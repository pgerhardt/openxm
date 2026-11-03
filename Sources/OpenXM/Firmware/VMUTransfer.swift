import Foundation

/// Device-directed CSR VM Upgrade state machine. Transport ACKs and upgrade notifications are separate.
/// The caller must validate the original package, bind it to fresh device identity and obtain confirmation.
@MainActor
final class VMUTransfer {
    enum Phase: String, Codable { case preparing, transferring, validating, rebooting, committing, complete }
    private(set) var phase: Phase = .preparing
    private(set) var offset = 0
    private var link: FirmwareLink
    private let bytes: [UInt8]
    private let syncID: [UInt8]
    private let reconnect: () async throws -> FirmwareLink
    var report: ((Phase, Int, Int) -> Void)?
    /// Persist the phase before its first device mutation. A failed checkpoint stops the transfer.
    var checkpoint: ((Phase) throws -> Void)?

    init(link: FirmwareLink, bytes: [UInt8], syncID: [UInt8], reconnect: @escaping () async throws -> FirmwareLink) {
        self.link = link; self.bytes = bytes; self.syncID = syncID; self.reconnect = reconnect
    }

    func run(allowResume: Bool = false, allowDataTransfer: Bool = true) async throws {
        guard !bytes.isEmpty, syncID.count == 4 else { throw FirmwareError.invalid("Missing update package data.") }
        defer { link.close() }
        let permitted: [UInt8] = allowResume ? (allowDataTransfer ? [0, 1, 2, 3, 4] : [3, 4]) : [0]
        guard allowResume || allowDataTransfer else { throw FirmwareError.invalid("A fresh transfer is not permitted on a device already reporting the target.") }
        var resume = try await handshake(permitted: permitted)
        // A reconnect is expected only after the device validates the image and installation is requested.
        // Unexpected disconnects elsewhere fail the session; a subsequent explicit resume uses the same image ID.
        for _ in 0..<3 {
            switch resume {
            case 0:
                offset = 0
                try setPhase(.transferring)
                try await send(0x15)
                while offset < bytes.count {
                    let request = try await receive(0x03)
                    guard request.payload.count == 8 else { throw FirmwareError.invalid("Invalid update data request.") }
                    let count = Self.u32(request.payload, at: 0)
                    let skip = Self.u32(request.payload, at: 4)
                    guard count > 0, skip < bytes.count - offset else {
                        throw FirmwareError.invalid("Update data request is outside the image.")
                    }
                    offset += skip
                    var remaining = min(count, bytes.count - offset)
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let length = min(250, remaining)
                        let end = offset + length
                        try await send(0x04, [end == bytes.count ? 1 : 0] + Array(bytes[offset..<end]))
                        offset = end; remaining -= length
                        report?(phase, offset, bytes.count)
                    }
                }
                try await validate()
            case 1:
                try await validate()
            case 2:
                break // Device already validated the image associated with our sync identifier.
            case 3:
                try setPhase(.committing)
                try await send(0x0E, [0])
                let result = try await receiveOneOf([0x0F, 0x12])
                guard result.payload.isEmpty else { throw FirmwareError.invalid("Malformed update commit response.") }
                if result.opcode == 0x0F { try await commit() }
                try await finish()
                return
            case 4:
                try setPhase(.committing)
                try await commit()
                try await finish()
                return
            default:
                throw FirmwareError.invalid("Unknown update resume point \(resume).")
            }
            try setPhase(.rebooting)
            do { try await send(0x0C, [0]) }
            catch TransportError.closedByRemote { /* Reboot may precede the transport ACK. */ }
            link.close()
            link = try await reconnect()
            resume = try await handshake(permitted: [3, 4])
        }
        throw FirmwareError.invalid("Package installation did not finish.")
    }

    private func handshake(permitted: [UInt8]) async throws -> UInt8 {
        _ = try await link.command(0x0640, payload: [])
        _ = try await link.command(0x4001, payload: [0x12])
        try await send(0x13, syncID)
        let sync = try await receive(0x14)
        guard sync.payload.count == 6, Array(sync.payload[1...4]) == syncID,
              sync.payload[0] <= 4, [1, 3].contains(sync.payload[5]) else {
            throw FirmwareError.invalid("The headset returned a different update package identifier or unsupported upgrade protocol.")
        }
        guard permitted.contains(sync.payload[0]) else {
            throw FirmwareError.invalid("Update resume point \(sync.payload[0]) is not permitted for this session. No start, data or commit request was sent.")
        }
        var ready = false
        for attempt in 0..<5 {
            try await send(0x01)
            let start = try await receive(0x02)
            guard start.payload.count == 3 else { throw FirmwareError.invalid("Invalid upgrade-start response.") }
            if start.payload[0] == 0 { ready = true; break }
            guard start.payload[0] == 1, attempt < 4 else {
                throw FirmwareError.invalid("The headset is not ready to update.")
            }
            try await Task.sleep(for: .seconds(2))
        }
        guard ready else { throw FirmwareError.invalid("The headset is not ready to update.") }
        return sync.payload[0]
    }

    private func validate() async throws {
        try setPhase(.validating)
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try await send(0x16)
            let response = try await receiveOneOf([0x17, 0x0B])
            if response.opcode == 0x0B {
                guard response.payload.isEmpty else { throw FirmwareError.invalid("Malformed validation completion.") }
                return
            }
            guard response.payload.count == 2 else { throw FirmwareError.invalid("Invalid validation delay.") }
            let delay = Int(response.payload[0]) << 8 | Int(response.payload[1])
            try await Task.sleep(for: .milliseconds(min(10_000, max(100, delay))))
        }
        throw FirmwareError.invalid("Package validation timed out. Installation was not requested.")
    }

    private func commit() async throws {
        try await send(0x10, [0])
        let complete = try await receive(0x12)
        guard complete.payload.isEmpty else { throw FirmwareError.invalid("Malformed update completion.") }
    }

    private func finish() async throws {
        // Save completion before cleanup/read-back, so retrying cannot rewrite an already committed image.
        try setPhase(.complete)
        do {
            _ = try await link.command(0x4002, payload: [0x12])
            _ = try await link.command(0x0641, payload: [])
        } catch TransportError.closedByRemote { /* Completion was already received and persisted. */ }
    }

    private func send(_ opcode: UInt8, _ payload: [UInt8] = []) async throws {
        _ = try await link.command(0x0642, payload: VMUPacket(opcode, payload).encoded())
    }

    private func receive(_ opcode: UInt8) async throws -> VMUPacket { try await receiveOneOf([opcode]) }

    private func receiveOneOf(_ expected: [UInt8]) async throws -> VMUPacket {
        let packet = try await link.nextNotification(timeout: 60)
        if packet.opcode == 0x11 {
            guard packet.payload.count == 2 else { throw FirmwareError.invalid("Malformed update error.") }
            try await send(0x1F, packet.payload)
            throw FirmwareError.invalid(String(format: "Headset rejected the upgrade (VMU error %02X%02X). No error override was sent.", packet.payload[0], packet.payload[1]))
        }
        guard expected.contains(packet.opcode) else {
            throw FirmwareError.invalid(String(format: "Unexpected update response %02X.", packet.opcode))
        }
        return packet
    }

    private func setPhase(_ value: Phase) throws {
        try checkpoint?(value)
        phase = value
        report?(phase, offset, bytes.count)
    }
    private static func u32(_ bytes: [UInt8], at offset: Int) -> Int {
        bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
}
