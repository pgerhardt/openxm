import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class GuidancePackageWorkflow {
    var isPresented = false
    var language: GuidanceLanguage? { didSet { if language != oldValue { clearResult() } } }
    private(set) var busy = false
    private(set) var isInstalling = false
    private(set) var journal: GuidanceJournal?
    private(set) var sessionError: String?
    private(set) var transferPhase: VMUTransfer.Phase?
    private(set) var message: String?
    private(set) var error: String?
    private(set) var source: GuidanceMetadataDownload?
    private(set) var archive: GuidancePackageArchive?
    private(set) var notice: GuidanceNoticeArchive?
    private(set) var preflight: GuidancePreflight?
    private(set) var fraction: Double?
    private(set) var requestedBackupLanguage: GuidanceLanguage?
    private(set) var packageBackup: GuidancePackageBackup?
    private(set) var packageBackupName: String?
    private unowned let controller: HeadphoneController
    private var task: Task<Void, Never>?
    private var discoveryAddress: String?
    private var reviewedSessionID: UUID?

    init(controller: HeadphoneController) { self.controller = controller; reloadSession() }

    var hasSession: Bool { journal != nil || sessionError != nil || isInstalling }
    var languages: [GuidanceLanguage] {
        if let journal { return [journal.targetLanguage] }
        var values = controller.state.capabilities.voiceGuidanceCapability?.languages ?? language.map { [$0] } ?? []
        if let requestedBackupLanguage, !values.contains(requestedBackupLanguage) { values.append(requestedBackupLanguage) }
        if let saved = packageBackup?.context.language, !values.contains(saved) { values.append(saved) }
        return values
    }

    private var canReadLanguageService: Bool {
        !busy && !hasSession && controller.canWrite && controller.state.family == .v1 && controller.state.modelName == "WH-1000XM3"
            && language.map { controller.state.capabilities.voiceGuidanceCapability?.languages.contains($0) == true } == true
    }
    var canCheck: Bool { canReadLanguageService && packageBackup == nil }
    var canCheckSavedPackage: Bool { canReadLanguageService && packageBackup != nil }
    var canOpenPackageBackup: Bool { !busy && !hasSession }
    var canExportPackageBackup: Bool {
        !busy && (packageBackup != nil || (source != nil && archive != nil && (source?.metadata.offer?.notice == nil || notice != nil)))
    }
    var canDownload: Bool { !busy && !hasSession && !controller.isReplay && source?.metadata.offer != nil && archive == nil }
    var canCheckPreparation: Bool {
        !busy && !controller.isReplay && sessionError == nil && !FirmwareJournalStore.exists
            && controller.bluetooth.status == .ready && !controller.firmwareOperationInProgress
            && !controller.settingsOperationInProgress && !controller.hasPendingWrites && !controller.isPairing
            && (journal != nil || (controller.canWrite && source != nil && archive != nil && discoveryAddress != nil))
    }
    var canInstall: Bool {
        canCheckPreparation && ((journal != nil && reviewedSessionID == journal?.id) || (journal == nil && preflight != nil && controller.selectedAddress.map {
            FirmwareDeviceAccess.normalizedAddress($0) == discoveryAddress.map(FirmwareDeviceAccess.normalizedAddress)
        } == true))
    }
    var canCancelPreparation: Bool { canCheckPreparation && journal?.canCancelPreparation == true }
    var installTitle: String {
        if journal?.phase == .complete { return "Finish Verification…" }
        return journal == nil ? "Install Language…" : "Resume Language Update…"
    }

    func reloadSession() {
        guard !isInstalling else { return }
        do {
            let saved = try GuidanceJournalStore.read()
            if saved?.id != journal?.id { clearAssets() }
            journal = saved; sessionError = nil
            if let saved { language = saved.targetLanguage }
        } catch {
            journal = nil
            sessionError = "The saved language session could not be read: \(error.localizedDescription) It was preserved; installation is disabled."
        }
    }

    func open() {
        requestedBackupLanguage = nil
        reloadSession()
        controller.refreshFirmwareReservation()
        if journal == nil, packageBackup == nil, let available = controller.state.capabilities.voiceGuidanceCapability?.languages,
           language == nil || !available.contains(language!) {
            language = available.first(where: { $0 == controller.state.voiceGuidanceDetails.language }) ?? available.first
        }
        isPresented = true
    }

    /// A backup supplies only the desired language. It cannot supply device eligibility or authorize
    /// downloading/installing anything; discovery and preparation still read the connected headphones.
    func openForRestore(_ target: GuidanceLanguage) {
        reloadSession()
        guard target.isKnown, !busy, !hasSession else { return }
        clearResult()
        requestedBackupLanguage = target
        language = target
        controller.refreshFirmwareReservation()
        isPresented = true
    }

    func openPackageBackup() {
        guard canOpenPackageBackup else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose an OpenXM voice-package backup. Opening checks the saved files; it does not install them."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.loadPackageBackup(url) }
        }
    }

    private func loadPackageBackup(_ url: URL) {
        guard canOpenPackageBackup else { return }
        busy = true; error = nil; message = "Checking saved package files…"
        task = Task { [self] in
            defer { busy = false; task = nil }
            do {
                let reading = Task.detached(priority: .userInitiated) { try GuidancePackageBackup.read(url) }
                let saved = try await withTaskCancellationHandler(operation: { try await reading.value }, onCancel: { reading.cancel() })
                try Task.checkCancellation()
                guard requestedBackupLanguage == nil || requestedBackupLanguage == saved.context.language else {
                    throw FirmwareError.invalid("This package is for \(saved.context.language.title), but the settings backup requests \(requestedBackupLanguage!.title). Choose a matching package.")
                }
                clearResult()
                language = saved.context.language
                packageBackup = saved; packageBackupName = url.lastPathComponent
                message = "Saved file integrity checked. Connect the headphones and check this package before preparing an installation."
            } catch is CancellationError { message = "Opening the saved package was stopped." }
            catch { self.error = error.localizedDescription; message = nil }
        }
    }

    func exportPackageBackup() {
        guard canExportPackageBackup else { return }
        let saved = packageBackup, source = source, archive = archive, notice = notice
        busy = true; error = nil; message = "Preparing the original package files for export…"
        task = Task { [self] in
            defer { busy = false; task = nil }
            do {
                let preparing = Task.detached(priority: .userInitiated) {
                    if let saved { return saved }
                    guard let source, let archive else { throw FirmwareError.invalid("No complete package archive is open.") }
                    return try GuidancePackageBackup(assets: .init(source: source, archive: archive, notice: notice))
                }
                let document = try await withTaskCancellationHandler(operation: { try await preparing.value }, onCancel: { preparing.cancel() })
                try Task.checkCancellation()
                let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "\(document.context.model)-\(document.context.language.title)-voice-package.json"
                panel.message = "Save the original package, metadata, notice and provenance together. This does not include an update session."
                let destination: URL? = await withCheckedContinuation { continuation in
                    panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
                }
                guard let destination else { message = "Package export cancelled."; return }
                try Task.checkCancellation()
                let writing = Task.detached(priority: .userInitiated) {
                    let data = try document.encoded()
                    try Task.checkCancellation()
                    try data.write(to: destination, options: .atomic)
                }
                try await withTaskCancellationHandler(operation: { try await writing.value }, onCancel: { writing.cancel() })
                message = "Saved \(destination.lastPathComponent). Original file bytes and provenance are included; no language was installed."
            } catch is CancellationError { message = "Package export stopped." }
            catch { self.error = error.localizedDescription; message = nil }
        }
    }

    func checkSavedPackage() {
        guard canCheckSavedPackage, let saved = packageBackup, let address = controller.selectedAddress else { return }
        clearAssets(keepingBackup: true)
        busy = true; error = nil; message = "Reading the headphones and checking the saved package…"
        task = Task { [self] in
            defer { busy = false; task = nil }
            do {
                try controller.beginSettingsOperation()
                let request: GuidancePackageRequest
                do {
                    defer { controller.endSettingsOperation() }
                    request = try await controller.readGuidancePackageRequest(address: address, language: saved.context.language)
                }
                try Task.checkCancellation()
                let restoring = Task.detached(priority: .userInitiated) { try saved.restore(for: request) }
                let assets = try await withTaskCancellationHandler(operation: { try await restoring.value }, onCancel: { restoring.cancel() })
                try Task.checkCancellation()
                source = assets.source; archive = assets.archive; notice = assets.notice; discoveryAddress = address
                message = "The saved package matches the freshly read language service and original metadata rules. Check Headphones to review installation preparation. No package was downloaded or installed."
            } catch is CancellationError { message = "Saved-package check stopped." }
            catch { self.error = error.localizedDescription; message = nil }
        }
    }

    func closePackageBackup() { if !busy && !hasSession { clearResult() } }

    func check() {
        guard canCheck, let language, let address = controller.selectedAddress else { return }
        clearResult()
        busy = true; message = "Reading the language service from your headphones…"
        task = Task { [self] in
            defer { busy = false; task = nil }
            do {
                try controller.beginSettingsOperation()
                let request: GuidancePackageRequest
                do {
                    defer { controller.endSettingsOperation() }
                    request = try await controller.readGuidancePackageRequest(address: address, language: language)
                }
                try Task.checkCancellation()
                message = "Checking Sony for \(language.title)…"
                let downloaded = try await GuidanceDownloads.metadata(for: request)
                try Task.checkCancellation()
                guard self.language == language else { throw CancellationError() }
                source = downloaded
                discoveryAddress = address
                if downloaded.metadata.offer?.notice != nil {
                    message = "Reading Sony's package notice…"
                    notice = try await GuidanceNoticeDownloads.notice(downloaded)
                    try Task.checkCancellation()
                }
                message = downloaded.metadata.offer == nil
                    ? "Sony's metadata does not offer an eligible package for this device state."
                    : "Package found for \(language.title). Downloading saves a local copy."
            } catch is CancellationError { message = "Check stopped." }
            catch { self.error = error.localizedDescription; message = nil }
        }
    }

    func download() {
        guard canDownload, let source else { return }
        busy = true; error = nil; fraction = 0
        message = "Downloading \(source.request.language.title)…"
        task = Task { [self] in
            defer { busy = false; fraction = nil; task = nil }
            do {
                let saved = try await GuidanceDownloads.package(source) { [weak self] received, size in
                    if let size, size > 0 { self?.fraction = Double(received) / Double(size) }
                }
                archive = saved
                message = "Saved and checked against Sony's metadata size and SHA-1. No language was installed."
            } catch is CancellationError { message = "Download stopped. No incomplete archive was published." }
            catch { self.error = error.localizedDescription; message = nil }
        }
    }

    /// No preparation SET or GAIA command is sent. The result is a dated check, not an install permit.
    func checkPreparation() {
        guard canCheckPreparation, let input = installInput else { return }
        busy = true; error = nil; preflight = nil; reviewedSessionID = nil
        message = "Checking the headphones and saved package…"
        task = Task { [self] in
            defer { busy = false; task = nil }
            do {
                try await controller.beginFirmwareAccess()
                defer { controller.endFirmwareAccess() }
                let review = try await GuidanceInstaller(io: NativeGuidanceInstallationIO()).inspect(input)
                source = review.assets.source; archive = review.assets.archive; notice = review.assets.notice
                reviewedSessionID = review.journal?.id
                if review.journal == nil {
                    preflight = try GuidancePreflight.check(snapshot: review.snapshot, discoveryAddress: discoveryAddress ?? "",
                        source: review.assets.source, archive: review.assets.archive, notice: review.assets.notice)
                }
                message = review.plan == .verifyCompleted
                    ? "The saved session was committed and reports the expected language. Finish Verification will confirm normal update mode and clear the session."
                    : "Headphones and saved files checked. Installation requires your final confirmation."
            } catch is CancellationError { message = "Preparation check stopped." }
            catch { self.error = error.localizedDescription; message = nil }
        }
    }

    private var installInput: GuidanceInstallInput? {
        if let journal { return .resume(journal.id) }
        guard let source, let archive, let discoveryAddress else { return nil }
        return .start(source: source, archive: archive, notice: notice, discoveryAddress: discoveryAddress)
    }

    func install() {
        guard canInstall, let input = installInput else { return }
        busy = true; isInstalling = true; error = nil; fraction = nil; transferPhase = nil
        message = "Reading the headphones before installation review…"
        task = Task { [self] in
            var ownsControls = false
            defer {
                isInstalling = false; busy = false; task = nil; fraction = nil
                reloadSession()
                if ownsControls { controller.endFirmwareAccess() }
            }
            do {
                try await controller.beginFirmwareAccess(); ownsControls = true
                let installer = GuidanceInstaller(io: NativeGuidanceInstallationIO())
                installer.onMessage = { [weak self] in self?.message = $0 }
                installer.onProgress = { [weak self] phase, offset, total in
                    self?.transferPhase = phase
                    self?.fraction = phase == .transferring && total > 0 ? Double(offset) / Double(total) : nil
                }
                let outcome = try await installer.run(input) { [self] review in
                    // Reloaded recovery assets must be visible before their confirmation, too.
                    source = review.assets.source; archive = review.assets.archive; notice = review.assets.notice
                    let alert = GuidanceInstallConfirmation.alert(for: review)
                    NSApp.activate(ignoringOtherApps: true)
                    return alert.runModal() == .alertSecondButtonReturn
                }
                switch outcome {
                case .cancelled: message = "Cancelled before changing language-update mode."
                case .verified(let language): message = "Verified: the headphones now report \(language.title)."; preflight = nil
                }
            } catch {
                self.error = error.localizedDescription
                message = GuidanceJournalStore.exists ? "The language session was retained. Reconnect the same headphones and open its status." : "No language session was started."
            }
        }
    }

    func cancelPreparation() {
        guard canCancelPreparation, let journal else { return }
        busy = true; isInstalling = true; error = nil; fraction = nil; transferPhase = nil
        message = "Checking the saved preparation and original language…"
        task = Task { [self] in
            var ownsControls = false
            defer {
                isInstalling = false; busy = false; task = nil
                reloadSession()
                if ownsControls { controller.endFirmwareAccess() }
            }
            do {
                try await controller.beginFirmwareAccess(); ownsControls = true
                let installer = GuidanceInstaller(io: NativeGuidanceInstallationIO())
                installer.onMessage = { [weak self] in self?.message = $0 }
                let cleared = try await installer.cancelPreparation(journal.id) { review in
                    let alert = GuidanceInstallConfirmation.cancellationAlert(for: review)
                    NSApp.activate(ignoringOtherApps: true)
                    return alert.runModal() == .alertSecondButtonReturn
                }
                message = cleared ? "Preparation cancelled. The original \(journal.sourceLanguage.title) language and normal update mode were verified. Downloaded files remain saved."
                    : "Preparation kept. No update-mode change was requested."
            } catch {
                self.error = error.localizedDescription
                message = "Preparation could not be cleared. The language session was retained."
            }
        }
    }

    func stop() { if !isInstalling { task?.cancel() } }
    func revealArchive() { if let archive { NSWorkspace.shared.activateFileViewerSelecting([archive.packageURL]) } }
    func revealNotice() { if let notice { NSWorkspace.shared.activateFileViewerSelecting([notice.noticeURL]) } }
    private func clearResult() {
        clearAssets()
        error = nil; message = nil; fraction = nil
    }
    private func clearAssets(keepingBackup: Bool = false) {
        source = nil; archive = nil; notice = nil; preflight = nil; discoveryAddress = nil
        reviewedSessionID = nil
        if !keepingBackup { packageBackup = nil; packageBackupName = nil }
    }
}
