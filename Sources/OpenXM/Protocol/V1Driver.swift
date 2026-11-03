import Foundation

/// MDR protocol V1 (WH-1000XM4 and older; service 96CC203E-…).
/// Protocol references: see the README credits. Where the MIT reference and Sony's own Android code disagreed
/// (SYSTEM writes), Sony's code was followed.
@MainActor
final class V1Driver: HeadphoneDriver {
    let link: MDRLink
    let state: DeviceState
    private let subscribesToAlerts: Bool

    /// Support-function codes (table 1, V1).
    enum Function {
        static let battery: UInt8 = 0x11
        static let upscalingIndicator: UInt8 = 0x12
        static let codecIndicator: UInt8 = 0x13
        static let leftRightBattery: UInt8 = 0x15
        static let cradleBattery: UInt8 = 0x18
        static let powerOff: UInt8 = 0x21
        static let pairingManagement: UInt8 = 0x38
        static let voiceGuidance: UInt8 = 0x39
        static let surround: UInt8 = 0x41
        static let soundPosition: UInt8 = 0x42
        static let presetEQ: UInt8 = 0x51
        static let presetEQFixed: UInt8 = 0x53
        static let noiseCancelling: UInt8 = 0x61
        static let noiseAndAmbient: UInt8 = 0x62
        static let ambientOnly: UInt8 = 0x63
        static let ncOptimizer: UInt8 = 0x81
        static let playback: UInt8 = 0xA1
        static let generalSettings: [UInt8] = [0xD1, 0xD2, 0xD3]
        static let connectionMode: UInt8 = 0xE1
        static let upscaling: UInt8 = 0xE2
        static let controlByWearing: UInt8 = 0xF3
        static let autoPowerOff: UInt8 = 0xF4
        static let speakToChat: UInt8 = 0xF5
        static let assignable: UInt8 = 0xF6
    }

    /// Read-back window for writes the headset first asks the user to confirm.
    static let confirmationTimeout: TimeInterval = 45

    private var hasTable2 = false
    private var ncInquiredType: UInt8 = 0x02
    private var lastReportedAmbientLevel: Int?
    private var eqInquiredType: UInt8 = 0x01
    private var eqStepCenter = 10
    private var stcModeOutValues: [UInt8] = []
    private var nameRefreshScheduled = false
    private var metadataBatch = V1PlaybackMetadataBatch()

    init(link: MDRLink, state: DeviceState, subscribesToAlerts: Bool = true) {
        self.link = link
        self.state = state
        self.subscribesToAlerts = subscribesToAlerts
    }

    private func supports(_ function: UInt8) -> Bool { state.supportFunctions.contains(function) }

    /// Base capabilities straight from the advertised function list (refined by later capability replies).
    private func deriveBaseCapabilities() {
        hasTable2 = supports(Function.pairingManagement) || supports(Function.voiceGuidance)
        var caps = Capabilities()
        caps.codecIndicator = supports(Function.codecIndicator)
        caps.upscalingIndicator = supports(Function.upscalingIndicator)
        caps.powerOff = supports(Function.powerOff)
        caps.playback = supports(Function.playback)
        caps.ncOptimizer = supports(Function.ncOptimizer)
        caps.connectionPriority = supports(Function.connectionMode)
        caps.autoPause = supports(Function.controlByWearing)
        caps.speakToChat = supports(Function.speakToChat)
        // Function 39 alone does not establish support for an on/off switch or language changes.
        // The separate table-2 capability reply supplies those flags.
        caps.pairedDevices = supports(Function.pairingManagement)
        caps.alerts = true
        if supports(Function.battery) { caps.batteryKinds.insert(.single) }
        if supports(Function.leftRightBattery) { caps.batteryKinds.insert(.leftRight) }
        if supports(Function.cradleBattery) { caps.batteryKinds.insert(.chargingCase) }
        state.capabilities = caps
        state.capabilitiesKnown = true
    }

    // MARK: Initialization

    func initialize() async throws {
        // Handshake: protocol info is mandatory; everything else degrades gracefully.
        _ = try await link.request([0x00, 0x00], expect: .init(.dataMdr, 0x01))
        _ = try await ask([0x02, 0x00], expect: .init(.dataMdr, 0x03))
        for type: UInt8 in [0x01, 0x02, 0x03] {
            _ = try await ask([0x04, type], expect: .init(.dataMdr, 0x05, type))
        }
        guard try await ask([0x06, 0x00], expect: .init(.dataMdr, 0x07)) != nil else {
            throw DriverError.malformed("the headphones did not list their functions")
        }

        // Capabilities.
        for (function, type) in [(Function.surround, UInt8(0x01)), (Function.soundPosition, UInt8(0x02))] where supports(function) {
            _ = try await ask([0x40, type, 0x01], expect: .init(.dataMdr, 0x41, type))
        }
        if supports(Function.presetEQ) || supports(Function.presetEQFixed) {
            eqInquiredType = supports(Function.presetEQ) ? 0x01 : 0x03
            _ = try await ask([0x50, eqInquiredType, 0x01], expect: .init(.dataMdr, 0x51, eqInquiredType))
        }
        if supports(Function.noiseAndAmbient) {
            ncInquiredType = 0x02
        } else if supports(Function.noiseCancelling) {
            ncInquiredType = 0x01
        } else if supports(Function.ambientOnly) {
            ncInquiredType = 0x03
        }
        if supports(Function.noiseAndAmbient) || supports(Function.noiseCancelling) || supports(Function.ambientOnly) {
            _ = try await ask([0x60, ncInquiredType], expect: .init(.dataMdr, 0x61, ncInquiredType))
        }
        if supports(Function.ncOptimizer) {
            _ = try await ask([0x80, 0x01], expect: .init(.dataMdr, 0x81, 0x01))
        }
        if supports(Function.playback) {
            _ = try await ask([0xA0, 0x01], expect: .init(.dataMdr, 0xA1, 0x01))
        }
        if supports(Function.connectionMode) {
            _ = try await ask([0xE0, 0x01], expect: .init(.dataMdr, 0xE1, 0x01))
        }
        if supports(Function.upscaling) {
            _ = try await ask([0xE0, 0x02], expect: .init(.dataMdr, 0xE1, 0x02))
        }
        if supports(Function.autoPowerOff) {
            _ = try await ask([0xF0, 0x04], expect: .init(.dataMdr, 0xF1, 0x04))
        }
        if supports(Function.speakToChat) {
            _ = try await ask([0xF0, 0x05], expect: .init(.dataMdr, 0xF1, 0x05))
        }
        if supports(Function.assignable) {
            _ = try await ask([0xF0, 0x06], expect: .init(.dataMdr, 0xF1, 0x06))
        }
        for slot in Function.generalSettings where supports(slot) {
            _ = try await ask([0xD0, slot, 0x01], expect: .init(.dataMdr, 0xD1, slot))
        }
        if hasTable2 && supports(Function.voiceGuidance) {
            _ = try await ask([0x40, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x41, 0x01))
        }

        // Ask the headset to send confirmation prompts (multipoint, connection quality) to us.
        if subscribesToAlerts { try await link.send([0x94, 0x01, 0x00]) }

        try await readAllValues()
    }

    private func readAllValues() async throws {
        for (function, type) in [(Function.surround, UInt8(0x01)), (Function.soundPosition, UInt8(0x02))] where supports(function) {
            _ = try await ask([0x42, type], expect: .init(.dataMdr, 0x43, type))
            _ = try await ask([0x46, type], expect: .init(.dataMdr, 0x47, type))
        }
        if supports(Function.presetEQ) || supports(Function.presetEQFixed) {
            _ = try await ask([0x52, eqInquiredType], expect: .init(.dataMdr, 0x53, eqInquiredType))
            _ = try await ask([0x56, eqInquiredType], expect: .init(.dataMdr, 0x57, eqInquiredType))
        }
        if state.capabilities.noise != nil {
            _ = try await ask([0x62, ncInquiredType], expect: .init(.dataMdr, 0x63, ncInquiredType))
            _ = try await ask([0x66, ncInquiredType], expect: .init(.dataMdr, 0x67, ncInquiredType))
        }
        if supports(Function.ncOptimizer) {
            _ = try await ask([0x82, 0x01], expect: .init(.dataMdr, 0x83, 0x01))
            _ = try await ask([0x86, 0x01], expect: .init(.dataMdr, 0x87, 0x01))
        }
        if supports(Function.connectionMode) {
            _ = try await ask([0xE6, 0x01], expect: .init(.dataMdr, 0xE7, 0x01))
        }
        if supports(Function.upscaling) {
            _ = try await ask([0xE6, 0x02], expect: .init(.dataMdr, 0xE7, 0x02))
        }
        if supports(Function.controlByWearing) {
            _ = try await ask([0xF6, 0x03], expect: .init(.dataMdr, 0xF7, 0x03))
        }
        if supports(Function.autoPowerOff) {
            _ = try await ask([0xF6, 0x04], expect: .init(.dataMdr, 0xF7, 0x04))
        }
        if supports(Function.speakToChat) {
            _ = try await ask([0xF6, 0x05], expect: .init(.dataMdr, 0xF7, 0x05))
            _ = try await ask([0xFA, 0x05], expect: .init(.dataMdr, 0xFB, 0x05))
        }
        if supports(Function.assignable) {
            _ = try await ask([0xF6, 0x06], expect: .init(.dataMdr, 0xF7, 0x06))
        }
        for slot in Function.generalSettings where supports(slot) {
            _ = try await ask([0xD6, slot], expect: .init(.dataMdr, 0xD7, slot))
        }
        if hasTable2 && supports(Function.pairingManagement) {
            _ = try await ask([0x32, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x33, 0x01))
            _ = try await ask([0x36, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x37, 0x01))
        }
        if hasTable2 && supports(Function.voiceGuidance) {
            for query in V1VoiceGuidance.queries(for: state.capabilities.voiceGuidanceCapability) {
                _ = try await ask(query.payload, table: .dataMdrNo2, expect: query.reply)
            }
        }
        try await refreshStatus()
    }

    func refreshStatus() async throws {
        if let cap = state.capabilities.equalizer {
            _ = try await ask([0x52, eqInquiredType], expect: .init(.dataMdr, 0x53, eqInquiredType))
            if state.equalizer == nil || (cap.supportsBandEditing
                && (state.equalizer?.bands.count != cap.bandCount || (cap.hasClearBass && state.equalizer?.clearBass == nil))) {
                _ = try await ask([0x56, eqInquiredType], expect: .init(.dataMdr, 0x57, eqInquiredType))
            }
        }
        if state.capabilities.noise != nil {
            _ = try await ask([0x62, ncInquiredType], expect: .init(.dataMdr, 0x63, ncInquiredType))
            if state.noise == nil {
                _ = try await ask([0x66, ncInquiredType], expect: .init(.dataMdr, 0x67, ncInquiredType))
            }
        }
        if supports(Function.battery) {
            _ = try await ask([0x10, 0x00], expect: .init(.dataMdr, 0x11, 0x00))
        }
        if supports(Function.leftRightBattery) {
            _ = try await ask([0x10, 0x01], expect: .init(.dataMdr, 0x11, 0x01))
        }
        if supports(Function.cradleBattery) {
            _ = try await ask([0x10, 0x02], expect: .init(.dataMdr, 0x11, 0x02))
        }
        if supports(Function.codecIndicator) {
            _ = try await ask([0x18, 0x00], expect: .init(.dataMdr, 0x19))
        }
        if supports(Function.upscalingIndicator) {
            _ = try await ask([0x14, 0x00], expect: .init(.dataMdr, 0x15))
        }
        if supports(Function.playback) {
            try await refreshPlayback()
        }
        if hasTable2 && supports(Function.pairingManagement) {
            _ = try await ask([0x36, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x37, 0x01))
        }
    }

    private func refreshPlayback() async throws {
        _ = try await ask([0xA2, 0x01], expect: .init(.dataMdr, 0xA3, 0x01))
        _ = try await ask([0xA6, 0x01, 0x20], expect: .init(.dataMdr, 0xA7, 0x01, detail: 0x20))
        try await refreshPlaybackNames()
    }

    private func invalidatePlaybackNames() {
        metadataBatch.reset()
        state.nowPlaying.receiveMetadata(nil)
    }

    private func refreshPlaybackNames() async throws {
        invalidatePlaybackNames()
        do {
            for detail: UInt8 in [0x00, 0x01, 0x02] {
                guard try await ask([0xA6, 0x01, detail], expect: .init(.dataMdr, 0xA7, 0x01, detail: detail)) != nil else {
                    invalidatePlaybackNames()
                    return
                }
            }
        } catch {
            invalidatePlaybackNames()
            throw error
        }
    }

    // MARK: Writes

    /// V1's unspecified preset targets the currently selected slot. Validate it before encoding bands.
    func equalizerPayload(_ change: DeviceChange, requireAvailability: Bool = true) throws -> [UInt8] {
        guard let cap = state.capabilities.equalizer,
              !requireAvailability || state.equalizerAvailable == true else {
            throw DriverError.unsupported("Equalizer in the current headphone mode")
        }
        switch change {
        case .equalizerPreset(let id):
            guard cap.presets.contains(where: { $0.id == id }) else { throw DriverError.unsupported("EQ preset") }
            return [0x58, eqInquiredType, id, 0]
        case .equalizerBands(let bands, let bass):
            guard eqInquiredType == 1, cap.supportsBandEditing, let current = state.equalizer,
                  cap.presets.contains(where: { $0.id == current.presetID && $0.isEditable }) else {
                throw DriverError.unsupported("EQ curve without a confirmed editable preset")
            }
            let curve = EqualizerState(presetID: current.presetID, bands: bands,
                clearBass: cap.hasClearBass ? (bass ?? current.clearBass) : bass)
            try EqualizerBank.validateCurve(curve, capability: cap)
            let center = -cap.bandRange.lowerBound
            let steps = (curve.clearBass.map { [$0 + center] } ?? []) + bands.map { $0 + center }
            guard steps.count <= 255, steps.allSatisfy({ (0...255).contains($0) }) else {
                throw DriverError.malformed("EQ steps")
            }
            return [0x58, eqInquiredType, 0xFF, UInt8(steps.count)] + steps.map(UInt8.init)
        default: throw DriverError.unsupported("EQ command")
        }
    }

    /// Fresh status and active-slot checks run inside the caller's link transaction.
    func applyEqualizer(_ change: DeviceChange,
                        send: ([UInt8]) async throws -> Void,
                        request: ([UInt8], MDRLink.Matcher) async throws -> Void) async throws {
        // A cleanup selection may retry after a status timeout. Reading status is permitted;
        // sending remains gated on the fresh reply below.
        _ = try equalizerPayload(change, requireAvailability: false)
        let cap = state.capabilities.equalizer
        let type = eqInquiredType
        let target: UInt8?
        if case .equalizerBands = change { target = state.equalizer?.presetID } else { target = nil }
        state.equalizerAvailable = nil
        state.equalizer = nil
        state.equalizerBank = nil
        try await request([0x52, type], .init(.dataMdr, 0x53, type))
        guard state.equalizerAvailable == true, state.capabilities.equalizer == cap, eqInquiredType == type else {
            throw DriverError.unsupported("Equalizer in the current headphone mode")
        }
        if let target {
            try await request([0x56, type], .init(.dataMdr, 0x57, type))
            guard state.equalizer?.presetID == target, state.capabilities.equalizer == cap, eqInquiredType == type else {
                throw DriverError.unsupported("The active EQ preset changed; review it before editing")
            }
        }
        let payload = try equalizerPayload(change)
        state.equalizer = nil
        state.equalizerBank = nil
        try await send(payload)
        // MDRLink delivers the frame to handle() before resuming; do not replay an older reply here.
        try await request([0x56, type], .init(.dataMdr, 0x57, type))
        guard let actual = state.equalizer, state.capabilities.equalizer == cap, eqInquiredType == type,
              target == nil || actual.presetID == target else {
            throw DriverError.malformed("EQ read-back or active preset")
        }
    }

    func apply(_ change: DeviceChange) async throws {
        switch change {
        case .noise(let value, let dragging):
            try await applyNoise(value, dragging: dragging,
                send: { try await self.link.send($0) },
                request: { _ = try await self.link.request($0, expect: $1) })

        case .equalizerBank(let bank):
            try await restoreEqualizerBank(bank)

        case .equalizerPreset, .equalizerBands:
            try await applyEqualizer(change, send: { try await self.link.send($0) },
                request: { _ = try await self.link.request($0, expect: $1) })

        case .surroundPreset, .soundPosition:
            let payload = try soundEffectPayload(change)
            try await link.send(payload)
            try await readBack([0x46, payload[1]], expect: .init(.dataMdr, 0x47, payload[1]))

        case .upscaling(let on):
            guard supports(Function.upscaling) else { throw DriverError.unsupported("DSEE") }
            try await link.send([0xE8, 0x02, 0x00, on ? 0x01 : 0x00])
            try await readBack([0xE6, 0x02], expect: .init(.dataMdr, 0xE7, 0x02))

        case .connectionPriority(let value):
            guard supports(Function.connectionMode) else { throw DriverError.unsupported("Connection quality") }
            try await link.send([0xE8, 0x01, 0x00, value.rawValue])
            // The headset asks the user to confirm (alert 0x01) before applying; allow time to answer.
            try await readBack([0xE6, 0x01], expect: .init(.dataMdr, 0xE7, 0x01), timeout: Self.confirmationTimeout)

        case .speakToChat(let on):
            guard supports(Function.speakToChat) else { throw DriverError.unsupported("Speak-to-Chat") }
            // Sony ym0/d: [F8, 05, parameterType MODE_ON_OFF(01), value].
            try await link.send([0xF8, 0x05, 0x01, on ? 0x01 : 0x00])
            try await readBack([0xF6, 0x05], expect: .init(.dataMdr, 0xF7, 0x05))

        case .speakToChatOptions(let sensitivity, let timeout, let savedVoiceFocus):
            guard supports(Function.speakToChat) else { throw DriverError.unsupported("Speak-to-Chat") }
            let voiceFocus: UInt8 = (savedVoiceFocus ?? state.speakToChat?.voiceFocus ?? false) ? 0x01 : 0x00
            try await link.send([0xFC, 0x05, 0x00, sensitivity.rawValue, voiceFocus, timeout.rawValue])
            try await readBack([0xFA, 0x05], expect: .init(.dataMdr, 0xFB, 0x05))

        case .autoPowerOff(let id):
            guard supports(Function.autoPowerOff) else { throw DriverError.unsupported("Automatic power off") }
            // Sony tm0/r3 + vm0/g: SYSTEM_SET_PARAM [F8, 04, ACTIVE_AND_SELECTIME_ID(01), active, selected].
            try await link.send([0xF8, 0x04, 0x01, id, id])
            try await readBack([0xF6, 0x04], expect: .init(.dataMdr, 0xF7, 0x04))

        case .autoPause(let on):
            guard supports(Function.controlByWearing) else { throw DriverError.unsupported("Pause when taken off") }
            // Sony KMP V1ControlByWearingRepository: [F8, 03, ON_OFF(00), value].
            try await link.send([0xF8, 0x03, 0x00, on ? 0x01 : 0x00])
            try await readBack([0xF6, 0x03], expect: .init(.dataMdr, 0xF7, 0x03))

        case .assignable(let presets):
            guard supports(Function.assignable) else { throw DriverError.unsupported("Button assignment") }
            try await link.send([0xF8, 0x06, UInt8(presets.count)] + presets)
            try await readBack([0xF6, 0x06], expect: .init(.dataMdr, 0xF7, 0x06), timeout: Self.confirmationTimeout)

        case .generalSetting(let slot, let value):
            guard supports(slot), let setting = state.setting(slot: slot), setting.isBoolean else {
                throw DriverError.unsupported("This setting")
            }
            try await link.send([0xD8, slot, 0x01, value ? 0x01 : 0x00])
            // Multipoint asks for confirmation (alerts 0x06/0x07) before the headset restarts its link.
            try await readBack([0xD6, slot], expect: .init(.dataMdr, 0xD7, slot),
                               timeout: setting.key.contains("MULTIPOINT") ? Self.confirmationTimeout : 4)

        case .generalSettingChoice(let slot, let index):
            try await link.send(generalSettingChoicePayload(slot: slot, index: index))
            try await readBack([0xD6, slot], expect: .init(.dataMdr, 0xD7, slot),
                               timeout: state.setting(slot: slot)?.isButtonAssignment == true ? Self.confirmationTimeout : 4)

        case .voiceGuidance(let on):
            try await link.send(voiceGuidancePayload(on), table: .dataMdrNo2)
            state.voiceGuidance = nil
            try await readBack([0x46, 0x01, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x47, 0x01, detail: 0x01))

        case .pairingMode(let on):
            guard hasTable2, supports(Function.pairingManagement) else { throw DriverError.unsupported("Pairing mode") }
            try await link.send([0x34, 0x01, on ? 0x01 : 0x00, 0x00], table: .dataMdrNo2)
            try await readBack([0x32, 0x01], table: .dataMdrNo2, expect: .init(.dataMdrNo2, 0x33, 0x01))

        case .playback(let command):
            guard supports(Function.playback) else { throw DriverError.unsupported("Playback control") }
            try await link.send([0xA4, 0x01, 0x00, command.rawValue])
            try await readBack([0xA2, 0x01], expect: .init(.dataMdr, 0xA3, 0x01))

        case .volume(let value):
            guard supports(Function.playback) else { throw DriverError.unsupported("Volume") }
            try await link.send([0xA8, 0x01, 0x20, UInt8(clamping: max(0, min(30, value)))])
            try await readVolumeBack(value, payload: [0xA6, 0x01, 0x20], expect: .init(.dataMdr, 0xA7, 0x01, detail: 0x20))

        case .listeningMode, .voiceGuidanceVolume, .ncAmbButton, .headGesture:
            throw DriverError.unsupported(change.label)
        }
    }

    func soundEffectPayload(_ change: DeviceChange) throws -> [UInt8] {
        switch change {
        case .surroundPreset(let id):
            guard supports(Function.surround), state.surroundAvailable == true,
                  state.capabilities.surroundPresets.contains(where: { $0.id == id }) else {
                throw DriverError.unsupported("Surround preset")
            }
            return [0x48, 0x01, id]
        case .soundPosition(let position):
            guard supports(Function.soundPosition), state.soundPositionAvailable == true,
                  state.capabilities.soundPositions.contains(position) else {
                throw DriverError.unsupported("Sound position")
            }
            return [0x48, 0x02, position.rawValue]
        default: throw DriverError.unsupported(change.label)
        }
    }

    /// Sony V1 generalsetting/c serializes the advertised list index, in the range 0..<64.
    func generalSettingChoicePayload(slot: UInt8, index: UInt8) throws -> [UInt8] {
        guard supports(slot), let setting = state.setting(slot: slot), setting.isList,
              index < 64, setting.options.contains(where: { $0.index == index }) else {
            throw DriverError.unsupported("This button function")
        }
        return [0xD8, slot, 0x02, index]
    }

    /// The caller owns the transaction gate. The closures keep the exact production sequence testable.
    func applyNoise(_ value: NoiseControl, dragging: Bool,
                    send: ([UInt8]) async throws -> Void,
                    request: ([UInt8], MDRLink.Matcher) async throws -> Void) async throws {
        guard let cap = state.capabilities.noise, state.noise != nil,
              state.noiseAvailable == true, cap.modes.contains(value.mode) else {
            throw DriverError.unsupported("Ambient sound control in the current headphone mode")
        }
        if value.mode == .ambient {
            guard cap.ambientRange.contains(value.ambientLevel), !value.focusOnVoice || cap.supportsVoiceFocus else {
                throw DriverError.unsupported("This ambient sound setting")
            }
        }
        if !dragging {
            state.noiseAvailable = nil
            try await request([0x62, ncInquiredType], .init(.dataMdr, 0x63, ncInquiredType))
            guard state.noiseAvailable == true, state.noise != nil, state.capabilities.noise == cap else {
                throw DriverError.unsupported("Ambient sound control in the current headphone mode")
            }
        }
        let wasOff = state.noise?.mode == .off
        let payload = noisePayload(value, capability: cap, dragging: dragging)
        if !dragging { state.noise = nil }
        try await send(payload)
        if dragging { return }
        try await readNoise(request: request)
        // XM3 4.5.2 treats ON as resume-last-mode and ignores supplied NC/ASM fields.
        // Commit the requested settings only after a fresh reply confirms it resumed.
        if wasOff, value.mode != .off, let actual = state.noise, actual.mode != .off,
           DeviceChange.noise(value, dragging: false).isReflected(in: state) == false {
            guard state.noiseAvailable == true else {
                throw DriverError.unsupported("Ambient sound control became unavailable")
            }
            link.note("Noise control resumed its previous settings; applying the requested settings now.")
            let completion = noisePayload(value, capability: cap, dragging: false)
            state.noise = nil
            try await send(completion)
            try await readNoise(request: request)
        }
    }

    private func readNoise(request: ([UInt8], MDRLink.Matcher) async throws -> Void) async throws {
        // MDRLink delivers the received frame to handle() before resuming this request.
        // Do not parse it again here: a newer notification may already have arrived.
        try await request([0x66, ncInquiredType], .init(.dataMdr, 0x67, ncInquiredType))
        guard state.noise != nil else { throw DriverError.malformed("NC/ambient read-back") }
    }

    /// Sony Sound Connect v30/c: slider 0 = NC (dual), 1 = wind (NC single), 2… = ambient level n-1 with NC off.
    /// The NC/ASM setting-type bytes echo the headset's own capability reply.
    private func noisePayload(_ value: NoiseControl, capability: NoiseControlCapability, dragging: Bool) -> [UInt8] {
        let ncType = state.v1NcSettingType
        let asmType = state.v1AsmSettingType
        let asmID: UInt8 = value.focusOnVoice && capability.supportsVoiceFocus ? 0x01 : 0x00
        let level = UInt8(clamping: max(capability.ambientRange.lowerBound, min(capability.ambientRange.upperBound, value.ambientLevel)))
        let wasOff = state.noise?.mode == .off
        let effect: UInt8
        switch (value.mode, dragging) {
        case (.off, _): effect = 0x00
        case (_, true): effect = 0x10            // ADJUSTMENT_IN_PROGRESS
        case (_, false) where wasOff: effect = 0x01 // ON
        default: effect = 0x11                     // ADJUSTMENT_COMPLETION
        }
        let lastOn = value.mode == .off ? (state.noise.map { NoiseMode.lastActive($0) } ?? .noiseCancelling) : value.mode
        switch lastOn {
        case .noiseCancelling, .off:
            return [0x68, ncInquiredType, effect, ncType, 0x02, asmType, asmID, 0x00]
        case .windReduction:
            return [0x68, ncInquiredType, effect, ncType, 0x01, asmType, asmID, 0x00]
        case .ambient:
            return [0x68, ncInquiredType, effect, ncType, 0x00, asmType, asmID, level]
        }
    }

    func answerAlert(_ alert: DeviceAlert, accept: Bool) async throws {
        try await link.send([0x98, 0x01, alert.messageType, accept ? 0x01 : 0x00])
    }

    func startNoiseOptimizer() async throws {
        try await setNoiseOptimizer(start: true)
    }

    func cancelNoiseOptimizer() async throws {
        try await setNoiseOptimizer(start: false)
    }

    private func setNoiseOptimizer(start: Bool) async throws {
        try await V1NoiseOptimizer.perform(start: start, supported: supports(Function.ncOptimizer),
                                          capability: state.capabilities.ncOptimizerCapability) { payload, matcher in
            try await self.link.request(payload, expect: matcher)
        }
    }

    func powerOff() async throws {
        guard supports(Function.powerOff) else { throw DriverError.unsupported("Power off") }
        try await link.send([0x22, 0x00, 0x01])
    }

    // MARK: Inbound

    func handle(_ frame: MDRFrame) {
        let p = frame.payload
        guard let command = p.first else { return }
        do {
            switch frame.type {
            case .dataMdr?: try handleTable1(command, p)
            case .dataMdrNo2?: try handleTable2(command, p)
            default: break
            }
        } catch {
            link.note(String(format: "Could not parse reply %02X: %@", command, p.hex))
        }
    }

    private func handleTable1(_ command: UInt8, _ p: [UInt8]) throws {
        var r = ByteReader(p, offset: 1)
        switch command {
        case 0x01: // protocol info
            _ = try r.u8()
            state.protocolVersion = try r.u16()
        case 0x03:
            _ = try r.u8(); _ = try r.u8()
            state.uniqueID = try r.string()
        case 0x05:
            switch try r.u8() {
            case 0x01: state.modelName = try r.string()
            case 0x02: state.firmware = try r.string()
            case 0x03: state.seriesCode = try r.u8(); state.colorCode = try r.u8()
            default: break
            }
        case 0x07:
            _ = try r.u8()
            let count = Int(try r.u8())
            state.supportFunctions = try r.take(count)
            deriveBaseCapabilities()
        case 0x11, 0x13:
            switch try r.u8() {
            case 0x00:
                state.battery.main = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
            case 0x01:
                state.battery.left = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
                state.battery.right = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
            case 0x02:
                state.battery.chargingCase = BatteryReading(level: Int(try r.u8()), charging: Self.charging(try r.u8()))
            default: break
            }
        case 0x15, 0x17:
            _ = try r.u8(); _ = try r.u8()
            let status = try r.u8()
            var upscaling = state.upscaling ?? UpscalingState(enabled: status != 0x00, active: nil)
            upscaling.active = status == 0x01
            state.upscaling = upscaling
        case 0x19, 0x1B:
            guard p.count >= 2, p[1] == 0x00 else { return }
            state.codec = p.count == 3 ? AudioCodec(rawValue: p[2]) ?? .other : nil
        case 0x41:
            switch try r.u8() {
            case 0x01:
                let count = Int(try r.u8())
                var presets: [SurroundPreset] = []
                for _ in 0..<count {
                    let id = try r.u8()
                    let name = try r.string()
                    guard !presets.contains(where: { $0.id == id }) else { throw DriverError.malformed("duplicate surround preset") }
                    presets.append(SurroundPreset(id: id, name: name.isEmpty ? SurroundPreset.displayName(for: id) : name))
                }
                state.capabilities.surroundPresets = presets
            case 0x02:
                let type = try r.u8()
                state.capabilities.soundPositions = type == 0x01 ? SoundPosition.allCases : []
            default: break
            }
        case 0x43, 0x45:
            let type = try r.u8()
            let status = try r.u8()
            let available: Bool? = status <= 1 ? status == 0 : nil
            if type == 0x01 { state.surroundAvailable = available }
            if type == 0x02 { state.soundPositionAvailable = available }
        case 0x47, 0x49:
            let type = try r.u8()
            let preset = try r.u8()
            if type == 0x01 { state.surroundPreset = preset }
            if type == 0x02 { state.soundPosition = SoundPosition(rawValue: preset) }
        case 0x51:
            try parseEqualizerCapability(&r)
        case 0x53, 0x55:
            guard try r.u8() == eqInquiredType else { return }
            state.equalizerAvailable = nil
            state.equalizerBank = nil
            let status = try r.u8()
            guard r.isAtEnd, status <= 1 else { throw DriverError.malformed("EQ availability") }
            state.equalizerAvailable = status == 0
        case 0x57, 0x59:
            guard try r.u8() == eqInquiredType, let cap = state.capabilities.equalizer else { return }
            state.equalizerBank = nil
            state.equalizer = nil
            let preset = try r.u8()
            let count = Int(try r.u8())
            let raw = try r.take(count).map { Int($0) - eqStepCenter }
            guard r.isAtEnd, cap.presets.contains(where: { $0.id == preset }),
                  count == 0 || count == cap.bandCount + (cap.hasClearBass ? 1 : 0),
                  raw.allSatisfy(cap.bandRange.contains) else { throw DriverError.malformed("EQ curve") }
            var eq = EqualizerState(presetID: preset, bands: [], clearBass: nil)
            if count > 0 {
                if cap.hasClearBass { eq.clearBass = raw[0]; eq.bands = Array(raw.dropFirst()) }
                else { eq.bands = raw }
                try EqualizerBank.validateCurve(eq, capability: cap)
            }
            state.equalizer = eq
        case 0x61:
            try parseNoiseCapability(&r)
        case 0x63, 0x65:
            guard p.byte(1) == ncInquiredType else { return }
            state.noiseAvailable = p.count == 3 && p[2] <= 1 ? p[2] == 0 : nil
        case 0x67, 0x69:
            try parseNoise(&r)
        case 0x81:
            if let capability = V1NoiseOptimizer.capability(p) {
                state.capabilities.ncOptimizer = true
                state.capabilities.ncOptimizerCapability = capability
            }
        case 0x83, 0x85:
            if let status = V1NoiseOptimizer.status(p) {
                state.optimizerAvailable = status.available
                state.optimizer = status.phase
            }
        case 0x87, 0x89:
            if let values = V1NoiseOptimizer.measurements(p, capability: state.capabilities.ncOptimizerCapability) {
                state.optimizerPersonalMeasured = values.personal
                state.optimizerMeasuredPressure = values.pressure
            }
        case 0xA1:
            state.capabilities.playback = true
        case 0xA3, 0xA5:
            guard p.count >= 2, p[1] == 0x01 else { return }
            // Playback-controller status: inquiry, availability, playback state.
            let status = p.count == 4 && p[2] == 0x00 ? PlaybackStatus(rawValue: p[3]) : nil
            state.nowPlaying.receivePlaybackStatus(status)
        case 0xA7, 0xA9:
            guard p.count >= 2, p[1] == 1 else { return }
            guard let detail = p.byte(2) else { invalidatePlaybackNames(); return }
            if detail == 0x20 {
                guard p.count == 4 else { return }
                state.nowPlaying.volume = Int(p[3])
            } else if detail <= 2 {
                if command == 0xA9 {
                    invalidatePlaybackNames() // Notifications contain a selector, no text.
                    if p.count == 3 { scheduleNameRefresh() }
                } else {
                    do {
                        var nameReader = ByteReader(p, offset: 3)
                        let name = try PlaybackName.read(&nameReader)
                        guard nameReader.isAtEnd else { throw DriverError.malformed("playback name length") }
                        // Clear the previous snapshot even while only the first new field is available.
                        state.nowPlaying.receiveMetadata(nil)
                        if let metadata = metadataBatch.receive(detail: detail, name: name) {
                            state.nowPlaying.receiveMetadata(metadata)
                        }
                    } catch {
                        invalidatePlaybackNames()
                        throw error
                    }
                }
            }
        case 0xD1:
            let slot = try r.u8()
            _ = try r.u8() // string format
            let key = try r.string()
            let summary = try r.string()
            let settingType = try r.u8()
            var options: [GeneralSettingOption] = []
            if settingType == 0x02 {
                let count = try r.u8()
                guard count > 0, count <= 64 else { throw DriverError.malformed("general setting list size") }
                for index in 0..<count {
                    _ = try r.u8() // string format; keys and literal labels share the same wire layout
                    let optionKey = try r.string()
                    let optionSummary = try r.string()
                    options.append(GeneralSettingOption(index: index, key: optionKey, summaryKey: optionSummary))
                }
            }
            var setting = state.setting(slot: slot) ?? GeneralSetting(slot: slot, key: key, summaryKey: summary, isBoolean: false, value: nil)
            setting.key = key
            setting.summaryKey = summary
            setting.isBoolean = settingType == 0x01
            setting.options = options
            if !setting.isBoolean { setting.value = nil }
            if !options.contains(where: { $0.index == setting.selectedIndex }) { setting.selectedIndex = nil }
            state.upsertSetting(setting)
            if !state.capabilities.generalSettingSlots.contains(slot) { state.capabilities.generalSettingSlots.append(slot) }
        case 0xD7, 0xD9:
            let slot = try r.u8()
            let settingType = try r.u8()
            let value = try r.u8()
            guard var setting = state.setting(slot: slot) else { break }
            if settingType == 0x01, setting.isBoolean, value <= 1 { setting.value = value == 0x01 }
            if settingType == 0x02, setting.isList {
                setting.selectedIndex = setting.options.contains(where: { $0.index == value }) ? value : nil
            }
            state.upsertSetting(setting)
        case 0xE1:
            switch try r.u8() {
            case 0x01: state.capabilities.connectionPriority = true
            case 0x02:
                let type = try r.u8()
                state.capabilities.upscalingName = Self.upscalingName(type)
            default: break
            }
        case 0xE7, 0xE9:
            let type = try r.u8()
            _ = try r.u8()
            let value = try r.u8()
            if type == 0x01 {
                state.connectionPriority = ConnectionPriority(rawValue: value)
            } else if type == 0x02 {
                var upscaling = state.upscaling ?? UpscalingState(enabled: false, active: nil)
                upscaling.enabled = value == 0x01
                if !upscaling.enabled { upscaling.active = false }
                state.upscaling = upscaling
                state.settingReadbacks.insert(.upscalingEnabled)
            }
        case 0xF1:
            try parseSystemCapability(&r)
        case 0xF7, 0xF9:
            try parseSystemParam(&r)
        case 0xFB, 0xFD:
            guard try r.u8() == 0x05 else { break }
            _ = try r.u8()
            var stc = state.speakToChat ?? SpeakToChat(enabled: false)
            stc.sensitivity = ChatSensitivity(rawValue: try r.u8())
            stc.voiceFocus = try r.u8() == 0x01
            stc.timeout = ChatTimeout(rawValue: try r.u8())
            state.speakToChat = stc
            state.settingReadbacks.insert(.speakToChatOptions)
        case 0x99:
            _ = try r.u8()
            let message = try r.u8()
            let action = try r.u8()
            state.alert = DeviceAlert(messageType: message, requiresAnswer: action == 0x01)
        default:
            break
        }
    }

    func voiceGuidancePayload(_ enabled: Bool) throws -> [UInt8] {
        guard supports(Function.voiceGuidance), state.capabilities.voiceGuidance,
              state.voiceGuidanceDetails.onOffAvailable == true else { throw DriverError.unsupported("Voice guidance") }
        return [0x48, 0x01, 0x01, enabled ? 0x01 : 0x00]
    }

    private func handleTable2(_ command: UInt8, _ p: [UInt8]) throws {
        var r = ByteReader(p, offset: 1)
        switch command {
        case 0x33, 0x35:
            _ = try r.u8()
            state.pairingMode = try r.u8() == 0x01
        case 0x37, 0x39:
            _ = try r.u8()
            let count = Int(try r.u8())
            var devices: [PairedDevice] = []
            for _ in 0..<count {
                let address = String(decoding: try r.take(17), as: UTF8.self)
                let connected = try r.u8()
                let name = try r.string()
                devices.append(PairedDevice(address: address, name: name, connected: connected != 0, isPlaybackSource: false))
            }
            if let playback = try? r.u8(), playback >= 1, Int(playback) <= devices.count {
                devices[Int(playback) - 1].isPlaybackSource = true
            }
            state.pairedDevices = devices
        case 0x41:
            let capability = try V1VoiceGuidance.capability(p)
            if state.capabilities.voiceGuidanceCapability != capability {
                state.voiceGuidanceDetails = VoiceGuidanceDetails()
                state.voiceGuidance = nil
            }
            state.capabilities.voiceGuidanceCapability = capability
            state.capabilities.voiceGuidance = capability.supportsOnOff
        case 0x43, 0x45, 0x47, 0x49:
            guard let reply = try V1VoiceGuidance.reply(p) else { return }
            switch reply {
            case .onOff(let value): state.voiceGuidance = value
            case .language(let language): state.voiceGuidanceDetails.language = language
            case .requiredTime(let value): state.voiceGuidanceDetails.requiredTime = value
            case .downloadService(let service): state.voiceGuidanceDetails.downloadService = service
            case .updateMethod(let method): state.voiceGuidanceDetails.updateMethod = method
            case .onOffAvailable(let value): state.voiceGuidanceDetails.onOffAvailable = value
            case .languageUpdateEnabled(let value): state.voiceGuidanceDetails.languageUpdateEnabled = value
            }
        default:
            break
        }
    }

    private func parseEqualizerCapability(_ r: inout ByteReader) throws {
        let type = try r.u8()
        guard type == 1 || type == 3 else { return } // 2 is EBB, with a different layout.
        let bandCount = Int(try r.u8())
        let steps = Int(try r.u8())
        let presetCount = Int(try r.u8())
        var presets: [EqualizerPreset] = []
        for _ in 0..<presetCount {
            let id = try r.u8()
            let name = try r.string()
            guard id != 0xFF else { throw DriverError.malformed("unspecified EQ preset in capability") }
            presets.append(EqualizerPreset(id: id, name: name.isEmpty ? EqualizerPreset.displayName(for: id) : name))
        }
        guard r.isAtEnd, !presets.isEmpty, Set(presets.map(\.id)).count == presets.count else {
            throw DriverError.malformed("EQ capability")
        }
        let center = max(0, (steps - 1) / 2)
        let hasClearBass = bandCount == 6
        let supportedCurve = (hasClearBass && steps == 21)
            || ([5, 10].contains(bandCount) && steps >= 3 && steps % 2 == 1)
        let editable = type == 1 && supportedCurve
        eqStepCenter = center
        eqInquiredType = type
        state.equalizer = nil
        state.equalizerAvailable = nil
        state.equalizerBank = nil
        state.capabilities.equalizer = EqualizerCapability(presets: presets,
            bandCount: hasClearBass ? 5 : bandCount, bandRange: -center...center, hasClearBass: hasClearBass,
            supportsCustomBank: editable, supportsBandEditing: editable)
    }

    private func parseNoiseCapability(_ r: inout ByteReader) throws {
        let type = try r.u8()
        var modes: [NoiseMode] = []
        var range = 1...20
        var voice = false
        if type == 0x02 {
            let ncType = try r.u8()
            _ = try r.u8()
            let asmType = try r.u8()
            let count = Int(try r.u8())
            var maxLevel = 0
            for _ in 0..<count {
                let id = try r.u8()
                let levelSteps = Int(try r.u8())
                maxLevel = max(maxLevel, levelSteps)
                if id == 0x01 { voice = true }
            }
            state.v1NcSettingType = ncType
            state.v1AsmSettingType = asmType
            modes = [.noiseCancelling]
            if ncType == 0x02 { modes.append(.windReduction) }
            modes += [.ambient, .off]
            if asmType == 0x01 && maxLevel > 0 { range = 1...maxLevel } else { range = 1...1 }
        } else if type == 0x01 {
            modes = [.noiseCancelling, .off]
            range = 1...1
        } else if type == 0x03 {
            modes = [.ambient, .off]
        }
        state.capabilities.noise = NoiseControlCapability(modes: modes, ambientRange: range,
                                                          supportsVoiceFocus: voice, supportsAutoAmbient: false)
    }

    private func parseNoise(_ r: inout ByteReader) throws {
        let type = try r.u8()
        guard type == ncInquiredType else { return }
        let previous = state.noise
        state.noise = nil
        guard type == 0x02 else {
            // NC-only / ASM-only variants: [type, effect, …]
            let effect = try r.u8()
            let mode: NoiseMode = effect == 0x00 ? .off : (type == 0x01 ? .noiseCancelling : .ambient)
            state.noise = NoiseControl(mode: mode, ambientLevel: previous?.ambientLevel ?? 1, focusOnVoice: false)
            return
        }
        let effect = try r.u8()
        let ncType = try r.u8()
        let ncValue = try r.u8()
        let asmType = try r.u8()
        let asmID = try r.u8()
        let asmValue = Int(try r.u8())
        guard r.remaining == 0, let cap = state.capabilities.noise,
              [0x00, 0x01, 0x10, 0x11].contains(effect),
              ncType == state.v1NcSettingType, asmType == state.v1AsmSettingType,
              ncType <= 2, asmType <= 1, asmID <= 1,
              ncType == 1 || ncValue <= (ncType == 2 ? 2 : 1),
              asmID == 0 || cap.supportsVoiceFocus,
              asmValue == 0 || cap.ambientRange.contains(asmValue),
              effect == 0 || ncValue != 0 || asmValue > 0 else {
            throw DriverError.malformed("NC/ambient values or setting types")
        }
        if asmValue > 0 { lastReportedAmbientLevel = asmValue }
        let level = asmValue > 0 ? asmValue : (previous?.ambientLevel ?? lastReportedAmbientLevel ?? cap.ambientRange.upperBound)
        let configured: NoiseMode = ncValue == 0 ? .ambient
            : (ncType == 2 && ncValue == 1 ? .windReduction : .noiseCancelling)
        var value = NoiseControl(mode: effect == 0x00 ? .off : configured, ambientLevel: level, focusOnVoice: asmID == 0x01)
        value.lastActiveMode = configured
        state.noise = value
    }

    private func parseSystemCapability(_ r: inout ByteReader) throws {
        switch try r.u8() {
        case 0x03:
            state.capabilities.autoPause = true
        case 0x04:
            let count = Int(try r.u8())
            state.capabilities.autoPowerOffOptions = try r.take(count).map { AutoPowerOffOption(id: $0) }
        case 0x05:
            state.capabilities.speakToChat = true
            // settingType, previewType, detailType, sensitivityType, voiceFocusType, modeOutType, then the
            // mode-out timer seconds per ModeOutTime index. WH-1000XM4 fw 2.6.0 sends them without a count
            // prefix: F1 05 00 01 00 00 00 00 | 0F 1E 3C 00 (15 s, 30 s, 60 s, never).
            _ = try r.take(6)
            var values = try r.take(r.remaining)
            if let first = values.first, Int(first) == values.count - 1 { values.removeFirst() }
            stcModeOutValues = values
            state.capabilities.speakToChatOptions = true
            state.capabilities.speakToChatTimeoutSeconds = values
        case 0x06:
            let keyCount = Int(try r.u8())
            var keys: [AssignableKey] = []
            for index in 0..<keyCount {
                let key = try r.u8()
                let keyType = try r.u8()
                let defaultPreset = try r.u8()
                let presetCount = Int(try r.u8())
                var options: [UInt8] = []
                for _ in 0..<presetCount {
                    options.append(try r.u8())
                    let actions = Int(try r.u8())
                    try r.skip(actions * 2)
                }
                keys.append(AssignableKey(index: index, key: key, keyType: keyType, defaultPreset: defaultPreset, options: options))
            }
            state.capabilities.assignableKeys = keys
        default:
            break
        }
    }

    private func parseSystemParam(_ r: inout ByteReader) throws {
        switch try r.u8() {
        case 0x03:
            _ = try r.u8()
            state.autoPause = try r.u8() == 0x01
        case 0x04:
            _ = try r.u8()
            state.autoPowerOff = try r.u8()
        case 0x05:
            _ = try r.u8()
            var stc = state.speakToChat ?? SpeakToChat(enabled: false)
            stc.enabled = try r.u8() == 0x01
            state.speakToChat = stc
            state.settingReadbacks.insert(.speakToChatEnabled)
        case 0x06:
            let count = Int(try r.u8())
            state.assignablePresets = try r.take(count)
        default:
            break
        }
    }

    private func scheduleNameRefresh() {
        guard !nameRefreshScheduled else { return }
        nameRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.nameRefreshScheduled = false
            guard !self.link.isClosed else { return }
            try? await self.link.exclusive {
                try await self.refreshPlaybackNames()
            }
        }
    }

    static func charging(_ raw: UInt8) -> ChargingState {
        switch raw {
        case 0x00: .notCharging
        case 0x01: .charging
        default: .unknown
        }
    }

    static func upscalingName(_ type: UInt8) -> String {
        switch type {
        case 0x00: "DSEE HX"
        case 0x01: "DSEE"
        case 0x02: "DSEE Extreme"
        case 0x03: "DSEE Ultimate"
        default: "DSEE"
        }
    }

    // MARK: Traffic descriptions

    func describe(_ frame: MDRFrame) -> String {
        guard let command = frame.payload.first else { return "" }
        if frame.type == .dataMdrNo2 {
            return Self.table2Names[command] ?? String(format: "T2 0x%02X", command)
        }
        return Self.table1Names[command] ?? String(format: "0x%02X", command)
    }

    static let table1Names: [UInt8: String] = [
        0x00: "GET protocol", 0x01: "RET protocol", 0x02: "GET capability", 0x03: "RET capability",
        0x04: "GET device info", 0x05: "RET device info", 0x06: "GET functions", 0x07: "RET functions",
        0x10: "GET battery", 0x11: "RET battery", 0x13: "NTFY battery", 0x14: "GET DSEE effect",
        0x15: "RET DSEE effect", 0x17: "NTFY DSEE effect", 0x18: "GET codec", 0x19: "RET codec", 0x1B: "NTFY codec",
        0x22: "SET power off", 0x50: "GET EQ capability", 0x51: "RET EQ capability", 0x52: "GET EQ status",
        0x40: "GET sound effect capability", 0x41: "RET sound effect capability", 0x42: "GET sound effect status",
        0x43: "RET sound effect status", 0x45: "NTFY sound effect status", 0x46: "GET sound effect",
        0x47: "RET sound effect", 0x48: "SET sound effect", 0x49: "NTFY sound effect",
        0x53: "RET EQ status", 0x55: "NTFY EQ status", 0x56: "GET EQ", 0x57: "RET EQ", 0x58: "SET EQ", 0x59: "NTFY EQ",
        0x60: "GET NC/ASM capability", 0x61: "RET NC/ASM capability", 0x62: "GET NC/ASM status", 0x63: "RET NC/ASM status",
        0x65: "NTFY NC/ASM status", 0x66: "GET NC/ASM", 0x67: "RET NC/ASM", 0x68: "SET NC/ASM", 0x69: "NTFY NC/ASM",
        0x80: "GET optimizer capability", 0x81: "RET optimizer capability", 0x82: "GET optimizer status",
        0x83: "RET optimizer status", 0x84: "SET optimizer", 0x85: "NTFY optimizer status", 0x86: "GET optimizer",
        0x87: "RET optimizer", 0x89: "NTFY optimizer", 0x94: "SET alerts", 0x98: "SET alert answer", 0x99: "NTFY alert",
        0xA0: "GET playback capability", 0xA1: "RET playback capability", 0xA2: "GET playback", 0xA3: "RET playback",
        0xA4: "SET playback", 0xA5: "NTFY playback", 0xA6: "GET playback param", 0xA7: "RET playback param",
        0xA8: "SET volume", 0xA9: "NTFY playback param", 0xD0: "GET setting capability", 0xD1: "RET setting capability",
        0xD6: "GET setting", 0xD7: "RET setting", 0xD8: "SET setting", 0xD9: "NTFY setting",
        0xE0: "GET audio capability", 0xE1: "RET audio capability", 0xE6: "GET audio", 0xE7: "RET audio",
        0xE8: "SET audio", 0xE9: "NTFY audio", 0xF0: "GET system capability", 0xF1: "RET system capability",
        0xF6: "GET system", 0xF7: "RET system", 0xF8: "SET system", 0xF9: "NTFY system",
        0xFA: "GET system ext", 0xFB: "RET system ext", 0xFC: "SET system ext", 0xFD: "NTFY system ext",
    ]

    static let table2Names: [UInt8: String] = [
        0x30: "GET pairing capability", 0x31: "RET pairing capability", 0x32: "GET pairing status",
        0x33: "RET pairing status", 0x34: "SET pairing mode", 0x35: "NTFY pairing status", 0x36: "GET devices",
        0x37: "RET devices", 0x39: "NTFY devices", 0x40: "GET voice guidance capability",
        0x41: "RET voice guidance capability", 0x46: "GET voice guidance", 0x47: "RET voice guidance",
        0x48: "SET voice guidance", 0x49: "NTFY voice guidance",
    ]
}

private extension NoiseMode {
    static func lastActive(_ value: NoiseControl) -> NoiseMode {
        value.mode == .off ? value.lastActiveMode : value.mode
    }
}
