import Foundation

/// V1 NC Optimizer values from Sony's OptimizerStatus, not inferred from command ACKs.
enum OptimizerPhase: Equatable, Sendable {
    case idle, measuringPersonal, measuringPressure, running, finished
    case unknown(UInt8?)

    init(byte: UInt8) {
        switch byte {
        case 0x00: self = .idle
        case 0x01: self = .measuringPersonal
        case 0x02: self = .measuringPressure
        case 0x10: self = .running
        case 0x11: self = .finished
        default: self = .unknown(byte)
        }
    }

    var isActive: Bool {
        switch self {
        case .measuringPersonal, .measuringPressure, .running: true
        default: false
        }
    }

    var canStart: Bool { self == .idle || self == .finished }

    var title: String {
        switch self {
        case .idle: "Ready"
        case .measuringPersonal: "Measuring personal fit…"
        case .measuringPressure: "Measuring air pressure…"
        case .running: "Optimizing…"
        case .finished: "Optimization complete"
        case .unknown: "Optimizer status unavailable"
        }
    }
}

struct NoiseOptimizerCapability: Equatable, Sendable {
    let optimizationSeconds: Int
    let personalMeasurement: Bool
    let personalSeconds: Int
    let pressureMeasurement: Bool
    let pressureSeconds: Int

    var estimatedSeconds: Int {
        optimizationSeconds + (personalMeasurement ? personalSeconds : 0) + (pressureMeasurement ? pressureSeconds : 0)
    }
}

/// Fixed V1 table-1 layouts: cg (capability), ci/bb (status), ch/ba (results), dj (control).
enum V1NoiseOptimizer {
    struct Status: Equatable {
        let available: Bool?
        let phase: OptimizerPhase
    }

    struct Measurements: Equatable {
        let personal: Bool?
        let pressure: Int?
    }

    static func capability(_ p: [UInt8]) -> NoiseOptimizerCapability? {
        guard p.count == 7, p[0] == 0x81, p[1] == 1, p[3] <= 1, p[5] <= 1 else { return nil }
        return .init(optimizationSeconds: Int(p[2]), personalMeasurement: p[3] == 1,
                     personalSeconds: Int(p[4]), pressureMeasurement: p[5] == 1, pressureSeconds: Int(p[6]))
    }

    static func status(_ p: [UInt8]) -> Status? {
        guard p.count == 4, [0x83, 0x85].contains(p[0]), p[1] == 1 else { return nil }
        return .init(available: p[2] == 0 ? true : (p[2] == 1 ? false : nil), phase: .init(byte: p[3]))
    }

    static func measurements(_ p: [UInt8], capability: NoiseOptimizerCapability?) -> Measurements? {
        guard p.count == 6, [0x87, 0x89].contains(p[0]), p[1] == 1, let capability,
              p[2] == (capability.personalMeasurement ? 1 : 0),
              p[4] == (capability.pressureMeasurement ? 1 : 0) else { return nil }
        return .init(personal: p[2] == 1 && p[3] <= 1 ? p[3] == 1 : nil,
                     pressure: p[4] == 1 && (7...10).contains(p[5]) ? Int(p[5]) : nil)
    }

    static func control(start: Bool, supported: Bool, capability: NoiseOptimizerCapability?, status: Status) throws -> [UInt8] {
        guard supported, capability != nil else { throw DriverError.unsupported("NC Optimizer") }
        if start, status.available != true { throw DriverError.unsupported("NC Optimizer is currently unavailable") }
        guard start ? status.phase.canStart : status.phase.isActive else {
            throw DriverError.unsupported(start ? "Wait until the NC Optimizer is ready" : "NC Optimizer is not running")
        }
        return [0x84, 0x01, 0x00, start ? 0x01 : 0x00]
    }

    @MainActor
    static func perform(start: Bool, supported: Bool, capability: NoiseOptimizerCapability?,
                        request: ([UInt8], MDRLink.Matcher) async throws -> [UInt8]) async throws {
        guard supported, capability != nil else { throw DriverError.unsupported("NC Optimizer") }
        let current = try await request([0x82, 0x01], .init(.dataMdr, 0x83, 0x01))
        guard let currentStatus = status(current) else {
            throw DriverError.unsupported("The headphones did not report a valid optimizer status")
        }
        let payload = try control(start: start, supported: supported, capability: capability, status: currentStatus)
        // The transport registers this notification waiter before transmitting. An ACK is not progress.
        let reply = try await request(payload, .init(.dataMdr, 0x85, 0x01))
        guard let confirmed = status(reply),
              start ? (confirmed.phase.isActive || confirmed.phase == .finished) : confirmed.phase.canStart else {
            throw DriverError.unsupported(start ? "The headphones did not confirm optimization started" : "The headphones did not confirm optimization stopped")
        }
    }
}
