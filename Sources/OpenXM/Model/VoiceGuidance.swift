import Foundation

/// Wire codes from MdrLanguage, not the ordinal positions in VoiceGuidanceLanguage.
/// Keep unknown codes intact so discovery never substitutes a different language.
struct GuidanceLanguage: RawRepresentable, Hashable, Identifiable, Sendable, Codable {
    let rawValue: UInt8
    var id: UInt8 { rawValue }
    var isKnown: Bool { (0x01...0x10).contains(rawValue) || rawValue == 0xF0 }

    var title: String {
        switch rawValue {
        case 0x00: "Unspecified"
        case 0x01: "English"
        case 0x02: "French"
        case 0x03: "German"
        case 0x04: "Spanish"
        case 0x05: "Italian"
        case 0x06: "Portuguese"
        case 0x07: "Dutch"
        case 0x08: "Swedish"
        case 0x09: "Finnish"
        case 0x0A: "Russian"
        case 0x0B: "Japanese"
        case 0x0C: "Simplified Chinese"
        case 0x0D: "Brazilian Portuguese"
        case 0x0E: "Traditional Chinese"
        case 0x0F: "Korean"
        case 0x10: "Turkish"
        case 0xF0: "Chinese"
        default: String(format: "Unknown language (0x%02X)", rawValue)
        }
    }
}

struct VoiceGuidanceCapability: Equatable, Sendable {
    let supportsOnOff: Bool
    let supportsLanguage: Bool
    let languages: [GuidanceLanguage]
}

/// Device-reported Automagic identifiers. These are discovery data, not a verified package offer.
/// Preserve the complete service IDs; never derive region compatibility from a language name.
struct GuidanceDownloadService: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let language: GuidanceLanguage
        let serviceID: String
    }
    let categoryID: String
    let serialNumber: String
    let entries: [Entry]
}

struct GuidanceUpdateMethod: Equatable, Sendable, Codable {
    let code: UInt8
    let parameters: [UInt8]

    var isCSR: Bool { (0x10...0x13).contains(code) }
    var transmitPower: Int? { isCSR && parameters.count == 2 ? Int(Int8(bitPattern: parameters[0])) : nil }
    var batteryThreshold: Int? { isCSR && parameters.count == 2 ? Int(parameters[1]) : nil }
}

struct VoiceGuidanceDetails: Equatable, Sendable {
    var language: GuidanceLanguage?
    var onOffAvailable: Bool?
    /// Sony's changeUpdateStatus callback sets this before/after a language transfer.
    /// It is not an authorization or a capability flag for starting a new installation.
    var languageUpdateEnabled: Bool?
    /// Kept in wire units until the time conversion is established; not displayed as an estimate.
    var requiredTime: UInt8?
    var downloadService: GuidanceDownloadService?
    var updateMethod: GuidanceUpdateMethod?
}
