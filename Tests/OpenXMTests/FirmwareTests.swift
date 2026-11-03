import Foundation
import Testing
@testable import OpenXM

struct FirmwareFramingTests {
    @Test func literalGAIAFramesAndFragmentation() throws {
        let request = GAIAFrame(command: 0x0304)
        #expect(try request.encoded() == [0xFF, 1, 0, 0, 0, 0x0A, 3, 4])
        var assembler = GAIAFrameAssembler()
        let response: [UInt8] = [0xFF, 1, 1, 3, 0, 0x0A, 0x83, 4, 0, 4, 0x52]
        let checked = response + [response.reduce(0, ^)]
        for byte in checked.dropLast() { #expect(try assembler.feed([byte]).isEmpty) }
        #expect(try assembler.feed([checked.last!]) == [GAIAFrame(command: 0x8304, payload: [0, 4, 0x52])])
        #expect(try assembler.feed(request.encoded() + request.encoded()).count == 2)
    }

    @Test func malformedFramesAreRejected() throws {
        var assembler = GAIAFrameAssembler()
        #expect(throws: (any Error).self) { try assembler.feed([0xFF, 2, 0, 0]) }
        #expect(throws: (any Error).self) { try assembler.feed([0xFF, 1, 2, 0]) }
        #expect(throws: (any Error).self) { try assembler.feed([0xFF, 1, 1, 0, 0, 0x0A, 3, 4, 0]) }
        #expect(throws: (any Error).self) { try GAIAFrame(command: 0, payload: Array(repeating: 0, count: 255)).encoded() }
        #expect(throws: (any Error).self) { try VMUPacket(bytes: [3, 0]) }
        #expect(throws: (any Error).self) { try VMUPacket(bytes: [3, 0, 8, 0]) }
        #expect(try VMUPacket(0x13, [0x8A, 0xDE, 0xC9, 0xAE]).encoded() == [0x13, 0, 4, 0x8A, 0xDE, 0xC9, 0xAE])
    }

    @Test func capturedXM3SyncExtensionIsAcceptedWithoutRelaxingOtherLengths() throws {
        // Captured from the physical 4.5.2 headset; header length excludes the final protocol byte.
        let captured: [UInt8] = [0x14, 0, 5, 0, 0x8A, 0xDE, 0xC9, 0xAE, 3]
        #expect(try VMUPacket(bytes: captured) == VMUPacket(0x14, [0, 0x8A, 0xDE, 0xC9, 0xAE, 3]))
        #expect(throws: (any Error).self) { try VMUPacket(bytes: captured + [0]) }
        #expect(throws: (any Error).self) { try VMUPacket(bytes: [3] + captured.dropFirst()) }
        #expect(throws: (any Error).self) { try VMUPacket(bytes: Array(captured.dropLast()) + [2]) }
    }

    @Test func rejectsUnpinnedImages() throws {
        #expect(throws: (any Error).self) { try FirmwareImage(data: Data()) }
        for release in FirmwareRelease.allCases {
            #expect(throws: (any Error).self) { try FirmwareImage(data: Data(repeating: 0, count: release.size)) }
        }
    }
}

struct FirmwareSessionTests {
    private func identity(_ version: String, model: String = "WH-1000XM3", category: String = "HP001",
                          service: String = "MDRID291600", battery: Int = 100, charging: Bool = false) -> FirmwareIdentity {
        FirmwareIdentity(model: model, version: version, category: category, service: service,
                         battery: battery, charging: charging)
    }

    @Test(arguments: [FirmwareTransition.downgrade, .upgrade])
    func enforcesDirectionAndRegion(_ transition: FirmwareTransition) throws {
        try transition.checkImage(transition.target)
        try transition.checkIdentity(identity(transition.source.version))
        #expect(throws: (any Error).self) { try transition.checkImage(transition.source) }
        for version in [transition.target.version, "1.0.8", "4.1.1", "4.2.2", "9.9.9", ""] {
            #expect(throws: (any Error).self) { try transition.checkIdentity(identity(version)) }
        }
        for model in ["WF-1000XM3", "WH-1000XM4", "WH-1000XM5", ""] {
            #expect(throws: (any Error).self) { try transition.checkIdentity(identity(transition.source.version, model: model)) }
        }
        for service in ["MDRID291601", "MDRID291602", "MDRID294300", ""] {
            #expect(throws: (any Error).self) { try transition.checkIdentity(identity(transition.source.version, service: service)) }
        }
        #expect(throws: (any Error).self) { try transition.checkIdentity(identity(transition.source.version, category: "HP002")) }
    }

    @Test func requiresChargedUnpluggedHeadphones() throws {
        for level in [50, 79, 80, 100] { try identity("2.0.0", battery: level).checkPower() }
        for level in [-1, 0, 49, 101] {
            #expect(throws: (any Error).self) { try identity("2.0.0", battery: level).checkPower() }
        }
        #expect(throws: (any Error).self) { try identity("2.0.0", charging: true).checkPower() }
    }

    @Test func identifiesRegionalServicesWithoutClaimingCrossRegionInstallationIsVerified() {
        for (service, name) in [("MDRID291600", "International"), ("MDRID291601", "Japan"), ("MDRID291602", "China")] {
            let device = identity("2.0.0", service: service)
            #expect(device.regionName == name)
            #expect((device.regionWarning(for: .international) == nil) == (service == "MDRID291600"))
        }
        #expect(identity("2.0.0", service: "MDRID291603").regionName == "Unknown")
        #expect(identity("2.0.0", model: "WF-1000XM3").regionName == "Unknown")
        #expect(identity("2.0.0", category: "HP002").regionName == "Unknown")
    }

    @Test(arguments: [FirmwareTransition.downgrade, .upgrade])
    func resumeAndReadBackUseTheSelectedTarget(_ transition: FirmwareTransition) throws {
        try transition.checkIdentity(identity(transition.source.version), resuming: true)
        try transition.checkIdentity(identity(transition.target.version), resuming: true)
        #expect(throws: (any Error).self) { try transition.checkIdentity(identity("4.1.1"), resuming: true) }
        #expect(throws: (any Error).self) { try transition.verifyInstalled(identity(transition.source.version)) }
        #expect(throws: (any Error).self) { try transition.verifyInstalled(identity(transition.target.version, service: "MDRID291602")) }
        // Completion only reads identity: it must work even when the long transfer depleted the battery.
        try transition.verifyInstalled(identity(transition.target.version, battery: 0))
    }

    @Test(arguments: [FirmwareTransition.downgrade, .upgrade])
    func journalsBindImageAndDirection(_ transition: FirmwareTransition) throws {
        func journal(hash: String? = nil, source: String? = nil, target: String? = nil,
                     address: String = "test-device") -> FirmwareJournal {
            FirmwareJournal(address: address, sha256: hash ?? transition.target.sha256,
                sourceVersion: source ?? transition.source.version, targetVersion: target ?? transition.target.version,
                started: Date(timeIntervalSince1970: 0))
        }
        let saved = try JSONDecoder().decode(FirmwareJournal.self, from: JSONEncoder().encode(journal()))
        #expect(try saved.transition(for: transition.target) == transition)
        #expect(saved.phase == .preparing)
        #expect(throws: (any Error).self) { try saved.transition(for: transition.source) }
        for invalid in [journal(hash: transition.source.sha256), journal(source: "4.1.1"),
                        journal(target: transition.source.version), journal(address: "")] {
            #expect(throws: (any Error).self) { try invalid.transition(for: transition.target) }
        }
    }

    @Test func existingDowngradeJournalStillDecodes() throws {
        let json = """
        {"address":"test-device","sha256":"c0f3a263011e14d3ad24f53661dc9c9c4e7f4a2171efff0e929f2053a0ffe3bd",
         "sourceVersion":"4.5.2","targetVersion":"2.0.0","started":0,"phase":"committing"}
        """
        let journal = try JSONDecoder().decode(FirmwareJournal.self, from: Data(json.utf8))
        #expect(try journal.transition(for: .xm3v200) == .downgrade)
        #expect(journal.phase == .committing)
    }

    @Test func commandsCannotMixWriteDirectionsOrPreviewModes() throws {
        for command in FirmwareCommand.allCases {
            #expect(try FirmwareCommand.parse(["OpenXM", command.rawValue, "image.bin"]) == command)
            for other in FirmwareCommand.allCases {
                #expect(throws: (any Error).self) { try FirmwareCommand.parse([command.rawValue, other.rawValue]) }
            }
            for preview in ["--demo", "--replay", "--probe", "--exercise", "--firmware-unknown"] {
                #expect(throws: (any Error).self) { try FirmwareCommand.parse([command.rawValue, preview]) }
            }
        }
        #expect(throws: (any Error).self) { try FirmwareCommand.parse([]) }
        #expect(throws: (any Error).self) { try FirmwareCommand.parse(["--firmware-unknown"]) }
    }

    // Firmware stays outside the repository. Opt in to full-image checks with the fetched local fixtures.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENXM_FIRMWARE_FIXTURES"] != nil))
    func verifiesRealImagesAndRejectsSingleByteCorruption() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPENXM_FIRMWARE_FIXTURES"]!)
        let expectedIDs: [FirmwareRelease: [UInt8]] = [.xm3v200: [0x8A, 0xDE, 0xC9, 0xAE], .xm3v452: [0x7D, 0x91, 0xFB, 0x64],
            .xm3v411: [0xFB, 0xC2, 0xA9, 0x1C], .xm3v422: [0xC8, 0x3B, 0x89, 0x9C]]
        for release in FirmwareRelease.allCases.filter({ $0.region == .international }) {
            let url = directory.appendingPathComponent("xm3-\(release.version).bin")
            let image = try FirmwareImage(url: url)
            #expect(image.release == release)
            #expect(image.syncID == expectedIDs[release])
            var damaged = Data(image.bytes)
            damaged[damaged.count / 2] ^= 1
            #expect(throws: (any Error).self) { try FirmwareImage(data: damaged) }
        }
    }
}

@MainActor
private final class ScriptedFirmwareLink: FirmwareLink {
    var incoming: [VMUPacket]
    var sent: [GAIAFrame] = []
    var failData = false
    var closed = false
    init(_ incoming: [VMUPacket]) { self.incoming = incoming }
    func command(_ command: UInt16, payload: [UInt8]) async throws -> [UInt8] {
        sent.append(GAIAFrame(command: command, payload: payload))
        if failData && command == 0x0642 && payload.first == 4 { throw TransportError.timeout("data ACK") }
        return []
    }
    func nextNotification(timeout: TimeInterval) async throws -> VMUPacket {
        guard !incoming.isEmpty else { throw TransportError.timeout("script exhausted") }
        return incoming.removeFirst()
    }
    func close() { closed = true }
    var vmu: [VMUPacket] { sent.filter { $0.command == 0x0642 }.compactMap { try? VMUPacket(bytes: $0.payload) } }
}

@MainActor
struct FirmwareTransferTests {
    private let id: [UInt8] = [0x8A, 0xDE, 0xC9, 0xAE]
    private func handshake(_ resume: UInt8 = 0, id: [UInt8]? = nil) -> [VMUPacket] {
        [VMUPacket(0x14, [resume] + (id ?? self.id) + [1]), VMUPacket(2, [0, 0x10, 0])]
    }
    private func request(_ count: Int, skip: Int = 0) -> VMUPacket {
        func be(_ n: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: n >> $0) } }
        return VMUPacket(3, be(count) + be(skip))
    }

    @Test(arguments: [[UInt8(0x8A), 0xDE, 0xC9, 0xAE], [UInt8(0x7D), 0x91, 0xFB, 0x64]])
    func transfersExactBytesAndCommitsAfterReboot(id: [UInt8]) async throws {
        let bytes = (0..<501).map { UInt8(truncatingIfNeeded: $0) }
        let initial = ScriptedFirmwareLink(handshake(id: id) + [request(600), VMUPacket(0x0B)])
        let rebooted = ScriptedFirmwareLink(handshake(3, id: id) + [VMUPacket(0x0F), VMUPacket(0x12)])
        let transfer = VMUTransfer(link: initial, bytes: bytes, syncID: id) { rebooted }
        try await transfer.run()
        let packets = initial.vmu.filter { $0.opcode == 4 }
        #expect(packets.map { $0.payload.count } == [251, 251, 2])
        #expect(packets.map { $0.payload[0] } == [0, 0, 1])
        #expect(packets.flatMap { $0.payload.dropFirst() } == bytes)
        #expect(initial.vmu.map(\.opcode) == [0x13, 1, 0x15, 4, 4, 4, 0x16, 0x0C])
        #expect(rebooted.vmu.map(\.opcode) == [0x13, 1, 0x0E, 0x10])
        #expect(transfer.phase == .complete)
        #expect(rebooted.sent.suffix(2).map(\.command) == [0x4002, 0x0641])
        #expect(initial.closed && rebooted.closed)
    }

    @Test func capturedXM3SyncCanStartTransferWithTheMatchingImage() async {
        let captured = try! VMUPacket(bytes: [0x14, 0, 5, 0] + id + [3])
        let link = ScriptedFirmwareLink([captured, VMUPacket(2, [0, 0x10, 0]), request(1)])
        link.failData = true
        let transfer = VMUTransfer(link: link, bytes: [0xAA], syncID: id) { link }
        await #expect(throws: (any Error).self) { try await transfer.run(allowResume: true) }
        #expect(link.vmu.map(\.opcode) == [0x13, 1, 0x15, 4])
    }

    @Test func handlesRelativeResumeOffsetWithoutPadding() async throws {
        let initial = ScriptedFirmwareLink(handshake() + [request(2, skip: 2), request(100), VMUPacket(0x0B)])
        let rebooted = ScriptedFirmwareLink(handshake(4) + [VMUPacket(0x12)])
        let transfer = VMUTransfer(link: initial, bytes: [0, 1, 2, 3, 4], syncID: id) { rebooted }
        try await transfer.run()
        #expect(initial.vmu.filter { $0.opcode == 4 }.map(\.payload) == [[0, 2, 3], [1, 4]])
    }

    @Test func missingDataAckNeverRetriesOrInstalls() async {
        let link = ScriptedFirmwareLink(handshake() + [request(3)])
        link.failData = true
        let transfer = VMUTransfer(link: link, bytes: [1, 2, 3], syncID: id) { throw FirmwareError.invalid("Unexpected reconnect") }
        await #expect(throws: (any Error).self) { try await transfer.run() }
        #expect(link.vmu.filter { $0.opcode == 4 }.count == 1)
        #expect(!link.vmu.contains { [0x0C, 0x10].contains($0.opcode) })
        #expect(transfer.phase != .complete)
        #expect(link.closed)
    }

    @Test func rejectsWrongIdentifierAndUnknownResumePoint() async {
        for payload: [UInt8] in [[0, 1, 2, 3, 4, 1], [5] + id + [1], [0] + id + [2], [0]] {
            let link = ScriptedFirmwareLink([VMUPacket(0x14, payload)])
            let transfer = VMUTransfer(link: link, bytes: [1], syncID: id) { link }
            await #expect(throws: (any Error).self) { try await transfer.run() }
            #expect(link.vmu.map(\.opcode) == [0x13])
        }
    }

    @Test func refusesMalformedAndOutOfRangeDataRequests() async {
        for packet in [request(0), request(10, skip: 3), VMUPacket(3, [0])] {
            let link = ScriptedFirmwareLink(handshake() + [packet])
            let transfer = VMUTransfer(link: link, bytes: [1, 2, 3], syncID: id) { link }
            await #expect(throws: (any Error).self) { try await transfer.run() }
            #expect(!link.vmu.contains { $0.opcode == 4 || $0.opcode == 0x0C })
        }
    }

    @Test func headsetErrorsAreAcknowledgedWithoutOverride() async {
        let link = ScriptedFirmwareLink([VMUPacket(0x11, [0, 0x81])])
        let transfer = VMUTransfer(link: link, bytes: [1], syncID: id) { link }
        await #expect(throws: (any Error).self) { try await transfer.run() }
        #expect(link.vmu.map(\.opcode) == [0x13, 0x1F])
        #expect(link.vmu.last?.payload == [0, 0x81])
    }

    @Test func resumeRequiresExplicitMode() async {
        let link = ScriptedFirmwareLink(handshake(4))
        let transfer = VMUTransfer(link: link, bytes: [1], syncID: id) { link }
        await #expect(throws: (any Error).self) { try await transfer.run() }
        #expect(link.vmu.map(\.opcode) == [0x13])
    }

    @Test func targetFirmwareCannotAccidentallyStartAnotherUpload() async {
        for resume: UInt8 in [0, 1, 2] {
            let link = ScriptedFirmwareLink(handshake(resume))
            let transfer = VMUTransfer(link: link, bytes: [1], syncID: id) { link }
            await #expect(throws: (any Error).self) { try await transfer.run(allowResume: true, allowDataTransfer: false) }
            #expect(link.vmu.map(\.opcode) == [0x13])
        }
    }

    @Test func provisionalTargetCanFinishItsCommitWithoutSendingData() async throws {
        let link = ScriptedFirmwareLink(handshake(4) + [VMUPacket(0x12)])
        let transfer = VMUTransfer(link: link, bytes: [1], syncID: id) { link }
        var persisted: [VMUTransfer.Phase] = []
        transfer.checkpoint = { phase in
            if phase == .committing { #expect(!link.vmu.contains { $0.opcode == 0x10 }) }
            if phase == .complete { #expect(!link.sent.contains { $0.command == 0x0641 }) }
            persisted.append(phase)
        }
        try await transfer.run(allowResume: true, allowDataTransfer: false)
        #expect(link.vmu.map(\.opcode) == [0x13, 1, 0x10])
        #expect(persisted == [.committing, .complete])
    }

    @Test func checkpointFailurePreventsInstall() async {
        let link = ScriptedFirmwareLink(handshake(2))
        let transfer = VMUTransfer(link: link, bytes: [1], syncID: id) { link }
        transfer.checkpoint = { _ in throw FirmwareError.invalid("Disk full") }
        await #expect(throws: (any Error).self) { try await transfer.run(allowResume: true) }
        #expect(!link.vmu.contains { $0.opcode == 0x0C || $0.opcode == 0x10 })
    }

    @Test func malformedCompletionCannotMarkTheSessionComplete() async {
        let link = ScriptedFirmwareLink(handshake(4) + [VMUPacket(0x12, [1])])
        let transfer = VMUTransfer(link: link, bytes: [1], syncID: id) { link }
        await #expect(throws: (any Error).self) { try await transfer.run(allowResume: true) }
        #expect(transfer.phase != .complete)
    }

    @Test func postInstallResetCannotRepeatTheTransfer() async {
        let initial = ScriptedFirmwareLink(handshake(2))
        let rebooted = ScriptedFirmwareLink(handshake(0))
        let transfer = VMUTransfer(link: initial, bytes: [1], syncID: id) { rebooted }
        await #expect(throws: (any Error).self) { try await transfer.run(allowResume: true) }
        #expect(rebooted.vmu.map(\.opcode) == [0x13])
    }
}
