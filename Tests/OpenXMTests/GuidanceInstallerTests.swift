import Foundation
import Testing
@testable import OpenXM

@MainActor private final class GuidanceTestLink: FirmwareLink {
    var incoming: [VMUPacket]
    var sent: [VMUPacket] = []
    var closed = false
    var onPacket: ((VMUPacket) throws -> Void)?
    init(_ incoming: [VMUPacket]) { self.incoming = incoming }
    func command(_ command: UInt16, payload: [UInt8]) async throws -> [UInt8] {
        if command == 0x0642 {
            let packet = try VMUPacket(bytes: payload); sent.append(packet)
            try onPacket?(packet)
        }
        return []
    }
    func nextNotification(timeout: TimeInterval) async throws -> VMUPacket {
        guard !incoming.isEmpty else { throw TransportError.timeout("synthetic script exhausted") }
        return incoming.removeFirst()
    }
    func close() { closed = true }
}

@MainActor private final class GuidanceTestIO: GuidanceInstallationIO {
    var snapshots: [GuidanceDeviceSnapshot]
    var links: [GuidanceTestLink]
    let allLinks: [GuidanceTestLink]
    let journalURL: URL
    var reads = 0, opens = 0
    var modes: [Bool] = []
    var onMode: ((Bool, GuidanceJournal) throws -> Void)?
    init(snapshots: [GuidanceDeviceSnapshot], links: [GuidanceTestLink] = [], journalURL: URL) {
        self.snapshots = snapshots; self.links = links; allLinks = links; self.journalURL = journalURL
    }
    func snapshot(address: String, language: GuidanceLanguage) async throws -> GuidanceDeviceSnapshot {
        reads += 1
        guard !snapshots.isEmpty else { throw TransportError.timeout("synthetic snapshot exhausted") }
        return snapshots.removeFirst()
    }
    func setUpdateMode(_ enabled: Bool, journal: GuidanceJournal, expectedLanguage: GuidanceLanguage?) async throws {
        #expect(try GuidanceJournalStore.read(from: journalURL)?.id == journal.id)
        #expect(enabled ? expectedLanguage != nil : expectedLanguage == nil)
        if !enabled { #expect(allLinks.allSatisfy { $0.closed } || opens == 0) }
        modes.append(enabled)
        try onMode?(enabled, journal)
    }
    func transferLink(address: String, reconnecting: Bool) async throws -> FirmwareLink {
        #expect(try GuidanceJournalStore.read(from: journalURL)?.transferStarted == true)
        #expect(modes.last == true)
        if reconnecting { #expect(allLinks.first?.closed == true) }
        opens += 1
        guard !links.isEmpty else { throw TransportError.timeout("synthetic links exhausted") }
        return links.removeFirst()
    }
}

@MainActor struct GuidanceInstallerTests {
    private let address = "00:11:22:33:44:55"
    private let request = GuidancePackageRequest(category: "TEST_CATEGORY", service: "TEST_EN_SERVICE",
        model: "WH-1000XM3", firmware: "2.0.0", serial: "0123456", language: .init(rawValue: 1))
    private let payload = Data("SYNTHETIC VOICE PACKAGE TEST DATA\n".utf8)

    private struct Fixture {
        let root: URL
        let assets: GuidanceInstallationAssets
        var journalURL: URL { root.appendingPathComponent("language.json") }
        var firmwareURL: URL { root.appendingPathComponent("firmware.json") }
        var lockURL: URL { root.appendingPathComponent("updates.lock") }
    }
    private func fixture() throws -> Fixture {
        func data(_ name: String, _ ext: String) throws -> Data {
            try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = try GuidanceMetadataDownload(data: data("synthetic-voice-notice-info", "enc"), request: request)
        let archive = try GuidanceDownloads.preserve(payload, source: source, directory: root.appendingPathComponent("packages"))
        let notice = try GuidanceNoticeDownloads.preserve(data("synthetic-voice-notice", "xml"), source: source, directory: root.appendingPathComponent("notices"))
        return .init(root: root, assets: try .init(source: source, archive: archive, notice: notice))
    }
    private func snapshot(language: UInt8 = 11, battery: Int = 100, mode: Bool = false,
                          method: UInt8 = 0x11, address: String? = nil, request: GuidancePackageRequest? = nil) -> GuidanceDeviceSnapshot {
        .init(address: address ?? self.address, request: request ?? self.request, currentLanguage: .init(rawValue: language),
              updateModeEnabled: mode, method: .init(code: method, parameters: [0, 50]), battery: battery, charging: false)
    }
    private func input(_ f: Fixture) -> GuidanceInstallInput {
        .start(source: f.assets.source, archive: f.assets.archive, notice: f.assets.notice, discoveryAddress: address)
    }
    private func installer(_ f: Fixture, io: GuidanceTestIO) -> GuidanceInstaller {
        .init(io: io, journalURL: f.journalURL, firmwareJournalURL: f.firmwareURL, lockURL: f.lockURL)
    }
    private func handshake(_ f: Fixture, _ point: UInt8) -> [VMUPacket] {
        [.init(0x14, [point] + f.assets.syncID + [1]), .init(2, [0, 0x10, 0])]
    }
    private func links(_ f: Fixture) -> [GuidanceTestLink] {
        [GuidanceTestLink(handshake(f, 0) + [.init(3, [0, 0, 0, UInt8(payload.count), 0, 0, 0, 0]), .init(0x0B)]),
         GuidanceTestLink(handshake(f, 3) + [.init(0x0F), .init(0x12)])]
    }
    private func save(_ f: Fixture, method: UInt8 = 0x11, started: Bool = true,
                      phase: VMUTransfer.Phase = .transferring) throws -> GuidanceJournal {
        var journal = try GuidanceJournal(snapshot: snapshot(method: method), assets: f.assets)
        journal.transferStarted = started; journal.phase = phase
        try GuidanceJournalStore.save(journal, to: f.journalURL)
        return journal
    }

    @Test func journalBindsExactAssetsAndPrivateDeviceIdentityAndRejectsMalformedState() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try save(f)
        #expect(try GuidanceJournalStore.read(from: f.journalURL) == saved)
        let json = try String(contentsOf: f.journalURL, encoding: .utf8)
        #expect(!json.contains(request.serial) && json.contains(saved.serialSHA256))
        #expect((try FileManager.default.attributesOfItem(atPath: f.journalURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try GuidanceInstallationAssets.load(journal: saved, snapshot: snapshot()).bytes == Array(payload))
        for bad in [snapshot(address: "00:11:22:33:44:56"), snapshot(language: 2), snapshot(method: 0x10),
                    snapshot(request: .init(category: request.category, service: request.service, model: request.model,
                        firmware: request.firmware, serial: "999", language: request.language))] {
            #expect(throws: (any Error).self) { try saved.check(bad) }
        }
        let original = try Data(contentsOf: f.journalURL)
        for (key, value): (String, Any) in [("formatVersion", 2), ("phase", "unknown"), ("transferStarted", false),
                                          ("packageSHA256", "broken"), ("address", ""), ("noticeSHA256", NSNull())] {
            var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any]); object[key] = value
            try JSONSerialization.data(withJSONObject: object).write(to: f.journalURL)
            #expect(throws: (any Error).self) { try GuidanceJournalStore.read(from: f.journalURL) }
        }
    }

    @Test func installationPersistsBeforeModeAndGAIAStreamsExactBytesAndRequiresLanguageReadback() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let links = links(f)
        // Independently computed with Python hashlib from the complete synthetic package bytes.
        #expect(f.assets.syncID == [0x12, 0xBD, 0x22, 0x65])
        let io = GuidanceTestIO(snapshots: [snapshot(), snapshot(), snapshot(language: 1, battery: 20)], links: links, journalURL: f.journalURL)
        io.onMode = { enabled, journal in
            if enabled { #expect(!journal.transferStarted && journal.phase == .preparing) }
            else { #expect(journal.phase == .complete) }
        }
        let result = try await installer(f, io: io).run(input(f)) { review in
            #expect(review.plan == .start)
            #expect(!FileManager.default.fileExists(atPath: f.journalURL.path)); return true
        }
        #expect(result == .verified(.init(rawValue: 1)))
        #expect(io.reads == 3 && io.opens == 2 && io.modes == [true, false])
        #expect(links[0].sent.filter { $0.opcode == 4 }.flatMap { $0.payload.dropFirst() } == Array(payload))
        #expect(links.allSatisfy { $0.closed })
        #expect(!FileManager.default.fileExists(atPath: f.journalURL.path))
        #expect(try Data(contentsOf: f.assets.archive.packageURL) == payload)
    }

    @Test func cancellingConfirmationDoesNotSaveSessionEnableModeOrOpenGAIA() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let io = GuidanceTestIO(snapshots: [snapshot()], journalURL: f.journalURL)
        #expect(try await installer(f, io: io).run(input(f), confirm: { _ in false }) == .cancelled)
        #expect(io.reads == 1 && io.opens == 0 && io.modes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.journalURL.path))
    }

    @Test func confirmationCannotAuthorizeChangedLanguagePowerMethodOrPackage() async throws {
        for change in 0..<4 {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let after = change == 0 ? snapshot(language: 1) : change == 1 ? snapshot(battery: 79)
                : change == 2 ? snapshot(method: 0x10) : snapshot()
            let io = GuidanceTestIO(snapshots: [snapshot(), after], journalURL: f.journalURL)
            await #expect(throws: (any Error).self) {
                try await installer(f, io: io).run(input(f)) { _ in
                    if change == 3 { try? Data(repeating: 0, count: payload.count).write(to: f.assets.archive.packageURL) }
                    return true
                }
            }
            #expect(io.opens == 0 && io.modes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: f.journalURL.path))
        }
    }

    @Test func uncertainModePreparationIsRecordedAndCleanedWithoutOpeningGAIA() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let io = GuidanceTestIO(snapshots: [snapshot(), snapshot()], journalURL: f.journalURL)
        io.onMode = { enabled, _ in if enabled { throw TransportError.timeout("mode acknowledgement") } }
        await #expect(throws: (any Error).self) { try await installer(f, io: io).run(input(f), confirm: { _ in true }) }
        let saved = try #require(try GuidanceJournalStore.read(from: f.journalURL))
        #expect(!saved.transferStarted && saved.phase == .preparing)
        #expect(io.opens == 0 && io.modes == [true, false])
    }

    @Test func transferFailureClosesGAIARestoresModeAndRetainsExactSession() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = links(f)[0]
        first.onPacket = { packet in if packet.opcode == 4 { throw TransportError.timeout("data ACK") } }
        let io = GuidanceTestIO(snapshots: [snapshot(), snapshot()], links: [first], journalURL: f.journalURL)
        await #expect(throws: (any Error).self) { try await installer(f, io: io).run(input(f), confirm: { _ in true }) }
        let saved = try #require(try GuidanceJournalStore.read(from: f.journalURL))
        #expect(saved.transferStarted && saved.phase == .transferring && saved.packageSHA256 == f.assets.archive.sha256)
        #expect(first.closed && io.modes == [true, false])
    }

    @Test func cancelledTransferRunsCleanupOutsideTheCancelledTask() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = links(f)[0]
        first.onPacket = { packet in if packet.opcode == 4 { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() } }
        let io = GuidanceTestIO(snapshots: [snapshot(), snapshot()], links: [first], journalURL: f.journalURL)
        io.onMode = { enabled, _ in if !enabled { #expect(!Task.isCancelled) } }
        let runner = installer(f, io: io)
        let task = Task { @MainActor in try await runner.run(input(f), confirm: { _ in true }) }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(io.modes == [true, false] && first.closed)
        #expect(try GuidanceJournalStore.read(from: f.journalURL)?.phase == .transferring)
    }

    @Test func resumableSessionUsesSavedIdentifierAndDeviceDirectedValidation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try save(f)
        let first = GuidanceTestLink(handshake(f, 1) + [.init(0x0B)])
        let second = links(f)[1]
        let io = GuidanceTestIO(snapshots: [snapshot(mode: true), snapshot(mode: true), snapshot(language: 1)],
                                links: [first, second], journalURL: f.journalURL)
        #expect(try await installer(f, io: io).run(.resume(saved.id), confirm: { _ in true }) == .verified(.init(rawValue: 1)))
        #expect(first.sent.first?.payload == f.assets.syncID && !first.sent.contains { $0.opcode == 4 })
        #expect(io.modes == [true, false] && !FileManager.default.fileExists(atPath: f.journalURL.path))
    }

    @Test func provisionalTargetAllowsOnlyCommitResumeAndNeverAnotherUpload() async throws {
        for point: UInt8 in [0, 3, 4] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let saved = try save(f, phase: .committing)
            let last: [VMUPacket] = point == 3 ? [.init(0x0F), .init(0x12)] : [.init(0x12)]
            let link = GuidanceTestLink(handshake(f, point) + last)
            let io = GuidanceTestIO(snapshots: Array(repeating: snapshot(language: 1), count: 3), links: [link], journalURL: f.journalURL)
            if point == 0 {
                await #expect(throws: (any Error).self) { try await installer(f, io: io).run(.resume(saved.id), confirm: { _ in true }) }
                #expect(link.sent.map(\.opcode) == [0x13])
                #expect(try GuidanceJournalStore.read(from: f.journalURL) != nil)
            } else {
                #expect(try await installer(f, io: io).run(.resume(saved.id), confirm: { _ in true }) == .verified(.init(rawValue: 1)))
            }
            #expect(!link.sent.contains { [UInt8(4), 0x15].contains($0.opcode) })
        }
    }

    @Test func nonresumableMethodCanRetryModePreparationButCannotRestartAnUncertainTransfer() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let uncertain = try save(f, method: 0x10)
        let io = GuidanceTestIO(snapshots: [snapshot(method: 0x10)], journalURL: f.journalURL)
        await #expect(throws: (any Error).self) {
            try await installer(f, io: io).run(.resume(uncertain.id)) { _ in Issue.record("Must not offer confirmation"); return true }
        }
        #expect(io.modes.isEmpty && io.opens == 0)
        let prepared = try save(f, method: 0x10, started: false, phase: .preparing)
        let retry = GuidanceTestIO(snapshots: [snapshot(mode: true, method: 0x10), snapshot(mode: true, method: 0x10), snapshot(language: 1, method: 0x10)],
                                  links: links(f), journalURL: f.journalURL)
        #expect(try await installer(f, io: retry).run(.resume(prepared.id), confirm: { _ in true }) == .verified(.init(rawValue: 1)))
    }

    @Test func completedSessionOnlyCleansModeAndReadsLanguageEvenWithDepletedBattery() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try save(f, method: 0x10, phase: .complete)
        let io = GuidanceTestIO(snapshots: Array(repeating: snapshot(language: 1, battery: 0, method: 0x10), count: 3), journalURL: f.journalURL)
        #expect(try await installer(f, io: io).run(.resume(saved.id), confirm: { $0.plan == .verifyCompleted }) == .verified(.init(rawValue: 1)))
        #expect(io.modes == [false] && io.opens == 0 && io.reads == 3)
        #expect(!FileManager.default.fileExists(atPath: f.journalURL.path))
    }

    @Test func unconfirmedFinalLanguageOrCleanupKeepsCommittedJournalForVerificationOnly() async throws {
        for cleanupFails in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let io = GuidanceTestIO(snapshots: [snapshot(), snapshot(), snapshot()], links: links(f), journalURL: f.journalURL)
            io.onMode = { enabled, _ in if !enabled && cleanupFails { throw TransportError.timeout("cleanup status") } }
            await #expect(throws: (any Error).self) { try await installer(f, io: io).run(input(f), confirm: { _ in true }) }
            let saved = try #require(try GuidanceJournalStore.read(from: f.journalURL))
            #expect(saved.phase == .complete)
            let retry = GuidanceTestIO(snapshots: Array(repeating: snapshot(language: 1), count: 3), journalURL: f.journalURL)
            #expect(try await installer(f, io: retry).run(.resume(saved.id), confirm: { _ in true }) == .verified(.init(rawValue: 1)))
            #expect(retry.opens == 0 && retry.modes == [false])
        }
    }

    @Test func missingCorruptOrConflictingSessionsAndSharedLockFailBeforeBluetooth() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let io = GuidanceTestIO(snapshots: [], journalURL: f.journalURL)
        let runner = installer(f, io: io)
        await #expect(throws: (any Error).self) { try await runner.inspect(.resume(UUID())) }
        try Data("corrupt journal".utf8).write(to: f.journalURL)
        await #expect(throws: (any Error).self) { try await runner.inspect(input(f)) }
        try FileManager.default.removeItem(at: f.journalURL)
        try Data("unfinished firmware session".utf8).write(to: f.firmwareURL)
        await #expect(throws: (any Error).self) { try await runner.inspect(input(f)) }
        try FileManager.default.removeItem(at: f.firmwareURL)
        let other = try FirmwareAccessLock(url: f.lockURL)
        await #expect(throws: (any Error).self) { try await runner.inspect(input(f)) }
        withExtendedLifetime(other) {}
        #expect(io.reads == 0 && io.opens == 0 && io.modes.isEmpty)
    }

    @Test func preparationCancellationOnlyCleansModeVerifiesOriginalLanguageAndPreservesAssets() async throws {
        for method: UInt8 in [0x10, 0x11] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let saved = try save(f, method: method, started: false, phase: .preparing)
            let io = GuidanceTestIO(snapshots: [snapshot(battery: 0, mode: true, method: method),
                snapshot(battery: 0, mode: true, method: method), snapshot(battery: 0, method: method)], journalURL: f.journalURL)
            let cleared = try await installer(f, io: io).cancelPreparation(saved.id) { review in
                #expect(review.journal == saved && review.snapshot.currentLanguage == saved.sourceLanguage)
                return true
            }
            #expect(cleared)
            #expect(io.modes == [false] && io.opens == 0 && io.reads == 3)
            #expect(try GuidanceJournalStore.read(from: f.journalURL) == nil)
            #expect(try Data(contentsOf: f.assets.archive.packageURL) == payload)
            #expect(try GuidanceInstallationAssets(source: f.assets.source, archive: f.assets.archive, notice: f.assets.notice).bytes == Array(payload))
        }
    }

    @Test func keepingPreparationDoesNotChangeModeOrJournal() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try save(f, started: false, phase: .preparing)
        let io = GuidanceTestIO(snapshots: [snapshot(mode: true)], journalURL: f.journalURL)
        let cleared = try await installer(f, io: io).cancelPreparation(saved.id, confirm: { _ in false })
        #expect(!cleared)
        #expect(io.modes.isEmpty && io.opens == 0 && io.reads == 1)
        #expect(try GuidanceJournalStore.read(from: f.journalURL) == saved)
    }

    @Test func preparationCancellationDoesNotRequireMissingPackageOrNoticeFiles() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try save(f, started: false, phase: .preparing)
        try FileManager.default.removeItem(at: f.assets.archive.directory)
        try FileManager.default.removeItem(at: #require(f.assets.notice?.directory))
        let io = GuidanceTestIO(snapshots: Array(repeating: snapshot(), count: 3), journalURL: f.journalURL)
        #expect(try await installer(f, io: io).cancelPreparation(saved.id, confirm: { _ in true }))
        #expect(io.modes == [false] && io.opens == 0)
    }

    @Test func preparationCancellationRefusesAnyPossiblyStartedTransferBeforeBluetooth() async throws {
        for phase: VMUTransfer.Phase in [.preparing, .transferring, .validating, .rebooting, .committing, .complete] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let saved = try save(f, phase: phase)
            let io = GuidanceTestIO(snapshots: [], journalURL: f.journalURL)
            await #expect(throws: (any Error).self) {
                try await installer(f, io: io).cancelPreparation(saved.id) { _ in
                    Issue.record("Started transfers cannot reach cancellation confirmation"); return true
                }
            }
            #expect(io.reads == 0 && io.modes.isEmpty && io.opens == 0)
            #expect(try GuidanceJournalStore.read(from: f.journalURL) == saved)
        }
    }

    @Test func preparationCancellationRechecksIdentityLanguageAndJournalAfterConfirmation() async throws {
        for change in 0..<5 {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let saved = try save(f, started: false, phase: .preparing)
            let after = change == 0 ? snapshot(language: 1) : change == 1 ? snapshot(address: "00:11:22:33:44:56")
                : change == 2 ? snapshot(method: 0x10) : snapshot()
            let io = GuidanceTestIO(snapshots: [snapshot(), after], journalURL: f.journalURL)
            await #expect(throws: (any Error).self) {
                try await installer(f, io: io).cancelPreparation(saved.id) { _ in
                    if change == 3 { _ = try? save(f, started: false, phase: .preparing) }
                    if change == 4 { var started = saved; started.transferStarted = true; try? GuidanceJournalStore.save(started, to: f.journalURL) }
                    return true
                }
            }
            #expect(io.modes.isEmpty && io.opens == 0)
            #expect(try GuidanceJournalStore.read(from: f.journalURL) != nil)
        }
    }

    @Test func uncertainPreparationCleanupOrReadbackRetainsSessionAndCanBeRetried() async throws {
        for failure in 0..<4 {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let saved = try save(f, started: false, phase: .preparing)
            let after = failure == 1 ? snapshot(language: 1) : failure == 2 ? snapshot(mode: true) : snapshot()
            let io = GuidanceTestIO(snapshots: failure == 3 ? [snapshot(), snapshot()] : [snapshot(), snapshot(), after], journalURL: f.journalURL)
            io.onMode = { _, _ in if failure == 0 { throw TransportError.timeout("cleanup ACK") } }
            await #expect(throws: (any Error).self) { try await installer(f, io: io).cancelPreparation(saved.id, confirm: { _ in true }) }
            #expect(try GuidanceJournalStore.read(from: f.journalURL) == saved)
            #expect(io.modes == [false] && io.opens == 0)
            let retry = GuidanceTestIO(snapshots: Array(repeating: snapshot(), count: 3), journalURL: f.journalURL)
            #expect(try await installer(f, io: retry).cancelPreparation(saved.id, confirm: { _ in true }))
            #expect(retry.opens == 0 && retry.modes == [false])
        }
    }

    @Test func preparationCancellationCannotRemoveChangedRecordOrRunWithoutExclusiveSession() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try save(f, started: false, phase: .preparing)
        let io = GuidanceTestIO(snapshots: [], journalURL: f.journalURL)
        let runner = installer(f, io: io)
        try Data("unfinished firmware".utf8).write(to: f.firmwareURL)
        await #expect(throws: (any Error).self) { try await runner.cancelPreparation(saved.id, confirm: { _ in true }) }
        try FileManager.default.removeItem(at: f.firmwareURL)
        do {
            let held = try FirmwareAccessLock(url: f.lockURL)
            await #expect(throws: (any Error).self) { try await runner.cancelPreparation(saved.id, confirm: { _ in true }) }
            withExtendedLifetime(held) {}
        }
        await #expect(throws: (any Error).self) { try await runner.cancelPreparation(UUID(), confirm: { _ in true }) }
        #expect(io.reads == 0 && io.opens == 0 && io.modes.isEmpty)
        io.snapshots = Array(repeating: snapshot(), count: 3)
        var replacement: GuidanceJournal?
        io.onMode = { _, _ in replacement = try save(f, started: false, phase: .preparing) }
        await #expect(throws: (any Error).self) { try await runner.cancelPreparation(saved.id, confirm: { _ in true }) }
        #expect(try GuidanceJournalStore.read(from: f.journalURL) == replacement)
        #expect(replacement?.id != saved.id && io.opens == 0)
    }

    @Test func changedNoticeInSavedSessionCannotReachModePreparation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try save(f)
        let url = try #require(f.assets.notice?.noticeURL)
        var bytes = try Data(contentsOf: url); bytes[0] ^= 1; try bytes.write(to: url)
        let io = GuidanceTestIO(snapshots: [snapshot()], journalURL: f.journalURL)
        await #expect(throws: (any Error).self) { try await installer(f, io: io).run(.resume(saved.id), confirm: { _ in true }) }
        #expect(io.opens == 0 && io.modes.isEmpty)
        #expect(try Data(contentsOf: url) == bytes && GuidanceJournalStore.read(from: f.journalURL) == saved)
    }
}

@MainActor struct GuidanceMDRSessionTests {
    private func string(_ command: UInt8, _ selector: UInt8, _ value: String) -> [UInt8] {
        [command, selector, UInt8(value.utf8.count)] + Array(value.utf8)
    }
    @Test func nativeReadTransactionUsesOnlyExactTableScopedQueriesAndFreshFields() async throws {
        func field(_ text: String) -> [UInt8] { [UInt8(text.utf8.count)] + Array(text.utf8) }
        let replies: [[UInt8]] = [[1, 0], string(5, 1, "WH-1000XM3"), string(5, 2, "2.0.0"),
            string(0x37, 2, "HP001"), string(0x37, 3, "MDRID291600"), [0x41, 1, 1, 1, 2, 1, 11],
            [0x43, 1, 2, 1], [0x47, 1, 2, 11], [0x47, 1, 4, 1] + field("TEST_CATEGORY") + field("123") + [1, 1] + field("TEST_EN_SERVICE"),
            [0x47, 1, 5, 0x11, 0, 50], [0x11, 0, 90, 0]]
        var sent: [[UInt8]] = [], tables: [MDRDataType] = []
        let read = try await GuidanceMDRSession.read(address: "00-11-22-33-44-55", language: .init(rawValue: 1)) { payload, table, matcher in
            let reply = replies[sent.count]; sent.append(payload); tables.append(table)
            #expect(matcher.matches(.init(type: table, sequence: 0, payload: reply)))
            return reply
        }
        #expect(sent == [[0, 0], [4, 1], [4, 2], [0x36, 2], [0x36, 3], [0x40, 1], [0x42, 1, 2],
                         [0x46, 1, 2], [0x46, 1, 4], [0x46, 1, 5], [0x10, 0]])
        #expect(tables == Array(repeating: .dataMdr, count: 5) + Array(repeating: .dataMdrNo2, count: 5) + [.dataMdr])
        #expect(read.currentLanguage.rawValue == 11 && !read.updateModeEnabled && read.battery == 90)
        #expect(read.request.service == "TEST_EN_SERVICE" && read.method.code == 0x11)
    }

    @Test func updateModeRequiresExactStatusNotificationAndCannotAcceptAnOrdinaryParameterReply() async throws {
        for enabled in [false, true] {
            let value: UInt8 = enabled ? 0 : 1
            let good: [UInt8] = [0x45, 1, 2, value]
            try await GuidanceMDRSession.setUpdateMode(enabled) { payload, table, matcher in
                #expect(payload == [0x44, 1, 2, value] && table == .dataMdrNo2)
                #expect(matcher.matches(.init(type: table, sequence: 0, payload: good)))
                #expect(!matcher.matches(.init(type: .dataMdr, sequence: 0, payload: good)))
                return good
            }
            for bad: [UInt8] in [[0x45, 1, 2, 1 - value], [0x45, 1, 1, value], [0x43, 1, 2, value],
                                 [0x49, 1, 2, value], Array(good.dropLast()), good + [0]] {
                await #expect(throws: (any Error).self) { try await GuidanceMDRSession.setUpdateMode(enabled) { _, _, _ in bad } }
            }
        }
    }

    @Test func earbudsAndOtherRegionsAreRejectedBeforeAnyVoiceOperation() async throws {
        for (model, service) in [("WF-1000XM3", "MDRID291600"), ("WH-1000XM3", "MDRID291601"), ("WH-1000XM3", "MDRID291602")] {
            var queries: [[UInt8]] = []
            await #expect(throws: (any Error).self) {
                try await GuidanceMDRSession.read(address: "00:11:22:33:44:55", language: .init(rawValue: 1)) { payload, table, _ in
                    queries.append(payload); #expect(table == .dataMdr)
                    switch payload {
                    case [0, 0]: return [1, 0]
                    case [4, 1]: return string(5, 1, model)
                    case [4, 2]: return string(5, 2, "2.0.0")
                    case [0x36, 2]: return string(0x37, 2, "HP001")
                    case [0x36, 3]: return string(0x37, 3, service)
                    default: Issue.record("Unexpected voice operation"); throw CancellationError()
                    }
                }
            }
            #expect(queries.count == (model == "WF-1000XM3" ? 2 : 5))
        }
    }
}
