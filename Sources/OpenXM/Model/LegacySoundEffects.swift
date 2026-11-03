import Foundation

/// VPT preset names can be supplied by the headphones; preserve unknown advertised presets.
struct SurroundPreset: Identifiable, Equatable, Sendable {
    let id: UInt8
    let name: String

    static func displayName(for id: UInt8) -> String {
        switch id {
        case 0: "Off"
        case 1: "Outdoor Festival"
        case 2: "Arena"
        case 3: "Concert Hall"
        case 4: "Club"
        default: String(format: "Preset %02X", id)
        }
    }
}

/// Positions defined for Sony's SOUND_POSITION TYPE1 capability.
enum SoundPosition: UInt8, CaseIterable, Identifiable, Codable, Sendable {
    case off = 0x00
    case frontLeft = 0x01
    case frontRight = 0x02
    case front = 0x03
    case rearLeft = 0x11
    case rearRight = 0x12

    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .frontLeft: "Front Left"
        case .frontRight: "Front Right"
        case .front: "Front"
        case .rearLeft: "Rear Left"
        case .rearRight: "Rear Right"
        }
    }
}
