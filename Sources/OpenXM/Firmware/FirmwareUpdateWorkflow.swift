import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// One automatic attempt per live connection. Busy periods defer the read; failures need a refresh
/// or a new connection, so an unavailable service cannot cause an automatic retry loop.
struct FirmwareIdentityRefreshState {
    struct Connection: Equatable {
        let address: String
        let generation: Int
    }
    struct Context: Equatable {
        let connection: Connection?
        let canRead: Bool
    }
    private(set) var connection: Connection?
    private var attempted = false

    mutating func shouldRead(_ context: Context) -> Bool {
        if connection != context.connection { connection = context.connection; attempted = false }
        guard connection != nil, context.canRead, !attempted else { return false }
        attempted = true
        return true
    }
}

@MainActor @Observable
final class FirmwareUpdateWorkflow {
    var isPresented = false
    private(set) var busy = false
    private(set) var isInstalling = false
    private(set) var selectedRelease: FirmwareRelease = .xm3v452
    private(set) var identity: FirmwareIdentity?
    private(set) var identityAddress: String?
    private(set) var identityDate: Date?
    private(set) var metadata: FirmwareMetadata?
    private(set) var checkedAt: Date?
    private(set) var verifiedURL: URL?
    private(set) var verifiedRelease: FirmwareRelease?
    private(set) var packageSource: String?
    private(set) var journal: FirmwareJournal?
    private(set) var sessionError: String?
    private(set) var error: String?
    private(set) var message: String?
    private(set) var transferPhase: VMUTransfer.Phase?
    private(set) var transferred = 0
    private(set) var transferTotal = 0
    private(set) var downloaded = 0
    private(set) var downloadTotal: Int?
    private(set) var outcome: FirmwareRunOutcome?
    private(set) var reportURL: URL?
    private unowned let controller: HeadphoneController
    private var task: Task<Void, Never>?
    private var identityRefresh = FirmwareIdentityRefreshState()

    init(controller: HeadphoneController) {
        self.controller = controller
        reloadSession()
    }

    var targetAddress: String? { journal?.address ?? controller.selectedAddress }
    var canReadDevice: Bool {
        !busy && !controller.isReplay && targetAddress != nil && controller.bluetooth.status == .ready
            && !GuidanceJournalStore.exists && !controller.firmwareOperationInProgress
            && !controller.settingsOperationInProgress && !controller.hasPendingWrites && !controller.isPairing
    }

    var identityReadContext: FirmwareIdentityRefreshState.Context {
        let connection = controller.isConnected && !controller.isReplay && targetAddress == controller.selectedAddress
            ? targetAddress.map { FirmwareIdentityRefreshState.Connection(address: $0, generation: controller.firmwareIdentityGeneration) }
            : nil
        return .init(connection: connection, canRead: canReadDevice)
    }

    var selectedTransition: FirmwareTransition? {
        if let journal { return try? journal.transition(for: selectedRelease) }
        return identity.flatMap { try? FirmwareTransition.make(identity: $0, target: selectedRelease) }
    }
    var regionWarning: String? { identity?.regionWarning(for: selectedRelease.region) }
    var regionReleases: [FirmwareRelease] { FirmwareRelease.allCases.filter { $0.region == selectedRelease.region } }

    func selectRegion(_ region: FirmwareRegion) {
        guard !busy, journal == nil else { return }
        let release = FirmwareRelease(version: selectedRelease.version, region: region)
            ?? FirmwareRelease.allCases.last(where: { $0.region == region })!
        selectRelease(release)
    }

    func refreshIdentityIfNeeded() {
        guard isPresented, !isInstalling else { return }
        let context = identityReadContext
        if identityRefresh.connection != context.connection { clearIdentity() }
        if identityRefresh.shouldRead(context) { checkHeadphones() }
    }

    private func clearIdentity() {
        identity = nil; identityAddress = nil; identityDate = nil
    }

    var installPlan: FirmwareInstallPlan? { try? makePlan() }
    var eligibilityMessage: String? {
        do { _ = try makePlan(); return nil } catch { return error.localizedDescription }
    }

    private func makePlan() throws -> FirmwareInstallPlan {
        guard !controller.isReplay else { throw FirmwareError.invalid("Firmware installation is disabled in previews and replays.") }
        guard !GuidanceJournalStore.exists else { throw FirmwareError.invalid("Finish the saved voice-language session first.") }
        if let sessionError { throw FirmwareError.invalid(sessionError) }
        guard let identity, let identityAddress, let targetAddress,
              FirmwareDeviceAccess.normalizedAddress(identityAddress) == FirmwareDeviceAccess.normalizedAddress(targetAddress) else {
            throw FirmwareError.invalid("Headphone details load automatically when connected. If reading fails, reconnect the headphones or choose Refresh.")
        }
        try identity.checkModelAndRegion()
        if journal?.phase != .complete { try identity.checkPower() }
        guard verifiedURL != nil, verifiedRelease == selectedRelease else {
            throw FirmwareError.invalid("Download a package or choose a local file to verify it before installation.")
        }
        return try FirmwareInstallPlan.make(identity: identity, address: targetAddress, release: selectedRelease, journal: journal)
    }

    func present() {
        guard !controller.settingsBackup.busy else { return }
        reloadSession()
        controller.refreshFirmwareReservation()
        if !busy { clearIdentity(); identityRefresh = FirmwareIdentityRefreshState() }
        isPresented = true
        refreshIdentityIfNeeded()
    }

    func reloadSession() {
        guard !isInstalling else { return }
        do {
            journal = try FirmwareJournalStore.read()
            sessionError = nil
            if let release = journal?.targetRelease, release != selectedRelease {
                selectRelease(release)
            }
        } catch {
            journal = nil
            sessionError = "The saved firmware session could not be read: \(error.localizedDescription) It was preserved; installation is disabled."
        }
    }

    func selectRelease(_ release: FirmwareRelease) {
        guard !busy else { return }
        if selectedRelease.region != release.region { metadata = nil; checkedAt = nil }
        selectedRelease = release
        if verifiedRelease != release { verifiedRelease = nil; verifiedURL = nil; packageSource = nil }
        outcome = nil; error = nil; message = nil
    }

    func checkHeadphones() {
        guard canReadDevice else { return }
        reloadSession()
        guard let address = targetAddress else { return }
        clearIdentity()
        _ = identityRefresh.shouldRead(identityReadContext)
        start(message: "Reading model, region, firmware and battery from headphones…") { [self] in
            let fresh: FirmwareIdentity
            if controller.isConnected && !controller.firmwareControlsReserved {
                try controller.beginSettingsOperation()
                defer { controller.endSettingsOperation() }
                let access = try FirmwareAccessLock()
                defer { withExtendedLifetime(access) {} }
                fresh = try await controller.readFirmwareIdentity(address: address)
            } else {
                // Pending update sessions reserve ordinary controls; their identity checks need a separate link.
                try await controller.beginFirmwareAccess()
                defer { controller.endFirmwareAccess() }
                let access = try FirmwareAccessLock()
                defer { withExtendedLifetime(access) {} }
                let device = try FirmwareDeviceAccess.connectedDevice(address: address)
                fresh = try await FirmwareDeviceAccess.readIdentity(device)
            }
            try Task.checkCancellation()
            guard targetAddress == address else { throw FirmwareError.invalid("The selected headphones changed. Reconnect to read their details.") }
            identity = fresh; identityAddress = address; identityDate = Date()
            message = nil
        }
    }

    func checkServer() {
        guard !busy else { return }
        let region = selectedRelease.region
        start(message: "Checking Sony's \(region.title) WH-1000XM3 update metadata…") { [self] in
            let result = try await FirmwareDownloads.metadata(region: region)
            metadata = result; checkedAt = Date()
            let versions = Set(result.offers.map(\.targetVersion)).sorted().joined(separator: ", ")
            message = "Sony's metadata lists firmware \(versions). OpenXM installation remains limited to its verified package catalog."
        }
    }

    func download() {
        guard !busy else { return }
        let release = selectedRelease
        start(message: "Downloading \(release.version) from \(release.provenance)…") { [self] in
            downloaded = 0; downloadTotal = release.size
            let url = try await FirmwareDownloads.package(release) { [weak self] count, total in
                self?.downloaded = count; self?.downloadTotal = total
            }
            try acceptPackage(url, source: release.provenance)
        }
    }

    func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]; panel.allowsMultipleSelection = false
        panel.message = "Choose an original international, Japanese or Chinese WH-1000XM3 .bin package. Version and region are identified from its hash, regardless of filename."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, !self.busy else { return }
                self.start(message: "Verifying firmware file…") {
                    try self.acceptPackage(url, source: "Local file; matches the pinned package")
                }
            }
        }
    }

    private func acceptPackage(_ url: URL, source: String) throws {
        verifiedURL = nil; verifiedRelease = nil; packageSource = nil
        let image = try FirmwareImage(url: url)
        if let journal { _ = try journal.transition(for: image.release) }
        if selectedRelease.region != image.release.region { metadata = nil; checkedAt = nil }
        selectedRelease = image.release
        verifiedURL = url; verifiedRelease = image.release; packageSource = source
        message = "Verified \(image.release.label): file size and SHA-256 match the pinned package."
    }

    func install() {
        guard !busy, let plan = installPlan, let file = verifiedURL, let address = targetAddress else { return }
        // No auto-install, retries, or consent bypass. The shared runner presents the existing final warning,
        // then re-reads live identity/power before the first upgrade command.
        isInstalling = true; busy = true; error = nil; outcome = nil
        transferPhase = nil; transferred = 0; transferTotal = selectedRelease.size
        message = "Checking the installation request…"
        task = Task { @MainActor [self] in
            var ownsControls = false
            defer {
                if ownsControls { controller.endFirmwareAccess() }
                isInstalling = false; busy = false; task = nil
                reloadSession()
            }
            do {
                try await controller.beginFirmwareAccess()
                ownsControls = true
                let runner = FirmwareRunner(arguments: [plan.command.rawValue, file.path], selectedAddress: address, embedded: true)
                runner.onProgress = { [weak self] phase, offset, total in
                    self?.transferPhase = phase; self?.transferred = offset; self?.transferTotal = total
                }
                runner.onMessage = { [weak self] line in
                    // Packet traces remain in the diagnostic file. Show meaningful stages in the main UI.
                    if ["Waiting for", "Refreshing Bluetooth", "VERIFIED:", "FAILED:", "Cancelled"].contains(where: line.hasPrefix) {
                        self?.message = line
                    }
                }
                reportURL = runner.reportURL
                _ = await runner.run()
                outcome = runner.outcome
                switch runner.outcome {
                case .verified(let version): message = "Verified: the headphones now report \(version) firmware and region."
                case .cancelled: message = "Cancelled before starting a firmware session."
                case .failed(let detail): error = detail; message = FirmwareJournalStore.exists ? "Session retained. Reconnect the same headphones and resume with the same package." : "No unfinished firmware session was saved."
                default: error = "The installation did not return a verified result."
                }
            } catch {
                message = nil
                self.error = error.localizedDescription
                outcome = .failed(error.localizedDescription)
            }
        }
    }

    func cancelPreparation() { if !isInstalling { task?.cancel() } }

    func showPackage() { if let verifiedURL { NSWorkspace.shared.activateFileViewerSelecting([verifiedURL]) } }
    func showReport() { if let reportURL { NSWorkspace.shared.activateFileViewerSelecting([reportURL]) } }

    private func start(message: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; outcome = nil; self.message = message
        downloaded = 0; downloadTotal = nil
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do { try await operation(); try Task.checkCancellation() }
            catch is CancellationError { self.message = "Cancelled. Firmware installation was not started." }
            catch { self.message = nil; self.error = error.localizedDescription }
        }
    }
}
