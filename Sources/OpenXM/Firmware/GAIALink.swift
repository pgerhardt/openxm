import Foundation
import IOBluetooth

@MainActor
protocol FirmwareLink: AnyObject {
    func command(_ command: UInt16, payload: [UInt8]) async throws -> [UInt8]
    func nextNotification(timeout: TimeInterval) async throws -> VMUPacket
    func close()
}

@MainActor
final class GAIALink: FirmwareLink, RFCOMMTransportDelegate {
    private let transport: RFCOMMTransport
    private var assembler = GAIAFrameAssembler()
    private var pending: (command: UInt16, shot: OneShot<[UInt8]>)?
    private var notificationWaiter: OneShot<VMUPacket>?
    private var notifications: [VMUPacket] = []
    private var failure: Error?
    private let gate = AsyncSerialGate()
    var trace: ((String) -> Void)?

    init(transport: RFCOMMTransport) {
        precondition(transport.family == nil)
        self.transport = transport
        transport.delegate = self
    }

    func command(_ command: UInt16, payload: [UInt8] = []) async throws -> [UInt8] {
        try await gate.run {
            if let failure = self.failure { throw failure }
            let shot = OneShot<[UInt8]>()
            self.pending = (command, shot)
            defer { self.pending = nil }
            let isFirmwareData = command == 0x0642 && payload.first == 0x04
            if !isFirmwareData { self.trace?(String(format: "GAIA TX %04X: %@", command, payload.hex)) }
            // No blind retransmission: a missed ACK for flash data leaves the result uncertain.
            do {
                try self.transport.write(GAIAFrame(command: command, payload: payload).encoded())
                let acknowledgement = String(format: "GAIA %04X acknowledgement", command)
                shot.deadline(15, error: TransportError.timeout(acknowledgement)) { [weak self] in
                    self?.fail(TransportError.timeout(acknowledgement))
                }
                let response = try await withTaskCancellationHandler { try await shot.value() } onCancel: {
                    Task { @MainActor in self.fail(CancellationError()) }
                }
                if !isFirmwareData { self.trace?(String(format: "GAIA ACK %04X: %@", command, response.hex)) }
                return response
            } catch { self.fail(error); throw error }
        }
    }

    func nextNotification(timeout: TimeInterval = 30) async throws -> VMUPacket {
        try Task.checkCancellation()
        if let failure { throw failure }
        if !notifications.isEmpty { return notifications.removeFirst() }
        guard notificationWaiter == nil else { throw FirmwareError.invalid("Concurrent firmware notification consumers.") }
        let shot = OneShot<VMUPacket>()
        notificationWaiter = shot
        defer { notificationWaiter = nil }
        shot.deadline(timeout, error: TransportError.timeout("firmware response")) { [weak self] in
            self?.fail(TransportError.timeout("firmware response"))
        }
        return try await withTaskCancellationHandler { try await shot.value() } onCancel: {
            Task { @MainActor in self.fail(CancellationError()) }
        }
    }

    func close() { fail(TransportError.closedByRemote) }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        pending?.shot.resolve(.failure(error))
        notificationWaiter?.resolve(.failure(error))
        notifications.removeAll()
        transport.close()
    }

    func transport(_ transport: RFCOMMTransport, didReceive bytes: [UInt8]) {
        guard failure == nil else { return }
        do {
            for frame in try assembler.feed(bytes) {
                guard frame.vendor == 0x000A else { continue }
                if frame.command == 0x4003 {
                    guard frame.payload.first == 0x12 else { continue }
                    let packet: VMUPacket
                    do { packet = try VMUPacket(bytes: Array(frame.payload.dropFirst())) }
                    catch {
                        trace?("Malformed GAIA VMU notification: \(frame.payload.hex)")
                        throw error
                    }
                    if packet.opcode != 0x03 { trace?(String(format: "VMU RX %02X: %@", packet.opcode, packet.payload.hex)) }
                    try transport.write(GAIAFrame(command: 0xC003, payload: [0]).encoded())
                    if let waiter = notificationWaiter, !waiter.isResolved {
                        waiter.resolve(.success(packet))
                    } else {
                        guard notifications.count < 32 else { throw FirmwareError.invalid("Unexpected firmware notification flood.") }
                        notifications.append(packet)
                    }
                } else if frame.command & 0x8000 != 0 {
                    guard let pending, frame.command == pending.command | 0x8000 else { continue }
                    guard let status = frame.payload.first else { throw FirmwareError.invalid("Empty GAIA acknowledgement.") }
                    guard status == 0 else {
                        throw FirmwareError.invalid(String(format: "GAIA command %04X failed with status %02X.", pending.command, status))
                    }
                    pending.shot.resolve(.success(Array(frame.payload.dropFirst())))
                }
            }
        } catch { fail(error) }
    }

    func transportDidClose(_ transport: RFCOMMTransport, error: TransportError) { fail(error) }
}
