import Foundation
import Testing
@testable import OpenXM

/// Synthetic vectors derived from the pinned Sony V2 parameter builder, not headset captures.
@MainActor struct V2EqualizerTests {
    private func receive(_ bytes: [UInt8], _ driver: V2Driver, table: MDRDataType = .dataMdr) {
        driver.handle(MDRFrame(type: table, sequence: 0, payload: bytes))
    }

    private func fixture(bands: UInt8 = 6, steps: UInt8 = 21, type: UInt8 = 0) -> (DeviceState, V2Driver) {
        let state = DeviceState()
        state.family = .v2
        let driver = V2Driver(link: MDRLink(transport: nil), state: state)
        receive([0x51, type, bands, steps] + (type == 3 ? [0] : []) + [4, 0x10, 0, 0xA0, 0, 0xA1, 0, 0xA2, 0], driver)
        receive([0x53, type, 0], driver)
        return (state, driver)
    }

    @Test func publishedLinkBudsOpenCaptureDecodesTenBandEQ() throws {
        let state = DeviceState()
        state.family = .v2
        let driver = V2Driver(link: MDRLink(transport: nil), state: state)
        for name in ["capability", "status", "parameter"] {
            let url = try #require(Bundle.module.url(forResource: "wf-lc900-eq-\(name)", withExtension: "bin", subdirectory: "Fixtures"))
            let wire = [UInt8](try Data(contentsOf: url))
            #expect(wire.first == MDRFrame.startMarker && wire.last == MDRFrame.endMarker)
            let frame = try MDRFrame.decode(body: wire[1..<(wire.count - 1)])
            #expect(frame.type == .dataMdr)
            driver.handle(frame)
        }
        let cap = try #require(state.capabilities.equalizer)
        #expect(cap.bandCount == 10 && cap.bandRange == -6...6 && !cap.hasClearBass)
        #expect(cap.presets.map(\.id) == [0, 0x30, 0x31, 0x32, 0x33, 0xA0, 0xA1, 0xA2])
        #expect(cap.supportsBandEditing && cap.supportsCustomBank && state.equalizerAvailable == true)
        #expect(state.equalizer == EqualizerState(presetID: 0, bands: Array(repeating: 0, count: 10), clearBass: nil))
        #expect(state.equalizerULTMode == nil)
    }

    @Test func customSlotIsExplicitAndMissingTargetNeverFallsBackToManual() throws {
        let (state, driver) = fixture()
        receive([0x57, 0, 0xA2, 6, 12, 0, 9, 10, 11, 20], driver)
        let value = try #require(state.equalizer)
        #expect(value == EqualizerState(presetID: 0xA2, bands: [-10, -1, 0, 1, 10], clearBass: 2))
        #expect(try driver.equalizerPayload(.equalizerPreset(0xA1)) == [0x58, 0, 0xA1, 0])
        #expect(try driver.equalizerPayload(.equalizerBands(bands: [1, 2, 3, 4, 5], clearBass: nil)) == [0x58, 0, 0xA2, 6, 12, 11, 12, 13, 14, 15])
        state.equalizer = nil
        #expect(throws: (any Error).self) { try driver.equalizerPayload(.equalizerBands(bands: value.bands, clearBass: 2)) }
        state.equalizer = value
        state.equalizer?.presetID = 0x10
        #expect(throws: (any Error).self) { try driver.equalizerPayload(.equalizerBands(bands: value.bands, clearBass: 2)) }
        #expect(throws: (any Error).self) { try driver.equalizerPayload(.equalizerPreset(0xA5)) }
    }

    @Test func tenBandEncodingUsesTheAdvertisedCenterAndNeverAddsClearBass() throws {
        for steps: UInt8 in [13, 25] {
            let (state, driver) = fixture(bands: 10, steps: steps)
            let center = Int(steps - 1) / 2
            receive([0x57, 0, 0xA1, 10] + Array(repeating: UInt8(center), count: 10), driver)
            #expect(state.equalizer?.bands == Array(repeating: 0, count: 10) && state.equalizer?.clearBass == nil)
            let curve = [-center, center, 1, -1, 0, 2, -2, 3, -3, 0]
            #expect(try driver.equalizerPayload(.equalizerBands(bands: curve, clearBass: nil)) == [0x58, 0, 0xA1, 10] + curve.map { UInt8($0 + center) })
            #expect(throws: (any Error).self) { try driver.equalizerPayload(.equalizerBands(bands: curve, clearBass: 0)) }
            #expect(throws: (any Error).self) { try driver.equalizerPayload(.equalizerBands(bands: Array(repeating: center + 1, count: 10), clearBass: nil)) }
        }
    }

    @Test func malformedCurvesCannotConfirmOldValuesAndOtherSelectorsCannotReplaceEQ() throws {
        let (state, driver) = fixture()
        let valid: [UInt8] = [0x57, 0, 0xA1, 6, 10, 10, 10, 10, 10, 10]
        for invalid in [Array(valid.dropLast()), valid + [0], [0x57, 0, 0xA1, 1, 10],
                        [0x57, 0, 0xA1, 6, 21, 10, 10, 10, 10, 10], [0x57, 0, 0xFF, 0]] {
            receive(valid, driver)
            state.equalizerBank = EqualizerBank(activePresetID: 0xA1, curves: [])
            receive(invalid, driver)
            #expect(state.equalizer == nil && state.equalizerBank == nil)
        }
        receive(valid, driver)
        let before = state.equalizer
        receive([0x59, 1, 0xA2, 0], driver) // V2 selector 1 is EBB, not preset EQ.
        receive([0x59, 0, 0xA2, 0], driver, table: .dataMdrNo2)
        #expect(state.equalizer == before)
        receive([0x59, 0, 0xA2, 0], driver)
        #expect(state.equalizer == EqualizerState(presetID: 0xA2, bands: [], clearBass: nil))
    }

    @Test func capabilityAndAvailabilityGateBankAccessWithoutPartialMutation() throws {
        let (state, driver) = fixture()
        let before = state.capabilities.equalizer
        #expect(before?.supportsCustomBank == true)
        for invalid: [UInt8] in [[0x51, 2, 6, 21, 2, 0xA0, 0], [0x51, 2, 6, 21, 2, 0xA0, 0, 0xA0, 0],
                                [0x51, 1, 6, 21, 1, 0xA0, 0]] {
            receive(invalid, driver)
            #expect(state.capabilities.equalizer == before)
            #expect(try driver.equalizerPayload(.equalizerPreset(0xA1)) == [0x58, 0, 0xA1, 0])
        }
        receive([0x55, 0, 2], driver)
        #expect(state.equalizerAvailable == nil)
        #expect(throws: (any Error).self) { try driver.equalizerPayload(.equalizerPreset(0xA1)) }
        receive([0x53, 0, 1], driver)
        #expect(state.equalizerAvailable == false)
        for type: UInt8 in [2, 3, 4] {
            let (other, _) = fixture(type: type)
            #expect(other.capabilities.equalizer?.supportsCustomBank == false)
        }
        let (unsupported, writer) = fixture(bands: 6, steps: 13)
        unsupported.equalizer = EqualizerState(presetID: 0xA0, bands: Array(repeating: 0, count: 5), clearBass: 0)
        #expect(unsupported.capabilities.equalizer?.supportsCustomBank == false)
        #expect(throws: (any Error).self) { try writer.equalizerPayload(.equalizerBands(bands: Array(repeating: 0, count: 5), clearBass: 0)) }
    }

    @Test func disconnectedWritesInvalidatePriorEqualValuesBeforeAnyReadback() async {
        for family in [ProtocolFamily.v1, .v2] {
            let (state, v2) = fixture()
            state.family = family
            state.equalizer = EqualizerState(presetID: 0xA1, bands: Array(repeating: 0, count: 5), clearBass: 0)
            state.equalizerBank = EqualizerBank(activePresetID: 0xA1, curves: [])
            let driver: HeadphoneDriver = family == .v1 ? V1Driver(link: v2.link, state: state) : v2
            do { try await driver.apply(.equalizerBands(bands: Array(repeating: 0, count: 5), clearBass: 0)); Issue.record("Closed link must fail") } catch {}
            #expect(state.equalizer == nil && state.equalizerBank == nil)
        }
    }

    @Test func ultRepliesAndWritesKeepModeBetweenPresetAndBandCount() throws {
        for mode: UInt8 in [0, 1, 2] {
            let (state, driver) = fixture(type: 3)
            receive([0x57, 3, 0xA1, mode, 6, 12, 0, 9, 10, 11, 20], driver)
            #expect(state.equalizerULTMode == mode)
            #expect(state.equalizer == .init(presetID: 0xA1, bands: [-10, -1, 0, 1, 10], clearBass: 2))
            #expect(try driver.equalizerPayload(.equalizerPreset(0x10)) == [0x58, 3, 0x10, mode, 0])
            #expect(try driver.equalizerPayload(.equalizerBands(bands: [1, 2, 3, 4, 5], clearBass: nil))
                    == [0x58, 3, 0xA1, mode, 6, 12, 11, 12, 13, 14, 15])
            // Preset-only notifications still include the mode, even when no band values follow.
            receive([0x59, 3, 0x10, mode, 0], driver)
            #expect(state.equalizer?.presetID == 0x10 && state.equalizerULTMode == mode)
            #expect(state.capabilities.equalizer?.supportsCustomBank == false)
        }
    }

    @Test func unknownOrMalformedULTModeCannotReuseAnEarlierModeOrCurve() throws {
        let (state, driver) = fixture(type: 3)
        let valid: [UInt8] = [0x57, 3, 0xA1, 2, 6, 10, 10, 10, 10, 10, 10]
        for invalid: [UInt8] in [[0x57, 3, 0xA1, 0xFF, 0], [0x57, 3, 0xA1, 3, 0],
                                Array(valid.dropLast()), valid + [0], [0x59, 3, 0xA1, 6, 10, 10, 10, 10, 10, 10]] {
            receive(valid, driver)
            receive(invalid, driver)
            #expect(state.equalizer == nil && state.equalizerULTMode == nil)
            #expect(throws: (any Error).self) { try driver.equalizerPayload(.equalizerPreset(0x10)) }
        }
        receive(valid, driver)
        receive([0x59, 0, 0xA0, 0], driver)
        #expect(state.equalizerULTMode == 2 && state.equalizer?.presetID == 0xA1)
        state.reset()
        #expect(state.equalizerULTMode == nil)
    }

    @Test func fixedEQOffersPresetsWithoutBandsScenesOrCustomCurveRestore() throws {
        let (state, driver) = fixture(type: 2)
        receive([0x57, 2, 0x10, 0], driver)
        let cap = try #require(state.capabilities.equalizer)
        #expect(!cap.supportsBandEditing && !cap.supportsCustomBank)
        #expect(try driver.equalizerPayload(.equalizerPreset(0x10)) == [0x58, 2, 0x10, 0])
        #expect(try SavedHeadphoneSetting.equalizer(.init(presetID: 0x10, bands: [], clearBass: nil)).changes(for: state).count == 1)
        let curve = EqualizerState(presetID: 0xA1, bands: [0, 0, 0, 0, 0], clearBass: 0)
        state.equalizer = curve
        #expect(throws: (any Error).self) { try driver.equalizerPayload(.equalizerBands(bands: curve.bands, clearBass: curve.clearBass)) }
        #expect(throws: (any Error).self) { try SavedHeadphoneSetting.equalizer(curve).changes(for: state) }
        let scene = SoundScene(name: "Custom curve", symbol: "headphones", tint: .sage, equalizer: .custom(bands: curve.bands, clearBass: curve.clearBass))
        #expect(scene.changes(for: state).changes.isEmpty && scene.changes(for: state).skipped == ["Custom equalizer"])
    }

    @Test func failedULTWriteInvalidatesModeAndBackupDisclosesItsScope() async throws {
        let (state, driver) = fixture(type: 3)
        state.modelName = "Synthetic ULT reference"
        state.capabilitiesKnown = true
        receive([0x57, 3, 0xA1, 1, 6, 10, 10, 10, 10, 10, 10], driver)
        let backup = try SettingsBackup.capture(state)
        #expect(backup.omissions.contains { $0.contains("ULT mode is not restored") })
        do { try await driver.apply(.equalizerPreset(0x10)); Issue.record("Closed link must fail") } catch {}
        #expect(state.equalizer == nil && state.equalizerULTMode == nil)
    }
}
