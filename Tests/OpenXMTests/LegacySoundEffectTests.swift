import Foundation
import Testing
@testable import OpenXM

@MainActor struct LegacySoundEffectTests {
    private func receive(_ bytes: [UInt8], _ driver: V1Driver, table: MDRDataType = .dataMdr) {
        driver.handle(MDRFrame(type: table, sequence: 0, payload: bytes))
    }

    @Test func referenceCapabilitiesGateWritesAndPreserveNames() throws {
        let state = DeviceState()
        state.supportFunctions = [0x41, 0x42]
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        // Reference cz$b: [command, VPT, count, id, name length, UTF-8 name, ...].
        receive([0x41, 0x01, 3, 0, 0, 2, 5, 65, 114, 101, 110, 97, 4, 0], driver)
        #expect(state.capabilities.surroundPresets.map(\.name) == ["Off", "Arena", "Club"])
        receive([0x41, 0x02, 0x01], driver) // cz$a: SOUND_POSITION TYPE1
        #expect(state.capabilities.soundPositions.count == 6)
        // Discovery alone cannot enable controls until the device reports its current status.
        #expect(throws: (any Error).self) { try driver.soundEffectPayload(.surroundPreset(2)) }
        receive([0x43, 0x01, 0x00], driver) // CommonStatus.ENABLE is zero
        receive([0x43, 0x02, 0x00], driver)
        #expect(try driver.soundEffectPayload(.surroundPreset(2)) == [0x48, 0x01, 0x02])
        #expect(try driver.soundEffectPayload(.soundPosition(.rearLeft)) == [0x48, 0x02, 0x11])
        #expect(throws: (any Error).self) { try driver.soundEffectPayload(.surroundPreset(1)) } // not in this device's list
        receive([0x45, 0x01, 0x01], driver) // unavailable
        #expect(throws: (any Error).self) { try driver.soundEffectPayload(.surroundPreset(2)) }
        #expect(state.soundPositionAvailable == true)
    }

    @Test func parameterTablesAreIndependentAndReadbackIsExact() {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        receive([0x47, 0x01, 0x03], driver)
        receive([0x49, 0x02, 0x12], driver)
        #expect(DeviceChange.surroundPreset(3).isReflected(in: state) == true)
        #expect(DeviceChange.surroundPreset(4).isReflected(in: state) == false)
        #expect(DeviceChange.soundPosition(.rearRight).isReflected(in: state) == true)
        // Same command byte on table 2 means voice guidance, not surround.
        receive([0x47, 0x01, 0x01, 0x01], driver, table: .dataMdrNo2)
        #expect(state.voiceGuidance == true)
        #expect(state.surroundPreset == 3)
        receive([0x49, 0x02, 0xFF], driver)
        #expect(state.soundPosition == nil)
        state.reset()
        #expect(state.surroundPreset == nil && state.soundPositionAvailable == nil)
        #expect(state.capabilities.surroundPresets.isEmpty)
    }

    @Test func malformedCapabilitiesDoNotPartiallyMutateState() {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        let packet: [UInt8] = [0x41, 1, 3, 0, 0, 1, 0, 2, 0]
        receive(packet, driver)
        let before = state.capabilities
        for length in 1..<packet.count {
            receive(Array(packet.prefix(length)), driver)
            #expect(state.capabilities == before)
        }
        receive([0x41, 1, 2, 0, 0, 0, 0], driver) // duplicate preset IDs
        #expect(state.capabilities == before)
        receive([0x41, 2, 0xFF], driver)
        #expect(state.capabilities.soundPositions.isEmpty)
    }

    @Test func scenesPreserveEffectsAndSkipUnsupportedDevices() throws {
        let state = DeviceState()
        state.surroundPreset = 3
        state.soundPosition = .frontLeft
        state.capabilities.surroundPresets = [SurroundPreset(id: 3, name: "Concert Hall")]
        state.capabilities.soundPositions = SoundPosition.allCases
        let scene = SoundScene.capture(from: state, name: "Concert")
        #expect(!scene.isEmpty)
        #expect(scene.changes(for: state).changes == [[.surroundPreset(3)], [.soundPosition(.frontLeft)]])
        let decoded = try JSONDecoder().decode(SoundScene.self, from: JSONEncoder().encode(scene))
        #expect(decoded == scene)
        state.reset()
        #expect(scene.changes(for: state).changes.isEmpty)
        #expect(scene.changes(for: state).skipped == ["Surround (VPT)", "Sound Position Control"])
        // Existing scene files omit both optional fields. They must load without a migration or data loss.
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Old scene","symbol":"headphones","tint":"lavender","upscaling":true,"generalSettings":{},"trigger":{"manual":{}},"triggerEnabled":true}"#.utf8)
        let legacy = try JSONDecoder().decode(SoundScene.self, from: old)
        #expect(legacy.surroundPreset == nil && legacy.soundPosition == nil && legacy.upscaling == true)
    }
}
