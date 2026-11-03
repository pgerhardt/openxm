import Foundation
import Testing
@testable import OpenXM

@MainActor struct LegacySettingTests {
    // Literal WH-1000XM3 4.5.2 reply recorded on 2026-10-29. It contains only public setting keys.
    static let buttonCapability: [UInt8] = """
    D1 D1 02 16 41 53 53 49 47 4E 41 42 4C 45 5F 4B 45 59 5F 53 45 54 54 49 4E 47 00 02 03
    02 19 41 53 53 49 47 4E 41 42 4C 45 5F 4B 45 59 5F 45 4C 45 4D 5F 4E 43 41 53 4D 00
    02 24 41 53 53 49 47 4E 41 42 4C 45 5F 4B 45 59 5F 45 4C 45 4D 5F 47 4F 4F 47 4C 45 5F 41 53 53 49 53 54 41 4E 54
    2C 41 53 53 49 47 4E 41 42 4C 45 5F 4B 45 59 5F 45 4C 45 4D 5F 47 4F 4F 47 4C 45 5F 41 53 53 49 53 54 41 4E 54 5F 53 55 4D 4D 41 52 59
    02 20 41 53 53 49 47 4E 41 42 4C 45 5F 4B 45 59 5F 45 4C 45 4D 5F 41 4D 41 5A 4F 4E 5F 41 4C 45 58 41
    28 41 53 53 49 47 4E 41 42 4C 45 5F 4B 45 59 5F 45 4C 45 4D 5F 41 4D 41 5A 4F 4E 5F 41 4C 45 58 41 5F 53 55 4D 4D 41 52 59
    """.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! }

    private func receive(_ bytes: [UInt8], _ driver: V1Driver) {
        driver.handle(MDRFrame(type: .dataMdr, sequence: 0, payload: bytes))
    }

    @Test func physicalFirmware200CaptureKeepsItsCapabilitiesSeparateFrom452() throws {
        let url = try #require(Bundle.module.url(forResource: "xm3-2.0.0-public-replies", withExtension: "json", subdirectory: "Fixtures"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let replies = try #require(object["replies"] as? [String])
        let state = DeviceState()
        state.family = .v1
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        for hex in replies {
            let fields = hex.split(separator: " ")
            let bytes = fields.compactMap { UInt8($0, radix: 16) }
            #expect(bytes.count == fields.count)
            receive(bytes, driver)
        }
        #expect(state.modelName == "WH-1000XM3" && state.firmware == "2.0.0" && state.protocolVersion == 0x4000)
        #expect(state.uniqueID == nil)
        let setting = try #require(state.setting(slot: 0xD1))
        #expect(setting.options.map(\.title) == ["Ambient Sound Control", "Google Assistant"])
        #expect(setting.selectedIndex == 0 && state.generalSettings.count == 1)
        #expect(try driver.generalSettingChoicePayload(slot: 0xD1, index: 1) == [0xD8, 0xD1, 2, 1])
        #expect(throws: (any Error).self) { try driver.generalSettingChoicePayload(slot: 0xD1, index: 2) }
        #expect(!state.capabilities.voiceGuidance && state.capabilities.voiceGuidanceCapability == nil)
        #expect(state.capabilities.surroundPresets.map(\.name) == ["Off", "Arena", "Club", "Outdoor Festival", "Concert Hall"])
        #expect(state.surroundPreset == 0 && state.surroundAvailable == true && state.soundPositionAvailable == true)
        #expect(state.equalizer == .init(presetID: 0, bands: [0, 0, 0, 0, 0], clearBass: 0))
        #expect(state.equalizerAvailable == true && state.noiseAvailable == true)
        #expect(state.noise?.mode == .noiseCancelling)
        // The capture reports zero for inactive ambient level; no hidden preference is asserted here.
    }

    @Test func xm3AdvertisedChoicesAndIndexWrites() throws {
        let state = DeviceState()
        state.supportFunctions = [0xD1]
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        receive(Self.buttonCapability, driver)
        let setting = try #require(state.setting(slot: 0xD1))
        #expect(setting.isList && setting.isButtonAssignment && !setting.isBoolean)
        #expect(setting.options.map(\.title) == ["Ambient Sound Control", "Google Assistant", "Amazon Alexa"])
        #expect(setting.selectedIndex == nil)
        receive([0xD7, 0xD1, 0x02, 0x00], driver)
        #expect(state.setting(slot: 0xD1)?.selectedOption?.title == "Ambient Sound Control")
        // Sony's V1 list encoder sends the entry's index, not newer ASSIGNABLE preset IDs (31/32).
        #expect(try driver.generalSettingChoicePayload(slot: 0xD1, index: 1) == [0xD8, 0xD1, 0x02, 0x01])
        #expect(try driver.generalSettingChoicePayload(slot: 0xD1, index: 2) == [0xD8, 0xD1, 0x02, 0x02])
        #expect(throws: (any Error).self) { try driver.generalSettingChoicePayload(slot: 0xD1, index: 0x31) }
        #expect(throws: (any Error).self) { try driver.generalSettingChoicePayload(slot: 0xD2, index: 0) }
        receive([0xD9, 0xD1, 0x02, 0x02], driver)
        #expect(DeviceChange.generalSettingChoice(slot: 0xD1, index: 2).isReflected(in: state) == true)
        #expect(DeviceChange.generalSettingChoice(slot: 0xD1, index: 1).isReflected(in: state) == false)
        receive([0xD9, 0xD1, 0x02, 0xFF], driver)
        #expect(state.setting(slot: 0xD1)?.selectedIndex == nil)
    }

    @Test func truncatedListCannotReplaceValidCapabilities() {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        receive(Self.buttonCapability, driver)
        receive([0xD7, 0xD1, 0x02, 0], driver)
        let before = state.generalSettings
        for length in 1..<Self.buttonCapability.count {
            receive(Array(Self.buttonCapability.prefix(length)), driver)
            #expect(state.generalSettings == before)
        }
        receive([0xD9, 0xD1, 0x01, 1], driver) // wrong setting type must not turn a list into a switch
        #expect(state.generalSettings == before)
    }

    @Test func booleanTouchSettingRemainsIndependent() throws {
        let state = DeviceState()
        state.supportFunctions = [0xD1, 0xD2]
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        receive(Self.buttonCapability, driver)
        receive([0xD1, 0xD2, 0x02, 0x13] + Array("TOUCH_PANEL_SETTING".utf8) + [0, 1], driver)
        receive([0xD7, 0xD2, 0x01, 0x01], driver)
        #expect(state.setting(slot: 0xD2)?.value == true)
        #expect(state.setting(slot: 0xD1)?.value == nil)
        #expect(throws: (any Error).self) { try driver.generalSettingChoicePayload(slot: 0xD2, index: 0) }
        receive([0xD9, 0xD2, 0x02, 0], driver)
        #expect(state.setting(slot: 0xD2)?.value == true)
    }
}
