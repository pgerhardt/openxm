import Foundation

enum GuidanceInstallInput {
    case start(source: GuidanceMetadataDownload, archive: GuidancePackageArchive,
               notice: GuidanceNoticeArchive?, discoveryAddress: String)
    case resume(UUID)
}

struct GuidanceInstallReview {
    let snapshot: GuidanceDeviceSnapshot
    let assets: GuidanceInstallationAssets
    let journal: GuidanceJournal?
    let plan: GuidanceInstallPlan
}

struct GuidancePreparationReview {
    let snapshot: GuidanceDeviceSnapshot
    let journal: GuidanceJournal
}

enum GuidanceInstallOutcome: Equatable { case cancelled, verified(GuidanceLanguage) }

/// The UI reserves normal controls before invoking this coordinator. The kernel lock also excludes
/// separate processes. Scripted tests substitute I/O but exercise this same journal/transfer lifecycle.
@MainActor final class GuidanceInstaller {
    private let io: GuidanceInstallationIO
    private let journalURL: URL
    private let firmwareJournalURL: URL
    private let lockURL: URL
    var onMessage: ((String) -> Void)?
    var onProgress: ((VMUTransfer.Phase, Int, Int) -> Void)?

    init(io: GuidanceInstallationIO, journalURL: URL = GuidanceJournalStore.url,
         firmwareJournalURL: URL = FirmwareJournalStore.url, lockURL: URL = FirmwareAccessLock.url) {
        self.io = io; self.journalURL = journalURL; self.firmwareJournalURL = firmwareJournalURL; self.lockURL = lockURL
    }

    /// Inspection never enables update mode, opens GAIA or changes either journal.
    func inspect(_ input: GuidanceInstallInput) async throws -> GuidanceInstallReview {
        let lock = try FirmwareAccessLock(url: lockURL)
        defer { withExtendedLifetime(lock) {} }
        try excludeFirmwareSession()
        return try await review(input)
    }

    /// Returns true only after normal mode and the original language are read back and the journal
    /// is removed. No package files are needed or changed; no GAIA connection or abort is issued.
    func cancelPreparation(_ id: UUID, confirm: (GuidancePreparationReview) -> Bool) async throws -> Bool {
        let lock = try FirmwareAccessLock(url: lockURL)
        defer { withExtendedLifetime(lock) {} }
        try excludeFirmwareSession()
        let before = try await reviewPreparation(id)
        guard confirm(before) else { return false }
        try Task.checkCancellation()
        let fresh = try await reviewPreparation(id)
        guard before.journal == fresh.journal else {
            throw FirmwareError.invalid("The saved preparation changed while awaiting confirmation. Session retained.")
        }
        try Task.checkCancellation()
        onMessage?("Restoring normal language mode and checking the original language…")
        do {
            try await io.setUpdateMode(false, journal: fresh.journal, expectedLanguage: nil)
            let after = try await io.snapshot(address: fresh.journal.address, language: fresh.journal.targetLanguage)
            try fresh.journal.check(after)
            guard after.currentLanguage == fresh.journal.sourceLanguage, !after.updateModeEnabled else {
                throw FirmwareError.invalid("The original language and normal update mode were not both confirmed.")
            }
            // An uncooperative process may ignore the shared lock. Never delete a replaced record.
            guard try GuidanceJournalStore.read(from: journalURL) == fresh.journal else {
                throw FirmwareError.invalid("The saved preparation changed during cleanup.")
            }
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: journalURL)
            return true
        } catch {
            throw FirmwareError.invalid("\(error.localizedDescription) Language session retained.")
        }
    }

    private func reviewPreparation(_ id: UUID) async throws -> GuidancePreparationReview {
        guard let journal = try GuidanceJournalStore.read(from: journalURL), journal.id == id else {
            throw FirmwareError.invalid("The saved language session changed or no longer exists.")
        }
        guard journal.canCancelPreparation else {
            throw FirmwareError.invalid("A language transfer may already have started. Preparation cancellation is unavailable; session retained.")
        }
        let snapshot = try await io.snapshot(address: journal.address, language: journal.targetLanguage)
        try journal.check(snapshot)
        guard snapshot.currentLanguage == journal.sourceLanguage else {
            throw FirmwareError.invalid("The headphones no longer report the preparation's original language. Session retained.")
        }
        return .init(snapshot: snapshot, journal: journal)
    }

    func run(_ input: GuidanceInstallInput, confirm: (GuidanceInstallReview) -> Bool) async throws -> GuidanceInstallOutcome {
        let lock = try FirmwareAccessLock(url: lockURL)
        defer { withExtendedLifetime(lock) {} }
        try excludeFirmwareSession()
        let before = try await review(input)
        guard confirm(before) else { return .cancelled }
        try Task.checkCancellation()
        // Dialogs can remain open indefinitely. Repeat device reads and file verification after approval.
        let fresh = try await review(input)
        guard before.snapshot.address == fresh.snapshot.address, before.snapshot.request == fresh.snapshot.request,
              before.snapshot.currentLanguage == fresh.snapshot.currentLanguage, before.snapshot.method == fresh.snapshot.method,
              before.journal == fresh.journal, before.plan == fresh.plan else {
            throw FirmwareError.invalid("The language installation changed while awaiting confirmation. Review it again.")
        }
        var saved = try fresh.journal ?? GuidanceJournal(snapshot: fresh.snapshot, assets: fresh.assets)
        var ownsSession = fresh.journal != nil
        var cleanupAttempted = false
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "XM3 voice-language installation")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            if fresh.plan != .verifyCompleted {
                // Save before the first mode SET; a failed/uncertain response must leave recovery context.
                try GuidanceJournalStore.save(saved, to: journalURL)
                ownsSession = true
                onMessage?("Preparing the headphones for a language update…")
                try await io.setUpdateMode(true, journal: saved, expectedLanguage: fresh.snapshot.currentLanguage)
                // Persist uncertainty before opening GAIA, including a failure during its handshake.
                saved.transferStarted = true
                try GuidanceJournalStore.save(saved, to: journalURL)
                onMessage?("Opening the language-transfer connection…")
                let link = try await io.transferLink(address: saved.address, reconnecting: false)
                let transfer = VMUTransfer(link: link, bytes: fresh.assets.bytes, syncID: fresh.assets.syncID) { [self, address = saved.address] in
                    onMessage?("Waiting for the headphones to restart…")
                    return try await io.transferLink(address: address, reconnecting: true)
                }
                transfer.checkpoint = { [self] phase in
                    saved.phase = phase
                    try GuidanceJournalStore.save(saved, to: journalURL)
                }
                transfer.report = { [weak self] phase, offset, total in self?.onProgress?(phase, offset, total) }
                let allowResume: Bool, allowData: Bool
                switch fresh.plan {
                case .start: allowResume = false; allowData = true
                case .resume(let data): allowResume = true; allowData = data
                case .verifyCompleted: preconditionFailure("Completed sessions never open GAIA")
                }
                try await transfer.run(allowResume: allowResume, allowDataTransfer: allowData)
            }
            onMessage?("Restoring normal language mode and checking the installed language…")
            cleanupAttempted = true
            try await io.setUpdateMode(false, journal: saved, expectedLanguage: nil)
            let after = try await io.snapshot(address: saved.address, language: saved.targetLanguage)
            try saved.check(after)
            guard after.currentLanguage == saved.targetLanguage, !after.updateModeEnabled else {
                throw FirmwareError.invalid("The installed language or normal update status was not confirmed. Session retained.")
            }
            // Only independent language/status read-back permits clearing a committed session.
            guard saved.phase == .complete else { throw FirmwareError.invalid("Language commit was not recorded. Session retained.") }
            try FileManager.default.removeItem(at: journalURL)
            onMessage?("Verified: the headphones now report \(saved.targetLanguage.title).")
            return .verified(saved.targetLanguage)
        } catch {
            let original = error.localizedDescription
            if ownsSession && !cleanupAttempted {
                // VMUTransfer closes GAIA before unwinding. Cleanup runs even after task cancellation,
                // but the journal stays: disabling the mode does not prove commit or permit a new upload.
                let cleanup = Task { @MainActor [io, saved] in try await io.setUpdateMode(false, journal: saved, expectedLanguage: nil) }
                do { try await cleanup.value }
                catch { throw FirmwareError.invalid("\(original) Normal language mode could not be restored: \(error.localizedDescription) Session retained.") }
            }
            throw FirmwareError.invalid("\(original)\(ownsSession ? " Language session retained." : "")")
        }
    }

    private func excludeFirmwareSession() throws {
        guard !FileManager.default.fileExists(atPath: firmwareJournalURL.path) else {
            throw FirmwareError.invalid("Finish the saved firmware session before starting or resuming a language update.")
        }
    }

    private func review(_ input: GuidanceInstallInput) async throws -> GuidanceInstallReview {
        let journal = try GuidanceJournalStore.read(from: journalURL)
        switch input {
        case .start(let source, let archive, let notice, let address):
            guard journal == nil else { throw FirmwareError.invalid("A language session already exists. Open that session to continue.") }
            let snapshot = try await io.snapshot(address: address, language: source.request.language)
            let assets = try GuidanceInstallationAssets(source: source, archive: archive, notice: notice)
            let plan = try GuidanceInstallPlan.make(snapshot: snapshot, assets: assets, discoveryAddress: address, journal: nil)
            return .init(snapshot: snapshot, assets: assets, journal: nil, plan: plan)
        case .resume(let id):
            guard let journal, journal.id == id else { throw FirmwareError.invalid("The saved language session changed or no longer exists.") }
            let snapshot = try await io.snapshot(address: journal.address, language: journal.targetLanguage)
            let assets = try GuidanceInstallationAssets.load(journal: journal, snapshot: snapshot)
            let plan = try GuidanceInstallPlan.make(snapshot: snapshot, assets: assets, discoveryAddress: journal.address, journal: journal)
            return .init(snapshot: snapshot, assets: assets, journal: journal, plan: plan)
        }
    }
}
