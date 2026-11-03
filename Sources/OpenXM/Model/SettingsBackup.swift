import Foundation

/// Portable, typed settings; never stores addresses, credentials, calibration or raw protocol commands.
struct SettingsBackup: Codable, Equatable, Sendable {
    var format = "OpenXM settings"
    var version = 1
    var createdAt: Date
    var model: String
    var firmware: String?
    var family: ProtocolFamily
    var settings: [SavedHeadphoneSetting]
    var omissions: [String]

    static let scope = "Includes reported settings, the voice-language selection and the active EQ curve, with optional custom EQ slots on supported models. Restoring a different language requires a separately reviewed package installation. Voice-package files, hidden ambient preferences, calibration, paired devices and Sony account data are not included."
    var hasEqualizerBank: Bool { settings.contains { if case .equalizerBank = $0 { true } else { false } } }
    var voiceLanguage: GuidanceLanguage? { settings.compactMap(\.languageToRestore).first }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw SettingsBackupError.invalid("The backup is larger than 1 MB.") }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.format == "OpenXM settings", [1, 2, 3].contains(backup.version),
              (backup.version >= 2 || !backup.hasEqualizerBank),
              (backup.version >= 3 || backup.voiceLanguage == nil),
              backup.voiceLanguage?.isKnown ?? true else {
            throw SettingsBackupError.invalid("This backup format is not supported.")
        }
        guard !backup.model.isEmpty, backup.model.count < 128, backup.settings.count <= 64,
              Set(backup.settings.map(\.id)).count == backup.settings.count,
              backup.omissions.count <= 128 else {
            throw SettingsBackupError.invalid("The backup has missing or duplicate settings.")
        }
        return backup
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    @MainActor
    static func capture(_ state: DeviceState, now: Date = Date()) throws -> Self {
        guard state.capabilitiesKnown, let model = state.modelName, !model.isEmpty, let family = state.family else {
            throw SettingsBackupError.invalid("The headphones did not report their model and capabilities.")
        }
        let caps = state.capabilities
        var settings: [SavedHeadphoneSetting] = []
        var omissions: [String] = []
        func add(_ supported: Bool, _ value: SavedHeadphoneSetting?, _ name: String) {
            guard supported else { return }
            if let value { settings.append(value) } else { omissions.append("\(name): no current value was reported.") }
        }
        add(caps.noise != nil, state.noise.map(SavedHeadphoneSetting.noise), "Ambient sound control")
        if let noise = state.noise, noise.mode != .ambient {
            omissions.append("Ambient level and voice focus are inactive; their remembered values are not restored. An Off setting restores Off without changing the remembered active mode.")
        }
        if let bank = state.equalizerBank, let cap = caps.equalizer {
            try bank.validate(cap)
            settings.append(.equalizerBank(bank))
        } else {
            add(caps.equalizer != nil, state.equalizer.map(SavedHeadphoneSetting.equalizer), "Equalizer")
            if caps.equalizer?.presets.contains(where: \.isEditable) == true {
                omissions.append("Inactive custom EQ curves were not collected. Enable Include all custom EQ curves when reading supported headphones to include them.")
            }
        }
        if state.equalizerULTMode != nil {
            omissions.append("ULT mode is not restored; ordinary EQ changes preserve the currently reported mode. ULT-specific all-slot curves are not collected.")
        }
        add(caps.listeningMode != nil, state.listeningMode.map(SavedHeadphoneSetting.listeningMode), "Listening mode")
        add(!caps.surroundPresets.isEmpty, state.surroundPreset.map(SavedHeadphoneSetting.surround), "Surround")
        add(!caps.soundPositions.isEmpty, state.soundPosition.map(SavedHeadphoneSetting.position), "Sound position")
        add(caps.upscalingName != nil, state.settingReadbacks.contains(.upscalingEnabled) ? state.upscaling.map { .upscaling($0.enabled) } : nil, "DSEE")
        add(caps.speakToChat, state.settingReadbacks.contains(.speakToChatEnabled) ? state.speakToChat.map(SavedHeadphoneSetting.speakToChat) : nil, "Speak-to-Chat")
        if caps.speakToChatOptions && !state.settingReadbacks.contains(.speakToChatOptions) {
            omissions.append("Speak-to-Chat extended options: no current value was reported.")
        }
        add(!caps.autoPowerOffOptions.isEmpty, state.autoPowerOff.map(SavedHeadphoneSetting.autoPowerOff), "Automatic power off")
        add(caps.autoPause, state.autoPause.map(SavedHeadphoneSetting.autoPause), "Pause when taken off")
        // Volume precedes enable/disable, since some voice-volume commands also enable guidance.
        add(caps.voiceGuidanceVolume != nil, state.voiceGuidanceVolume.map(SavedHeadphoneSetting.voiceVolume), "Voice guidance volume")
        add(caps.voiceGuidance, state.voiceGuidance.map(SavedHeadphoneSetting.voiceGuidance), "Voice guidance")
        if state.family == .v1, let capability = caps.voiceGuidanceCapability, capability.supportsLanguage {
            let language = state.voiceGuidanceDetails.language.flatMap { value in
                value.isKnown && capability.languages.contains(value) ? value : nil
            }
            add(true, language.map(SavedHeadphoneSetting.voiceLanguage), "Voice-guidance language")
        }
        add(caps.ncAmbButton, state.ncAmbButton.map { .ncAmbCycle($0.rawValue) }, "NC/AMB button cycle")
        add(caps.headGesture, state.headGesture.map(SavedHeadphoneSetting.headGesture), "Head gestures")
        add(caps.playback, state.nowPlaying.volume.map(SavedHeadphoneSetting.volume), "Playback volume")
        for slot in caps.generalSettingSlots {
            guard let setting = state.setting(slot: slot), !setting.key.isEmpty else {
                omissions.append("Headphone setting \(slot): no capability was reported."); continue
            }
            if setting.isBoolean {
                add(true, setting.value.map { .toggle(key: setting.key, value: $0) }, setting.title)
            } else {
                add(true, setting.selectedOption.map { .choice(key: setting.key, option: $0.key) }, setting.title)
            }
        }
        if !caps.assignableKeys.isEmpty {
            if let values = state.assignablePresets, values.count == caps.assignableKeys.count,
               caps.assignableKeys.allSatisfy({ values.indices.contains($0.index) }) {
                settings.append(.buttons(caps.assignableKeys.map {
                    SavedButton(key: $0.key, keyType: $0.keyType, preset: values[$0.index])
                }))
            } else { omissions.append("Button assignment: no complete current value was reported.") }
        }
        // May interrupt Bluetooth; restore after audio and ordinary switches.
        add(caps.connectionPriority, state.connectionPriority.map(SavedHeadphoneSetting.connectionPriority), "Connection quality")
        let duplicates = Dictionary(grouping: settings, by: \.id).filter { $0.value.count > 1 }.keys
        if !duplicates.isEmpty {
            settings.removeAll { duplicates.contains($0.id) }
            omissions.append("Ambiguous duplicate setting names were omitted: \(duplicates.sorted().joined(separator: ", ")).")
        }
        let version = settings.contains { $0.languageToRestore != nil } ? 3 : state.equalizerBank == nil ? 1 : 2
        return Self(version: version, createdAt: now, model: model, firmware: state.firmware, family: family, settings: settings, omissions: omissions)
    }

    @MainActor
    func plan(for state: DeviceState) throws -> [SettingsRestoreEntry] {
        guard state.capabilitiesKnown, state.modelName == model, state.family == family else {
            throw SettingsBackupError.invalid("Connect a \(model) using the same control protocol to restore this backup.")
        }
        // Apply user EQ before a listening mode that may disable it; reconnecting changes last.
        return settings.sorted { $0.order < $1.order }.map { setting in
            do {
                let changes = try setting.changes(for: state)
                return SettingsRestoreEntry(setting: setting, changes: changes, unavailableReason: nil,
                                            alreadyMatches: changes.allSatisfy { $0.isReflected(in: state) == true })
            } catch {
                return SettingsRestoreEntry(setting: setting, changes: [], unavailableReason: error.localizedDescription,
                                            alreadyMatches: false)
            }
        }
    }
}

struct SavedButton: Codable, Equatable, Sendable {
    var key: UInt8
    var keyType: UInt8
    var preset: UInt8
}

enum SavedHeadphoneSetting: Codable, Equatable, Sendable, Identifiable {
    case noise(NoiseControl), equalizer(EqualizerState), listeningMode(ListeningMode)
    case equalizerBank(EqualizerBank)
    case surround(UInt8), position(SoundPosition), upscaling(Bool), connectionPriority(ConnectionPriority)
    case speakToChat(SpeakToChat), autoPowerOff(UInt8), autoPause(Bool)
    case voiceGuidance(Bool), voiceVolume(Int), ncAmbCycle(UInt8), headGesture(Bool), volume(Int)
    case voiceLanguage(GuidanceLanguage)
    case toggle(key: String, value: Bool), choice(key: String, option: String), buttons([SavedButton])

    var languageToRestore: GuidanceLanguage? { if case .voiceLanguage(let language) = self { language } else { nil } }

    var id: String {
        switch self {
        case .noise: "noise"; case .equalizer: "equalizer"; case .listeningMode: "listeningMode"
        case .equalizerBank: "equalizer"
        case .surround: "surround"; case .position: "position"; case .upscaling: "upscaling"
        case .connectionPriority: "connectionPriority"; case .speakToChat: "speakToChat"
        case .autoPowerOff: "autoPowerOff"; case .autoPause: "autoPause"; case .voiceGuidance: "voiceGuidance"
        case .voiceVolume: "voiceVolume"; case .ncAmbCycle: "ncAmbCycle"; case .headGesture: "headGesture"
        case .voiceLanguage: "voiceLanguage"
        case .volume: "volume"; case .buttons: "buttons"
        case .toggle(let key, _), .choice(let key, _): "general:\(key)"
        }
    }

    var title: String {
        switch self {
        case .noise: "Ambient sound control"; case .equalizer: "Equalizer"; case .listeningMode: "Listening mode"
        case .equalizerBank: "Equalizer and all custom curves"
        case .surround: "Surround"; case .position: "Sound position"; case .upscaling: "DSEE"
        case .connectionPriority: "Connection quality"; case .speakToChat: "Speak-to-Chat"
        case .autoPowerOff: "Automatic power off"; case .autoPause: "Pause when taken off"
        case .voiceGuidance: "Voice guidance"; case .voiceVolume: "Voice guidance volume"
        case .voiceLanguage: "Voice-guidance language"
        case .ncAmbCycle: "NC/AMB button cycle"; case .headGesture: "Head gestures"
        case .volume: "Playback volume"; case .buttons: "Button assignments"
        case .toggle(let key, _), .choice(let key, _):
            GeneralSetting(slot: 0, key: key, summaryKey: "", isBoolean: false).title
        }
    }

    var detail: String {
        switch self {
        case .noise(let n): n.mode == .ambient ? "\(n.mode.title), level \(n.ambientLevel), voice focus \(n.focusOnVoice ? "on" : "off")" : n.mode.title
        case .equalizer(let e): "\(EqualizerPreset.displayName(for: e.presetID)) · \(e.bands.map(String.init).joined(separator: ", "))" + (e.clearBass.map { " · Clear Bass \($0)" } ?? "")
        case .equalizerBank(let bank):
            "Selected: \(EqualizerPreset.displayName(for: bank.activePresetID))\n" + bank.curves.sorted { $0.presetID < $1.presetID }.map { curve in
                "\(EqualizerPreset.displayName(for: curve.presetID)): \(curve.bands.map(String.init).joined(separator: ", "))" + (curve.clearBass.map { " · Clear Bass \($0)" } ?? "")
            }.joined(separator: "\n")
        case .listeningMode(let value): value.title
        case .surround(let value): SurroundPreset.displayName(for: value)
        case .position(let value): value.title
        case .connectionPriority(let value): value.title
        case .speakToChat(let value): (value.enabled ? "On" : "Off") + (value.sensitivity.map { " · \($0.title)" } ?? "") + (value.timeout.map { " · \($0.title)" } ?? "")
        case .autoPowerOff(let value): AutoPowerOffOption(id: value).title
        case .ncAmbCycle(let value): NcAmbButtonCycle(rawValue: value)?.title ?? "Unknown cycle"
        case .upscaling(let on), .autoPause(let on), .voiceGuidance(let on), .headGesture(let on), .toggle(_, let on): on ? "On" : "Off"
        case .voiceVolume(let value), .volume(let value): String(value)
        case .voiceLanguage(let value): value.title
        case .choice(_, let option): GeneralSettingOption(index: 0, key: option, summaryKey: "").title
        case .buttons(let values): values.map { ButtonFunction(rawValue: $0.preset)?.title ?? "Unknown function" }.joined(separator: ", ")
        }
    }

    var order: Int {
        switch self {
        case .equalizer, .equalizerBank: 0
        case .voiceVolume: 10
        case .voiceGuidance: 20
        case .listeningMode: 30
        case .volume: 40
        case .toggle(let key, _) where key.contains("MULTIPOINT"): 50
        case .choice, .buttons: 60
        case .connectionPriority: 70
        case .voiceLanguage: 80
        default: 5
        }
    }

    @MainActor
    func changes(for state: DeviceState) throws -> [DeviceChange] {
        let caps = state.capabilities
        func require(_ allowed: Bool, _ reason: String = "This setting is not available on the connected firmware.") throws {
            if !allowed { throw SettingsBackupError.invalid(reason) }
        }
        switch self {
        case .voiceLanguage(let language):
            try require(state.family == .v1 && language.isKnown
                && caps.voiceGuidanceCapability?.supportsLanguage == true
                && caps.voiceGuidanceCapability?.languages.contains(language) == true,
                "The saved voice language is not advertised by these headphones.")
            try require(state.voiceGuidanceDetails.language == language,
                "Changing language requires a separately reviewed package installation. Open Voice Language Packages to continue.")
            return [] // Verification only. An ordinary settings restore must never upload a package.
        case .noise(var n):
            guard let cap = caps.noise, state.noiseControlAvailable else {
                throw SettingsBackupError.invalid("Ambient sound control is unavailable or has not been read from the headphones.")
            }
            try require(cap.modes.contains(n.mode) && (!n.autoAmbient || cap.supportsAutoAmbient))
            if n.mode == .ambient {
                try require(cap.ambientRange.contains(n.ambientLevel) && (!n.focusOnVoice || cap.supportsVoiceFocus), "The saved ambient setting is outside this model's range.")
            } else {
                // Do not write an inactive, unmeasured remembered ambient preference from a backup.
                guard let current = state.noise else { throw SettingsBackupError.invalid("Read the current noise setting first.") }
                n.ambientLevel = current.ambientLevel; n.focusOnVoice = current.focusOnVoice
            }
            return [.noise(n, dragging: false)]
        case .equalizerBank(let bank):
            guard state.family != nil, state.equalizerAvailable == true, let cap = caps.equalizer else {
                throw SettingsBackupError.invalid("All custom EQ curves require a supported model with EQ available. If EQ is disabled by the listening or connection mode, change that mode and review again.")
            }
            try bank.validate(cap)
            return [.equalizerBank(bank)]
        case .equalizer(let eq):
            guard let cap = caps.equalizer, let preset = cap.presets.first(where: { $0.id == eq.presetID }) else {
                throw SettingsBackupError.invalid("The saved EQ preset is not offered by these headphones.")
            }
            try require(state.equalizerAvailable == true, "EQ is unavailable in the current listening or connection mode. Change that mode and review again.")
            if !preset.isEditable { return [.equalizerPreset(eq.presetID)] }
            try require(cap.supportsBandEditing, "This EQ configuration offers preset selection without custom band editing.")
            try require(eq.bands.count == cap.bandCount && eq.bands.allSatisfy(cap.bandRange.contains)
                        && (cap.hasClearBass ? eq.clearBass.map { (-10...10).contains($0) } == true : eq.clearBass == nil),
                        "The saved EQ curve does not fit this model's bands and range.")
            return [.equalizerPreset(eq.presetID), .equalizerBands(bands: eq.bands, clearBass: eq.clearBass)]
        case .listeningMode(let mode):
            guard let cap = caps.listeningMode else { throw SettingsBackupError.invalid("Listening modes are unavailable.") }
            switch mode {
            case .standard: break
            case .backgroundMusic: try require(cap.backgroundMusic)
            case .cinema: try require(cap.cinema)
            }
            return [.listeningMode(mode)]
        case .surround(let id):
            try require(caps.surroundPresets.contains { $0.id == id } && state.surroundAvailable == true)
            return [.surroundPreset(id)]
        case .position(let value):
            try require(caps.soundPositions.contains(value) && state.soundPositionAvailable == true)
            return [.soundPosition(value)]
        case .upscaling(let value):
            try require(caps.upscalingName != nil && state.settingReadbacks.contains(.upscalingEnabled), "The DSEE setting has not been read from these headphones.")
            return [.upscaling(value)]
        case .connectionPriority(let value): try require(caps.connectionPriority); return [.connectionPriority(value)]
        case .speakToChat(let value):
            try require(caps.speakToChat && state.settingReadbacks.contains(.speakToChatEnabled))
            var changes: [DeviceChange] = []
            if let sensitivity = value.sensitivity, let timeout = value.timeout {
                try require(caps.speakToChatOptions && state.settingReadbacks.contains(.speakToChatOptions))
                try require(value.voiceFocus == nil || state.family == .v1)
                changes.append(.speakToChatOptions(sensitivity, timeout, voiceFocus: value.voiceFocus))
            } else { try require(value.sensitivity == nil && value.timeout == nil && value.voiceFocus == nil, "Speak-to-Chat options are incomplete.") }
            changes.append(.speakToChat(value.enabled)); return changes
        case .autoPowerOff(let id): try require(caps.autoPowerOffOptions.contains { $0.id == id }); return [.autoPowerOff(id)]
        case .autoPause(let value): try require(caps.autoPause); return [.autoPause(value)]
        case .voiceGuidance(let value): try require(caps.voiceGuidance); return [.voiceGuidance(value)]
        case .voiceVolume(let value): try require(caps.voiceGuidanceVolume?.contains(value) == true); return [.voiceGuidanceVolume(value)]
        case .ncAmbCycle(let value):
            guard caps.ncAmbButton, let cycle = NcAmbButtonCycle(rawValue: value) else { throw SettingsBackupError.invalid("This button cycle is unavailable.") }
            return [.ncAmbButton(cycle)]
        case .headGesture(let value): try require(caps.headGesture); return [.headGesture(value)]
        case .volume(let value): try require(caps.playback && (0...30).contains(value)); return [.volume(value)]
        case .toggle(let key, let value):
            let matches = state.generalSettings.filter { $0.key == key && $0.isBoolean }
            try require(matches.count == 1 && !key.isEmpty, "The saved switch is missing or ambiguous on this firmware.")
            return [.generalSetting(slot: matches[0].slot, value: value)]
        case .choice(let key, let option):
            let matches = state.generalSettings.filter { $0.key == key && $0.isList }
            try require(state.family == .v1 && matches.count == 1 && !key.isEmpty)
            let options = matches[0].options.filter { $0.key == option && $0.index < 64 }
            try require(options.count == 1 && !option.isEmpty, "The saved button choice is not offered on this firmware.")
            return [.generalSettingChoice(slot: matches[0].slot, index: options[0].index)]
        case .buttons(let saved):
            let keys = caps.assignableKeys.sorted { $0.index < $1.index }
            try require(!keys.isEmpty && saved.count == keys.count && keys.map(\.index) == Array(0..<keys.count))
            let values = try keys.map { key -> UInt8 in
                let matches = saved.filter { $0.key == key.key && $0.keyType == key.keyType }
                try require(matches.count == 1 && key.options.contains(matches[0].preset), "A saved button function is missing or ambiguous on this firmware.")
                return matches[0].preset
            }
            return [.assignable(values)]
        }
    }
}

struct SettingsRestoreEntry: Identifiable, Equatable, Sendable {
    let setting: SavedHeadphoneSetting
    let changes: [DeviceChange]
    let unavailableReason: String?
    let alreadyMatches: Bool
    var id: String { setting.id }
}

enum SettingsBackupError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}
