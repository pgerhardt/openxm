import Foundation

/// CSR GAIA BR/EDR framing; distinct from Sony's MDR control frames.
/// Wire-format references and the pinned research revisions are in docs/FIRMWARE.md.
struct GAIAFrame: Equatable {
    let vendor: UInt16
    let command: UInt16
    let payload: [UInt8]

    init(vendor: UInt16 = 0x000A, command: UInt16, payload: [UInt8] = []) {
        self.vendor = vendor; self.command = command; self.payload = payload
    }

    func encoded(checksum: Bool = false) throws -> [UInt8] {
        guard payload.count <= 254 else { throw FirmwareError.invalid("GAIA payload exceeds 254 bytes.") }
        var bytes: [UInt8] = [0xFF, 1, checksum ? 1 : 0, UInt8(payload.count),
                             UInt8(vendor >> 8), UInt8(truncatingIfNeeded: vendor),
                             UInt8(command >> 8), UInt8(truncatingIfNeeded: command)] + payload
        if checksum { bytes.append(bytes.reduce(0, ^)) }
        return bytes
    }
}

struct GAIAFrameAssembler {
    private var buffer: [UInt8] = []
    mutating func feed(_ bytes: [UInt8]) throws -> [GAIAFrame] {
        var frames: [GAIAFrame] = []
        // Incremental consumption bounds retained data to one frame, even for a large input.
        for byte in bytes {
            if buffer.isEmpty && byte != 0xFF { continue }
            buffer.append(byte)
            guard buffer.count >= 4 else { continue }
            guard buffer[1] == 1, buffer[2] & 0xFE == 0, buffer[3] <= 254 else {
                buffer.removeAll()
                throw FirmwareError.invalid("Invalid GAIA frame header.")
            }
            let count = 8 + Int(buffer[3]) + Int(buffer[2] & 1)
            guard buffer.count == count else { continue }
            if buffer[2] & 1 != 0 && buffer.reduce(0, ^) != 0 {
                buffer.removeAll()
                throw FirmwareError.invalid("GAIA checksum mismatch.")
            }
            frames.append(GAIAFrame(vendor: UInt16(buffer[4]) << 8 | UInt16(buffer[5]),
                                    command: UInt16(buffer[6]) << 8 | UInt16(buffer[7]),
                                    payload: Array(buffer[8..<(8 + Int(buffer[3]))])))
            buffer.removeAll(keepingCapacity: true)
        }
        return frames
    }
}

struct VMUPacket: Equatable {
    let opcode: UInt8
    let payload: [UInt8]
    init(_ opcode: UInt8, _ payload: [UInt8] = []) { self.opcode = opcode; self.payload = payload }
    init(bytes: [UInt8]) throws {
        guard bytes.count >= 3 else { throw FirmwareError.invalid("Invalid VM Upgrade packet length.") }
        let declaredLength = Int(bytes[1]) << 8 | Int(bytes[2])
        // WH-1000XM3 4.5.2: 14 00 05 <resume><id:4> 03. Its sync header counts only
        // resume + identifier; the protocol-version extension lies outside that count. Sony's
        // reader consumes the declared bytes and ignores this extension. Do not relax other packets.
        let xm3SyncExtension = bytes[0] == 0x14 && declaredLength == 5 && bytes.count == 9 && bytes[8] == 3
        guard declaredLength == bytes.count - 3 || xm3SyncExtension else {
            throw FirmwareError.invalid("Invalid VM Upgrade packet length.")
        }
        self.opcode = bytes[0]; self.payload = Array(bytes.dropFirst(3))
    }
    func encoded() throws -> [UInt8] {
        guard payload.count <= 251 else { throw FirmwareError.invalid("VM Upgrade payload is too large.") }
        return [opcode, UInt8(payload.count >> 8), UInt8(truncatingIfNeeded: payload.count)] + payload
    }
}
