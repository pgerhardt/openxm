import Foundation
import Observation

@MainActor @Observable
final class EqualizerGuideWorkflow {
    var isPresented = false
    private(set) var record: EqualizerGuideRecord?
    private(set) var reserved = false
    private(set) var busy = false
    private(set) var active = false
    private(set) var round: EqualizerGuideRound = .balance
    private(set) var selected: Int?
    private(set) var listeningToOriginal = false
    private(set) var message: String?
    private(set) var error: String?
    private(set) var choices: [EqualizerGuideCurve] = []
    private var favorites: [EqualizerGuideCurve] = []
    private var ownsSettingsOperation = false
    private unowned let controller: HeadphoneController
    private let store: EqualizerGuideStore
    private var task: Task<Void, Never>?

    init(controller: HeadphoneController, store: EqualizerGuideStore = .init()) {
        self.controller = controller; self.store = store
        reserved = store.exists
        do { record = try store.load() }
        catch { self.error = "Could not read EQ recovery: \(error.localizedDescription)" }
    }

    var result: EqualizerGuideCurve? { round == .review ? favorites.last : nil }
    var canStart: Bool { !reserved && !busy && controller.canWrite && EqualizerGuideRecord.supported(controller.state) && controller.state.equalizerAvailable == true }
    var canRecover: Bool {
        !busy && reserved && record != nil && !controller.isReplay && controller.isConnected
            && controller.selectedAddress == record?.address
    }
    var recoveryURL: URL { store.url }

    func open() { isPresented = true }

    func restoreLater() {
        guard !busy, reserved else { return }
        active = false
        message = "Your original EQ is saved on this Mac. Reconnect the headphones and restore it before making other settings changes."
        releaseOperation()
    }

    func start() {
        guard canStart, let address = controller.selectedAddress else { return }
        do {
            try controller.beginEqualizerGuideOperation()
            ownsSettingsOperation = true
        } catch { self.error = error.localizedDescription; return }
        run("Preserving your EQ presets…") { [self] in
            _ = try await controller.prepareEqualizerGuide(address: address) { value in
                guard try store.load() == record else {
                    throw SettingsBackupError.invalid("The recovery file changed outside OpenXM. No further EQ changes were made.")
                }
                // Remember the snapshot even if a disk error occurs after its atomic write.
                try store.save(value)
                record = value; reserved = true
            }
            favorites = []; round = .balance; selected = nil; listeningToOriginal = false
            choices = round.choices(around: nil); active = true
            message = "Play a familiar song in your music app, then compare the sounds below."
        }
    }

    func audition(_ index: Int) {
        guard active, !busy, choices.indices.contains(index), let record else { return }
        let curve = choices[index]
        run("Applying Sound \(index + 1)…") { [self] in
            try await controller.previewEqualizerGuide(curve, record: record)
            selected = index; listeningToOriginal = false
            message = "Sound \(index + 1) is active. Compare the others, then keep your favorite."
        }
    }

    func compareOriginal() {
        guard active, !busy, let record else { return }
        run("Restoring the original sound for comparison…") { [self] in
            try await controller.previewEqualizerGuide(nil, record: record)
            listeningToOriginal = true
            message = "Listening to your original EQ setting. Your favorite is still selected."
        }
    }

    func compareResult() {
        guard active, !busy, let record, let result else { return }
        run("Applying your chosen equalizer…") { [self] in
            try await controller.previewEqualizerGuide(result, record: record)
            listeningToOriginal = false
            message = "Listening to your chosen equalizer. Save it to replace Custom 2."
        }
    }

    func next() {
        guard active, !busy, let selected, choices.indices.contains(selected), round != .review else { return }
        favorites.append(choices[selected])
        round = EqualizerGuideRound(rawValue: round.rawValue + 1)!
        choices = round.choices(around: favorites.last)
        self.selected = nil
        message = round == .review ? "Compare your result with the original sound, then save or cancel."
            : "Choose your favorite from these five variations."
    }

    func back() {
        guard active, !busy, round != .balance else { return }
        round = EqualizerGuideRound(rawValue: round.rawValue - 1)!
        if !favorites.isEmpty { favorites.removeLast() }
        choices = round.choices(around: favorites.last); selected = nil
        message = "Compare the sounds again. Your headphones keep the last sound you auditioned."
    }

    func save() {
        guard active, !busy, let result, let record else { return }
        run("Saving Custom 2 and checking every preset…") { [self] in
            try await controller.finishEqualizerGuide(saving: result, record: record)
            try store.clear(matching: record)
            complete("Saved and verified Custom 2. Manual and Custom 1 were restored to their original curves.")
        }
    }

    func cancelAndRestore() {
        guard !busy, let record, canRecover else { return }
        do {
            if !ownsSettingsOperation {
                try controller.beginEqualizerGuideOperation()
                ownsSettingsOperation = true
            }
        } catch { self.error = error.localizedDescription; return }
        run("Restoring and verifying your original equalizer…") { [self] in
            try await controller.finishEqualizerGuide(saving: nil, record: record)
            try store.clear(matching: record)
            complete("Your original EQ selection and curves have been restored and verified.")
        }
    }

    /// Called only after the explicit Keep Current EQ confirmation. No device commands are sent.
    func keepCurrent() {
        guard !busy, reserved else { return }
        do {
            try store.archive()
            complete("Kept the current headphone EQ. The recovery file was archived on this Mac.")
        } catch { self.error = error.localizedDescription }
    }

    private func run(_ status: String, operation: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil; message = status
        task = Task { @MainActor [self] in
            defer { busy = false; task = nil }
            do {
                guard try store.load() == record else { throw SettingsBackupError.invalid("The recovery file changed outside OpenXM. It has been preserved.") }
                try await operation()
            }
            catch {
                let problem = error.localizedDescription
                active = false
                // If persistence failed after writing the file, recover using those exact bytes.
                if record == nil { record = try? store.load() }
                reserved = store.exists || record != nil
                if let record, (try? store.load()) == record,
                   controller.isConnected, controller.selectedAddress == record.address {
                    message = "The comparison stopped. Restoring your original EQ…"
                    do {
                        try await controller.finishEqualizerGuide(saving: nil, record: record)
                        try store.clear(matching: record)
                        complete("Your original EQ selection and curves have been restored and verified.")
                    } catch {
                        self.error = "\(problem) Restoration could not be confirmed: \(error.localizedDescription)"
                        message = "The recovery file is preserved. Reconnect these headphones and choose Restore Original EQ."
                    }
                }
                if self.error == nil { self.error = problem }
                if reserved { message = "The recovery file is preserved. Reconnect these headphones and choose Restore Original EQ." }
                releaseOperation()
            }
        }
    }

    private func complete(_ status: String) {
        record = nil; reserved = false; active = false; selected = nil
        message = status; error = nil
        releaseOperation()
    }

    private func releaseOperation() {
        if ownsSettingsOperation { controller.endSettingsOperation(); ownsSettingsOperation = false }
    }
}
