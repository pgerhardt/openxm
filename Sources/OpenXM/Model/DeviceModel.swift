import Foundation

// MARK: - Noise control

enum NoiseMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case noiseCancelling
    case windReduction
    case ambient
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noiseCancelling: "Noise Canceling"
        case .windReduction: "Wind Reduction"
        case .ambient: "Ambient Sound"
        case .off: "Off"
        }
    }

    var shortTitle: String {
        switch self {
        case .noiseCancelling: "Noise Canceling"
        case .windReduction: "Wind"
        case .ambient: "Ambient"
        case .off: "Off"
        }
    }

    var symbol: String {
        switch self {
        case .noiseCancelling: "person.wave.2.fill"
        case .windReduction: "wind"
        case .ambient: "ear.and.waveform"
        case .off: "circle.slash"
        }
    }
}

enum AdaptiveSensitivity: UInt8, Codable, CaseIterable, Sendable, Identifiable {
    case standard = 0x00, high = 0x01, low = 0x02
    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .high: "High"
        case .low: "Low"
        }
    }
}

struct NoiseControl: Equatable, Codable, Sendable {
    var mode: NoiseMode
    /// Ambient level as presented by Sony (V1: 1…20, V2: 0…20). Kept when NC/off so it is restored later.
    var ambientLevel: Int
    var focusOnVoice: Bool
    /// V2 noise-adaptive "auto ambient" (WH-1000XM6 class). Ignored on V1.
    var autoAmbient: Bool = false
    var adaptiveSensitivity: AdaptiveSensitivity = .standard
    /// The mode the headset returns to when switched back on (V1 keeps it while off).
    var lastActiveMode: NoiseMode = .noiseCancelling

    init(mode: NoiseMode, ambientLevel: Int, focusOnVoice: Bool, autoAmbient: Bool = false,
         adaptiveSensitivity: AdaptiveSensitivity = .standard, lastActiveMode: NoiseMode? = nil) {
        self.mode = mode
        self.ambientLevel = ambientLevel
        self.focusOnVoice = focusOnVoice
        self.autoAmbient = autoAmbient
        self.adaptiveSensitivity = adaptiveSensitivity
        self.lastActiveMode = lastActiveMode ?? (mode == .off ? .noiseCancelling : mode)
    }
}

struct NoiseControlCapability: Equatable, Sendable {
    var modes: [NoiseMode]
    var ambientRange: ClosedRange<Int>
    var supportsVoiceFocus: Bool
    var supportsAutoAmbient: Bool
}

// MARK: - Battery

enum ChargingState: Sendable, Equatable {
    case notCharging, charging, charged, unknown
}

struct BatteryReading: Sendable, Equatable {
    var level: Int
    var charging: ChargingState
}

struct BatteryState: Sendable, Equatable {
    var main: BatteryReading?
    var left: BatteryReading?
    var right: BatteryReading?
    var chargingCase: BatteryReading?

    var headlineLevel: Int? { main?.level ?? [left?.level, right?.level].compactMap { $0 }.min() }
    var isCharging: Bool { [main, left, right].contains { $0?.charging == .charging } }
}

// MARK: - Equalizer

struct EqualizerPreset: Identifiable, Hashable, Sendable, Codable {
    let id: UInt8
    let name: String

    static func displayName(for id: UInt8) -> String {
        switch id {
        case 0x00: "Off"
        case 0x01: "Rock"
        case 0x02: "Pop"
        case 0x03: "Jazz"
        case 0x04: "Dance"
        case 0x05: "EDM"
        case 0x06: "R&B/Hip-Hop"
        case 0x07: "Acoustic"
        case 0x10: "Bright"
        case 0x11: "Excited"
        case 0x12: "Mellow"
        case 0x13: "Relaxed"
        case 0x14: "Vocal"
        case 0x15: "Treble Boost"
        case 0x16: "Bass Boost"
        case 0x17: "Speech"
        case 0x20: "Gaming"
        case 0x21: "FPS 1"
        case 0x22: "FPS 2"
        case 0x23: "FPS 3"
        case 0x30: "Heavy"
        case 0x31: "Clear"
        case 0x32: "Hard"
        case 0x33: "Soft"
        case 0xA0: "Manual"
        case 0xA1...0xA5: "Custom \(id - 0xA0)"
        case 0xB0...0xBB: "Artist \(id - 0xAF)"
        default: String(format: "Preset %02X", id)
        }
    }

    /// Manual and the user slots store their own band values; the rest are fixed curves.
    var isEditable: Bool { id >= 0xA0 && id <= 0xA5 }
}

struct EqualizerState: Equatable, Sendable, Codable {
    var presetID: UInt8
    /// Band offsets in device steps (V1 five-band: -10…+10, V2 ten-band: -6…+6).
    var bands: [Int]
    /// Clear Bass (five-band models): -10…+10.
    var clearBass: Int?
}

struct EqualizerCapability: Equatable, Sendable {
    var presets: [EqualizerPreset]
    var bandCount: Int
    var bandRange: ClosedRange<Int>
    var hasClearBass: Bool
    /// All-slot capture/restore is enabled only for a protocol layout whose curve writes are understood.
    var supportsCustomBank: Bool = true
    /// Fixed-preset configurations do not accept band changes.
    var supportsBandEditing: Bool = true

    var bandLabels: [String] {
        bandCount == 10
            ? ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
            : ["400", "1k", "2.5k", "6.3k", "16k"]
    }
}

// MARK: - Listening mode (V2)

enum RoomSize: UInt8, Codable, CaseIterable, Sendable, Identifiable {
    case small = 0x00, middle = 0x01, large = 0x02
    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .small: "My Room"
        case .middle: "Living Room"
        case .large: "Café"
        }
    }
}

enum ListeningMode: Equatable, Codable, Sendable {
    case standard
    case backgroundMusic(RoomSize)
    case cinema

    var title: String {
        switch self {
        case .standard: "Standard"
        case .backgroundMusic: "Background Music"
        case .cinema: "Cinema"
        }
    }
}

struct ListeningModeCapability: Equatable, Sendable {
    var backgroundMusic: Bool
    var cinema: Bool
}

// MARK: - Speak-to-Chat

enum ChatSensitivity: UInt8, Codable, CaseIterable, Sendable, Identifiable {
    case auto = 0x00, high = 0x01, low = 0x02
    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .high: "High"
        case .low: "Low"
        }
    }
}

enum ChatTimeout: UInt8, Codable, CaseIterable, Sendable, Identifiable {
    case short = 0x00, standard = 0x01, long = 0x02, never = 0x03
    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .short: "Short"
        case .standard: "Standard"
        case .long: "Long"
        case .never: "Don't end automatically"
        }
    }

    /// Label using the seconds the headset reported for this index (XM4: 15 s / 30 s / 1 min / never).
    func title(reportedSeconds: [UInt8]) -> String {
        guard self != .never, Int(rawValue) < reportedSeconds.count else { return title }
        let seconds = Int(reportedSeconds[Int(rawValue)])
        guard seconds > 0 else { return title }
        let amount = seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
        return "\(title) (about \(amount))"
    }
}

struct SpeakToChat: Equatable, Codable, Sendable {
    var enabled: Bool
    var sensitivity: ChatSensitivity?
    var timeout: ChatTimeout?
    /// V1 carries a voice-focus flag inside the same extended parameter; preserved verbatim on writes.
    var voiceFocus: Bool?
}

// MARK: - Power

struct AutoPowerOffOption: Identifiable, Hashable, Sendable {
    let id: UInt8
    var title: String {
        switch id {
        case 0x00: "After 5 minutes"
        case 0x01: "After 30 minutes"
        case 0x02: "After 1 hour"
        case 0x03: "After 3 hours"
        case 0x04: "After 15 minutes"
        case 0x10: "When taken off"
        case 0x11: "Don't turn off"
        default: String(format: "Option %02X", id)
        }
    }
}

// MARK: - Audio

enum AudioCodec: UInt8, Sendable {
    case unsettled = 0x00, sbc = 0x01, aac = 0x02, ldac = 0x10, aptX = 0x20, aptXHD = 0x21, lc3 = 0x30, other = 0xFF
    var title: String {
        switch self {
        case .unsettled: "—"
        case .sbc: "SBC"
        case .aac: "AAC"
        case .ldac: "LDAC"
        case .aptX: "aptX"
        case .aptXHD: "aptX HD"
        case .lc3: "LC3"
        case .other: "Other"
        }
    }
}

enum ConnectionPriority: UInt8, Codable, Sendable, CaseIterable, Identifiable {
    case soundQuality = 0x00, stableConnection = 0x01
    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .soundQuality: "Prioritize Sound Quality"
        case .stableConnection: "Prioritize Stable Connection"
        }
    }
}

struct UpscalingState: Equatable, Sendable {
    var enabled: Bool
    /// Live indicator: DSEE is currently processing the stream.
    var active: Bool?
}

// MARK: - General settings, buttons, devices

/// V1 list values are positions in the device's list, not ButtonFunction wire IDs.
struct GeneralSettingOption: Identifiable, Equatable, Sendable {
    let index: UInt8
    let key: String
    let summaryKey: String
    var id: UInt8 { index }

    var title: String {
        switch key {
        case "ASSIGNABLE_KEY_ELEM_NCASM": "Ambient Sound Control"
        case "ASSIGNABLE_KEY_ELEM_GOOGLE_ASSISTANT": "Google Assistant"
        case "ASSIGNABLE_KEY_ELEM_AMAZON_ALEXA": "Amazon Alexa"
        case "ASSIGNABLE_KEY_ELEM_TENCENT_XIAOWEI": "Tencent Xiaowei"
        default: key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }
}

struct GeneralSetting: Identifiable, Equatable, Sendable {
    let slot: UInt8
    var key: String
    var summaryKey: String
    var isBoolean: Bool
    var value: Bool?
    var options: [GeneralSettingOption] = []
    var selectedIndex: UInt8?
    var id: UInt8 { slot }
    var isList: Bool { !isBoolean && !options.isEmpty }
    var isButtonAssignment: Bool { key == "ASSIGNABLE_KEY_SETTING" }
    var selectedOption: GeneralSettingOption? { options.first { $0.index == selectedIndex } }

    var title: String {
        switch key {
        case "TOUCH_PANEL_SETTING": "Touch Sensor Control Panel"
        case "MULTIPOINT_SETTING": "Connect to 2 Devices Simultaneously"
        case "SIDETONE_SETTING": "Capture Voice During a Phone Call"
        case "ASSIGNABLE_KEY_SETTING": "NC/AMBIENT Button"
        default:
            key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }

    var detail: String {
        switch key {
        // Only consequences the user must know before changing a setting.
        case "MULTIPOINT_SETTING": "Changing this reconnects the headphones."
        default: ""
        }
    }

    var symbol: String {
        switch key {
        case "TOUCH_PANEL_SETTING": "hand.tap"
        case "MULTIPOINT_SETTING": "laptopcomputer.and.iphone"
        case "SIDETONE_SETTING": "phone.bubble"
        default: "switch.2"
        }
    }
}

enum ButtonFunction: UInt8, Sendable, Identifiable {
    case ambientSoundControl = 0x00
    case volumeControl = 0x10
    case playbackControl = 0x20
    case voiceRecognition = 0x30
    case googleAssistant = 0x31
    case amazonAlexa = 0x32
    case tencentXiaowei = 0x33
    case noFunction = 0xFF

    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .ambientSoundControl: "Ambient Sound Control"
        case .volumeControl: "Volume Control"
        case .playbackControl: "Playback Control"
        case .voiceRecognition: "Voice Assistant (device)"
        case .googleAssistant: "Google Assistant"
        case .amazonAlexa: "Amazon Alexa"
        case .tencentXiaowei: "Tencent Xiaowei"
        case .noFunction: "No Function"
        }
    }
    var symbol: String {
        switch self {
        case .ambientSoundControl: "circle.lefthalf.filled"
        case .volumeControl: "speaker.wave.2"
        case .playbackControl: "playpause"
        case .voiceRecognition: "mic"
        case .googleAssistant, .amazonAlexa, .tencentXiaowei: "bubble.left.and.text.bubble.right"
        case .noFunction: "nosign"
        }
    }
}

struct AssignableKey: Identifiable, Equatable, Sendable {
    let index: Int
    let key: UInt8
    let keyType: UInt8
    let defaultPreset: UInt8
    let options: [UInt8]
    var id: Int { index }

    var title: String {
        switch key {
        case 0x00: "Left"
        case 0x01: "Right"
        case 0x02: "CUSTOM Button"
        case 0x03: "C Button"
        case 0x04, 0x05: "NC/AMB Button"
        default: String(format: "Key %02X", key)
        }
    }
}

/// V2 NC/AMB toggle-button cycle (WH-1000XM5/XM6 "NC_AMB_TOGGLE").
enum NcAmbButtonCycle: UInt8, Sendable, CaseIterable, Identifiable {
    case ncAmbientOff = 0x01
    case ncAmbient = 0x02
    case ncOff = 0x03
    case ambientOff = 0x04
    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .ncAmbientOff: "Noise Canceling → Ambient → Off"
        case .ncAmbient: "Noise Canceling ↔ Ambient"
        case .ncOff: "Noise Canceling ↔ Off"
        case .ambientOff: "Ambient ↔ Off"
        }
    }
}

struct PairedDevice: Identifiable, Equatable, Sendable {
    let address: String
    var name: String
    var connected: Bool
    var isPlaybackSource: Bool
    var id: String { address }
}

enum PlaybackStatus: UInt8, Sendable {
    case unsettled = 0x00, playing = 0x01, paused = 0x02, stopped = 0x03
}

struct NowPlaying: Equatable, Sendable {
    private(set) var metadata: PlaybackMetadata?
    private(set) var metadataReportedAt: Date?
    var title: String? { metadata?.title }
    var artist: String? { metadata?.artist }
    var album: String? { metadata?.album }
    private(set) var status: PlaybackStatus?
    private(set) var statusReportedAt: Date?
    private var musicPlayback = false
    var volume: Int?

    mutating func receiveMetadata(_ value: PlaybackMetadata?, at date: Date = Date()) {
        metadata = value
        metadataReportedAt = value == nil ? nil : date
    }

    mutating func expireMetadata(at date: Date = Date()) {
        guard let metadataReportedAt else { return }
        let age = date.timeIntervalSince(metadataReportedAt)
        if age < 0 || age >= 90 { receiveMetadata(nil) }
    }

    mutating func receivePlaybackStatus(_ value: PlaybackStatus?, music: Bool = true, at date: Date = Date()) {
        status = value
        statusReportedAt = value == nil ? nil : date
        musicPlayback = music
    }

    /// Only a headset playback reply can refresh this estimate. Battery/metadata refreshes cannot.
    func hasFreshListeningStatus(at date: Date) -> Bool {
        guard let status, status != .unsettled, let statusReportedAt, musicPlayback else { return false }
        let age = date.timeIntervalSince(statusReportedAt)
        return age >= 0 && age < 90
    }
}

enum PlaybackCommand: UInt8, Sendable {
    case pause = 0x01, next = 0x02, previous = 0x03, play = 0x07
}

enum WearingState: Sendable {
    case worn, notWorn, partially, unknown
}
