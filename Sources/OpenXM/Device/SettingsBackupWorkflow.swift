import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum SettingsRestoreOutcome: Equatable, Sendable {
    case confirmed, adjusted(String), waitingForReconnect, failed(String)

    var message: String {
        switch self {
        case .confirmed: "Confirmed by headphones"
        case .adjusted(let message): message
        case .waitingForReconnect: "Waiting for reconnection and verification"
        case .failed(let message): message
        }
    }
}

enum SettingsRestoreSelection {
    /// Defaults apply only to a new backup's first preview. Refreshing a review must preserve explicit
    /// selections (including selecting nothing or opting into volume), while dropping unavailable entries.
    static func reviewed(_ entries: [SettingsRestoreEntry], keeping previous: Set<String>? = nil) -> Set<String> {
        let available = Set(entries.filter { $0.unavailableReason == nil && $0.setting.languageToRestore == nil }.map(\.id))
        if let previous { return previous.intersection(available) }
        return available.subtracting(["volume"])
    }
}

/// A resumable Bluetooth connection is not a verified setting. This executor stops after the first failure,
/// requires fresh read-back after reconnect, and checks the whole selected result after the final write.
@MainActor
enum SettingsRestoreExecutor {
    static func run(backup: SettingsBackup, entries: [SettingsRestoreEntry],
                    read: () async throws -> DeviceState,
                    write: (SettingsRestoreEntry) async -> SettingsRestoreOutcome,
                    reconnect: () async throws -> Void,
                    progress: (String, SettingsRestoreOutcome?) -> Void) async throws {
        let fresh = try await read()
        let current = try backup.plan(for: fresh)
        // Validate every selected item before the first write. A changed preview requires another review.
        for entry in entries {
            guard let actual = current.first(where: { $0.id == entry.id }), actual.unavailableReason == nil else {
                throw SettingsBackupError.invalid("\(entry.setting.title) is no longer available. Review the backup again.")
            }
        }
        for entry in entries {
            try Task.checkCancellation()
            progress(entry.id, nil)
            var result = await write(entry)
            try Task.checkCancellation()
            if result == .waitingForReconnect {
                progress(entry.id, result)
                try await reconnect()
                let after = try await read()
                _ = try backup.plan(for: after) // includes model/protocol checks
                let changes = try entry.setting.changes(for: after)
                result = changes.allSatisfy { $0.isReflected(in: after) == true }
                    ? .confirmed : .failed("The saved value was not confirmed after reconnection.")
            }
            progress(entry.id, result)
            if case .failed(let message) = result { throw SettingsBackupError.invalid(message) }
        }
        let final: DeviceState
        do { final = try await read() }
        catch {
            for entry in entries { progress(entry.id, .failed("Final verification could not finish: \(error.localizedDescription)")) }
            throw error
        }
        _ = try backup.plan(for: final)
        var failed = false
        for entry in entries {
            do {
                let changes = try entry.setting.changes(for: final)
                for change in changes where change.isReflected(in: final) != true {
                    if let adjustment = change.adjustment(in: final) { progress(entry.id, .adjusted(adjustment)) }
                    else { throw SettingsBackupError.invalid("The final read-back did not match this saved setting.") }
                }
            } catch {
                failed = true
                progress(entry.id, .failed(error.localizedDescription))
            }
        }
        if failed { throw SettingsBackupError.invalid("Some settings did not remain in effect. Review the results below.") }
    }
}

@MainActor @Observable
final class SettingsBackupWorkflow {
    var isPresented = false
    private(set) var backup: SettingsBackup?
    private(set) var entries: [SettingsRestoreEntry] = []
    var selected: Set<String> = []
    var includeCustomEQ = false
    private(set) var busy = false
    private(set) var changesHeadphones = false
    private(set) var message: String?
    private(set) var error: String?
    private(set) var outcomes: [String: SettingsRestoreOutcome] = [:]
    private(set) var activeID: String?
    private(set) var previewAddress: String?
    private(set) var previewFirmware: String?
    private(set) var needsReview = false
    private unowned let controller: HeadphoneController
    private var task: Task<Void, Never>?
    private var pendingLanguageRestore: GuidanceLanguage?

    init(controller: HeadphoneController) { self.controller = controller }

    var canRestore: Bool {
        !busy && !needsReview && backup != nil && controller.canWrite && previewAddress == controller.selectedAddress
            && previewFirmware == controller.state.firmware && !selected.isEmpty
            && entries.contains { selected.contains($0.id) && $0.unavailableReason == nil && $0.setting.languageToRestore == nil }
    }

    func createBackup() {
        guard !busy, let address = controller.selectedAddress else { return }
        let includeCustomEQ = includeCustomEQ
        startOperation(message: "Reading settings from headphones…", changesHeadphones: includeCustomEQ) { [self] in
            let state = try await controller.readSettingsState(address: address, includeCustomEQ: includeCustomEQ)
            let saved = try SettingsBackup.capture(state)
            backup = saved
            entries = try saved.plan(for: state)
            selected = SettingsRestoreSelection.reviewed(entries)
            previewAddress = address; previewFirmware = state.firmware; needsReview = false
            message = "Read \(saved.settings.count) settings. Save the backup to keep a copy."
        }
    }

    func openBackup() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose an OpenXM settings backup."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.load(url) }
        }
    }

    private func load(_ url: URL) {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw SettingsBackupError.invalid("The backup is larger than 1 MB.") }
            let saved = try SettingsBackup.decode(Data(contentsOf: url))
            backup = saved
            entries = saved.settings.sorted { $0.order < $1.order }.map {
                SettingsRestoreEntry(setting: $0, changes: [], unavailableReason: "Connect matching headphones and choose Review.", alreadyMatches: false)
            }
            selected = []; outcomes = [:]; error = nil
            previewAddress = nil; needsReview = true
            message = "Loaded \(url.lastPathComponent). Review it against your connected headphones."
            if controller.canWrite { review() }
        } catch { self.error = error.localizedDescription }
    }

    func saveBackup() {
        guard !busy, let backup else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(backup.model)-settings.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try backup.encoded().write(to: url, options: .atomic)
                    self?.message = "Saved \(url.lastPathComponent)."
                } catch { self?.error = error.localizedDescription }
            }
        }
    }

    func review() {
        guard !busy, let backup, let address = controller.selectedAddress else { return }
        let previousSelection = previewAddress == nil ? nil : selected
        needsReview = true
        startOperation(message: "Checking backup against connected headphones…") { [self] in
            let state = try await controller.readSettingsState(address: address)
            entries = try backup.plan(for: state)
            selected = SettingsRestoreSelection.reviewed(entries, keeping: previousSelection)
            previewAddress = address; previewFirmware = state.firmware; needsReview = false
            message = backup.hasEqualizerBank
                ? "Restoring custom EQ briefly selects each saved slot and verifies it, then returns to the saved active preset. Other changes may reconnect Bluetooth."
                : "Choose the settings to restore. Bluetooth may reconnect for button or connection changes."
        }
    }

    func restore() {
        guard canRestore, let backup, let address = previewAddress else { return }
        let chosen = entries.filter { selected.contains($0.id) && $0.unavailableReason == nil && $0.setting.languageToRestore == nil }
        let includeCustomEQ = chosen.contains { if case .equalizerBank = $0.setting { true } else { false } }
        needsReview = true
        startOperation(message: "Restoring selected settings…", changesHeadphones: true) { [self] in
            try await SettingsRestoreExecutor.run(backup: backup, entries: chosen,
                read: { try await self.controller.readSettingsState(address: address, includeCustomEQ: includeCustomEQ, matching: backup) },
                write: { await self.controller.restoreSetting($0, backup: backup, address: address) },
                reconnect: { try await self.controller.waitForSettingsReconnect(address: address) },
                progress: { id, result in
                    self.activeID = result == nil || result == .waitingForReconnect ? id : nil
                    if let result { self.outcomes[id] = result }
                })
            message = "Finished restoring \(chosen.count) settings. Results were checked again after the last change."
        }
    }

    func stop() {
        task?.cancel()
        if controller.state.alert?.requiresAnswer == true { controller.answerAlert(accept: false) }
        message = "Stopping. Settings already applied are kept; review again to continue."
    }

    var canReviewVoiceLanguage: Bool {
        !busy && !controller.isReplay && backup?.model == "WH-1000XM3" && backup?.family == .v1
            && backup?.voiceLanguage?.isKnown == true && !controller.guidancePackages.busy
            && !controller.guidancePackages.hasSession && !controller.firmwareOperationInProgress
            && !FirmwareJournalStore.exists && !GuidanceJournalStore.exists
    }

    func reviewVoiceLanguage() {
        guard canReviewVoiceLanguage, let language = backup?.voiceLanguage else { return }
        pendingLanguageRestore = language
        isPresented = false
    }

    /// Open the next sheet only after SwiftUI finishes dismissing the backup sheet.
    func completeLanguageRestoreHandoff() {
        guard let language = pendingLanguageRestore else { return }
        pendingLanguageRestore = nil
        guard canReviewVoiceLanguage else {
            error = "Finish the active operation before reviewing the saved voice language."
            isPresented = true
            return
        }
        controller.guidancePackages.openForRestore(language)
    }

    private func startOperation(message: String, changesHeadphones: Bool = false, body: @escaping @MainActor () async throws -> Void) {
        do { try controller.beginSettingsOperation() }
        catch { self.error = error.localizedDescription; return }
        busy = true; error = nil; self.message = message; outcomes = [:]; activeID = nil
        self.changesHeadphones = changesHeadphones
        task = Task { @MainActor in
            defer { controller.endSettingsOperation(); busy = false; self.changesHeadphones = false; activeID = nil; task = nil }
            do { try await body() }
            catch is CancellationError {
                if let activeID { outcomes[activeID] = .failed("Stopped before verification finished.") }
                self.message = "Stopped. Review the backup again before continuing."; needsReview = true
            }
            catch {
                if let activeID { outcomes[activeID] = .failed(error.localizedDescription) }
                self.error = error.localizedDescription; needsReview = true
            }
        }
    }
}
