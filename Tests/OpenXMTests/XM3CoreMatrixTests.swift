import Foundation
import Testing
@testable import OpenXM

/// Regression coverage for the independently captured, physical 2.0.0 control matrix.
/// These replay checks do not establish audible behavior, reconnection or power-cycle persistence.
@MainActor struct XM3CoreMatrixTests {
    private struct Capture: Decodable {
        let model: String
        let firmware: String
        let cases: [Entry]
    }
    private struct Entry: Decodable {
        let feature: String
        let label: String
        let value: UInt8
        let write: String
        let reply: String
    }

    private func bytes(_ hex: String) throws -> [UInt8] {
        try hex.split(separator: " ").map { try #require(UInt8($0, radix: 16)) }
    }

    private func cases(_ feature: String) throws -> [Entry] {
        let url = try #require(Bundle.module.url(forResource: "xm3-2.0.0-core-matrix", withExtension: "json", subdirectory: "Fixtures"))
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
        #expect(capture.model == "WH-1000XM3" && capture.firmware == "2.0.0" && capture.cases.count == 27)
        return capture.cases.filter { $0.feature == feature }
    }

    private func fixture() throws -> (DeviceState, V1Driver) {
        let url = try #require(Bundle.module.url(forResource: "xm3-2.0.0-public-replies", withExtension: "json", subdirectory: "Fixtures"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let replies = try #require(object["replies"] as? [String])
        let state = DeviceState(); state.family = .v1
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        for reply in replies { try receive(reply, driver) }
        return (state, driver)
    }

    private func receive(_ reply: String, _ driver: V1Driver) throws {
        driver.handle(.init(type: .dataMdr, sequence: 0, payload: try bytes(reply)))
    }

    @Test func everyCapturedSoundEffectMatchesItsAdvertisedSelection() throws {
        let (state, driver) = try fixture()
        let surround = try cases("surround"), positions = try cases("soundPosition")
        #expect(surround.count == 5 && positions.count == 6)
        for entry in surround {
            let change = DeviceChange.surroundPreset(entry.value)
            #expect(try driver.soundEffectPayload(change) == bytes(entry.write))
            try receive(entry.reply, driver)
            #expect(change.isReflected(in: state) == true)
            #expect(state.capabilities.surroundPresets.first { $0.id == state.surroundPreset }?.name == entry.label)
        }
        for entry in positions {
            let position = try #require(SoundPosition(rawValue: entry.value))
            let change = DeviceChange.soundPosition(position)
            #expect(try driver.soundEffectPayload(change) == bytes(entry.write))
            try receive(entry.reply, driver)
            #expect(change.isReflected(in: state) == true && state.soundPosition?.title == entry.label)
        }
    }

    @Test func capturedFactoryEQCurvesPreserveSignedBandsAndClearBass() throws {
        let (state, driver) = try fixture()
        // Values independently observed in the native EQ editor during the physical check.
        let expected: [UInt8: ([Int], Int)] = [
            0: ([0, 0, 0, 0, 0], 0), 0x10: ([0, 5, 7, 7, 9], -1),
            0x11: ([-1, 1, 0, 3, 5], 8), 0x12: ([-1, -2, -3, -4, -6], -3),
            0x13: ([-3, -1, -3, -5, -8], -9), 0x14: ([6, 4, 2, 3, -1], 0),
            0x15: ([0, 0, 2, 6, 10], 0), 0x16: ([0, 0, 0, 0, 0], 7),
            0x17: ([4, 3, 1, 2, -10], -10)
        ]
        let entries = try cases("equalizer")
        #expect(entries.count == expected.count)
        for entry in entries {
            let change = DeviceChange.equalizerPreset(entry.value)
            #expect(try driver.equalizerPayload(change) == bytes(entry.write))
            try receive(entry.reply, driver)
            let curve = try #require(expected[entry.value])
            #expect(state.equalizer == .init(presetID: entry.value, bands: curve.0, clearBass: curve.1))
            #expect(change.isReflected(in: state) == true)
            #expect(EqualizerPreset.displayName(for: entry.value) == entry.label)
        }
    }

    @Test func capturedPowerOptionsUseTheSelectedOptionRatherThanTheRetainedTimer() throws {
        let (state, driver) = try fixture()
        let entries = try cases("autoPowerOff")
        #expect(entries.count == 5)
        for entry in entries {
            try receive(entry.reply, driver)
            #expect(state.autoPowerOff == entry.value)
            #expect(AutoPowerOffOption(id: try #require(state.autoPowerOff)).title == entry.label)
        }
        // The real Never reply retains 30 minutes in its trailing byte; it must still display Never.
        let never = try #require(entries.first { $0.value == 0x11 })
        #expect(never.reply == "F7 04 01 11 01")
    }

    @Test func bothCapturedConnectionPrioritiesAreConfirmedIndependently() throws {
        let (state, driver) = try fixture()
        let entries = try cases("connectionPriority")
        #expect(entries.count == 2)
        for entry in entries {
            try receive(entry.reply, driver)
            let priority = try #require(ConnectionPriority(rawValue: entry.value))
            #expect(state.connectionPriority == priority && priority.title == entry.label)
            #expect(DeviceChange.connectionPriority(priority).isReflected(in: state) == true)
        }
    }
}
