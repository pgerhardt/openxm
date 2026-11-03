import Foundation
import Testing
@testable import OpenXM

@MainActor struct V1EqualizerTests {
    // Exact public-setting replies from the WH-1000XM3 4.5.2 capture.
    // Modified parameters, fixed-preset capabilities and failures below are synthetic.
    private let capability: [UInt8] = [0x51, 1, 6, 21, 12, 0, 0, 0x10, 0, 0x11, 0, 0x12, 0,
        0x13, 0, 0x14, 0, 0x15, 0, 0x16, 0, 0x17, 0, 0xA0, 0, 0xA1, 0, 0xA2, 0]
    private let status: [UInt8] = [0x53, 1, 0]
    private let off: [UInt8] = [0x57, 1, 0, 6, 10, 10, 10, 10, 10, 10]
    private let custom: [UInt8] = [0x57, 1, 0xA2, 6, 12, 10, 12, 13, 11, 9]

    private func receive(_ p: [UInt8], _ driver: V1Driver, table: MDRDataType = .dataMdr) {
        driver.handle(.init(type: table, sequence: 0, payload: p))
    }

    private func fixture() -> (DeviceState, V1Driver) {
        let state = DeviceState()
        state.family = .v1; state.modelName = "WH-1000XM3"; state.firmware = "4.5.2"
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        for p in [capability, status, off] { receive(p, driver) }
        return (state, driver)
    }

    @Test func capturedXM3RepliesExposeExactlyTheAdvertisedPresetsAndCurve() throws {
        let (state, driver) = fixture()
        let cap = try #require(state.capabilities.equalizer)
        #expect(cap.presets.map(\.id) == [0, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0, 0xA1, 0xA2])
        #expect(cap.hasClearBass && cap.bandCount == 5 && cap.bandRange == -10...10)
        #expect(cap.supportsBandEditing && cap.supportsCustomBank && state.equalizerAvailable == true)
        #expect(state.equalizer == .init(presetID: 0, bands: [0, 0, 0, 0, 0], clearBass: 0))
        #expect(try driver.equalizerPayload(.equalizerPreset(0xA1)) == [0x58, 1, 0xA1, 0])
        #expect(throws: DriverError.self) { try driver.equalizerPayload(.equalizerPreset(0xA5)) }
        #expect(throws: DriverError.self) {
            try driver.equalizerPayload(.equalizerBands(bands: [0, 0, 0, 0, 0], clearBass: 0))
        }
    }

    @Test func bandEncodingRequiresAnEditableTargetAndNeverClampsOrInventsBass() throws {
        let (state, driver) = fixture()
        receive(custom, driver)
        #expect(try driver.equalizerPayload(.equalizerBands(bands: [-10, 10, 0, -1, 1], clearBass: nil))
                == [0x58, 1, 0xFF, 6, 12, 0, 20, 10, 9, 11])
        for change: DeviceChange in [.equalizerBands(bands: [0], clearBass: 0),
            .equalizerBands(bands: [11, 0, 0, 0, 0], clearBass: 0),
            .equalizerBands(bands: [0, 0, 0, 0, 0], clearBass: -11)] {
            #expect(throws: (any Error).self) { try driver.equalizerPayload(change) }
        }
        state.equalizer?.clearBass = nil
        #expect(throws: (any Error).self) {
            try driver.equalizerPayload(.equalizerBands(bands: [0, 0, 0, 0, 0], clearBass: nil))
        }
        state.equalizer = nil
        #expect(throws: DriverError.self) {
            try driver.equalizerPayload(.equalizerBands(bands: [0, 0, 0, 0, 0], clearBass: 0))
        }
        receive(custom, driver)
        state.equalizerAvailable = false
        #expect(throws: DriverError.self) { try driver.equalizerPayload(.equalizerPreset(0)) }
    }

    @Test func statusAndParameterParsingRejectsMalformedAndUnrelatedReplies() {
        let (state, driver) = fixture()
        receive(custom, driver)
        let before = state.equalizer
        for p: [UInt8] in [[0x55, 2, 1], [0x55, 3, 1], [0x59, 2, 0xA1, 0], [0x59, 3, 0xA1, 0]] {
            receive(p, driver)
        }
        receive([0x59, 1, 0xA1, 0], driver, table: .dataMdrNo2)
        #expect(state.equalizer == before && state.equalizerAvailable == true)
        for p: [UInt8] in [[0x55, 1], [0x53, 1, 0xFF], [0x55, 1, 0, 0]] {
            receive(status, driver)
            state.equalizerBank = .init(activePresetID: 0xA2, curves: [])
            receive(p, driver)
            #expect(state.equalizerAvailable == nil && state.equalizerBank == nil)
        }
        for p in [Array(custom.dropLast()), custom + [0], [0x57, 1, 0xA2, 1, 10],
                  [0x57, 1, 0xA5, 0], [0x57, 1, 0xFF, 0], [0x59, 1, 0xA2, 6, 21, 10, 10, 10, 10, 10]] {
            receive(custom, driver)
            state.equalizerBank = .init(activePresetID: 0xA2, curves: [])
            receive(p, driver)
            #expect(state.equalizer == nil && state.equalizerBank == nil)
        }
        receive(custom, driver)
        receive([0x59, 1, 0xA1, 0], driver)
        #expect(state.equalizer == .init(presetID: 0xA1, bands: [], clearBass: nil))
    }

    @Test func fixedAndUnsupportedConfigurationsCannotEditOrCollectBands() throws {
        let (state, driver) = fixture()
        let before = state.capabilities.equalizer
        for p in [Array(capability.dropLast()), capability + [0], [0x51, 2, 0, 20],
                  [0x51, 3, 0, 0, 2, 0x10, 0, 0x10, 0], [0x51, 3, 0, 0, 1, 0xFF, 0]] {
            receive(p, driver)
            #expect(state.capabilities.equalizer == before && state.equalizerAvailable == true)
        }
        receive([0x51, 3, 0, 0, 2, 0x10, 0, 0x11, 0], driver)
        #expect(state.equalizer == nil && state.equalizerAvailable == nil && state.equalizerBank == nil)
        receive([0x53, 3, 0], driver)
        receive([0x57, 3, 0x10, 0], driver)
        let cap = try #require(state.capabilities.equalizer)
        #expect(!cap.supportsBandEditing && !cap.supportsCustomBank)
        #expect(try driver.equalizerPayload(.equalizerPreset(0x11)) == [0x58, 3, 0x11, 0])
        #expect(throws: DriverError.self) { try driver.equalizerPayload(.equalizerBands(bands: [], clearBass: nil)) }
        let scene = SoundScene(name: "Curve", symbol: "headphones", tint: .sage,
            equalizer: .custom(bands: [], clearBass: nil))
        #expect(scene.changes(for: state).changes.isEmpty)
        #expect(try SavedHeadphoneSetting.equalizer(.init(presetID: 0x10, bands: [], clearBass: nil)).changes(for: state).count == 1)
        receive([0x51, 1, 6, 13, 1, 0xA0, 0], driver)
        #expect(state.capabilities.equalizer?.supportsBandEditing == false)
        #expect(state.capabilities.equalizer?.supportsCustomBank == false)
    }

    @Test func changedPresetOrUnavailableStatusStopsBeforeAnUnspecifiedBandWrite() async throws {
        for fail in 0...5 {
            let (state, driver) = fixture()
            receive(custom, driver)
            var sent = 0
            do {
                try await driver.applyEqualizer(.equalizerBands(bands: [0, 1, 2, 3, 4], clearBass: 0),
                    send: { _ in sent += 1 }, request: { p, _ in
                        if p[0] == 0x52 {
                            if fail == 0 { receive([0x53, 1, 1], driver) }
                            else if fail == 1 { receive([0x53, 1, 0xFF], driver) }
                            else if fail == 2 { throw MDRLink.LinkError.closed }
                            else { receive(status, driver) }
                        } else {
                            if fail == 3 { receive([0x57, 1, 0xA1, 0], driver) }
                            if fail == 4 { receive(Array(custom.dropLast()), driver) }
                            if fail == 5 {
                                receive(custom, driver)
                                receive([0x55, 1, 1], driver)
                            }
                        }
                    })
                Issue.record("Unconfirmed active EQ slot must prevent a band write")
            } catch {}
            #expect(sent == 0 && state.equalizerBank == nil)
        }
    }

    @Test func successfulPresetAndCurveWritesUseSeparateCommandsAndFreshReadback() async throws {
        let (state, driver) = fixture()
        var sent: [[UInt8]] = []
        var requested: [[UInt8]] = []
        try await driver.applyEqualizer(.equalizerPreset(0xA2), send: { sent.append($0) }, request: { p, _ in
            requested.append(p)
            receive(p[0] == 0x52 ? status : custom, driver)
        })
        #expect(sent == [[0x58, 1, 0xA2, 0]] && requested == [[0x52, 1], [0x56, 1]])
        sent = []; requested = []
        let bands = [-10, -2, 0, 3, 10]
        try await driver.applyEqualizer(.equalizerBands(bands: bands, clearBass: nil),
            send: { sent.append($0) }, request: { p, _ in
                requested.append(p)
                if p[0] == 0x52 { receive(status, driver) }
                else if sent.isEmpty { receive(custom, driver) }
                else { receive([0x57, 1, 0xA2, 6, 12, 0, 8, 10, 13, 20], driver) }
            })
        #expect(sent == [[0x58, 1, 0xFF, 6, 12, 0, 8, 10, 13, 20]])
        #expect(requested == [[0x52, 1], [0x56, 1], [0x56, 1]])
        #expect(state.equalizer == .init(presetID: 0xA2, bands: bands, clearBass: 2))
    }

    @Test func failedReadbackOrDifferentDestinationCannotConfirmTheOldCurve() async throws {
        for failure in 0...3 {
            let (state, driver) = fixture()
            receive(custom, driver)
            let original = try #require(state.equalizer)
            var sent = false
            do {
                try await driver.applyEqualizer(.equalizerBands(bands: original.bands, clearBass: original.clearBass),
                    send: { _ in sent = true; if failure == 0 { throw MDRLink.LinkError.closed } },
                    request: { p, _ in
                        if p[0] == 0x52 { receive(status, driver); return }
                        if !sent { receive(custom, driver); return }
                        if failure == 1 { throw MDRLink.LinkError.closed }
                        if failure == 2 { receive(Array(custom.dropLast()), driver) }
                        if failure == 3 {
                            var other = custom; other[2] = 0xA1
                            receive(other, driver)
                        }
                    })
                Issue.record("Failed or misdirected read-back was accepted")
            } catch {}
            #expect(sent && state.equalizerBank == nil)
            if failure != 3 { #expect(state.equalizer == nil) }
            else { #expect(state.equalizer?.presetID == 0xA1) }
        }
    }

    @Test func genericNoBassLayoutsUseReportedStepsAndRejectExtraBass() throws {
        for bandCount: UInt8 in [5, 10] {
            let (state, driver) = fixture()
            receive([0x51, 1, bandCount, 13, 1, 0xA0, 0], driver)
            receive(status, driver)
            receive([0x57, 1, 0xA0, bandCount] + Array(repeating: 6, count: Int(bandCount)), driver)
            let bands = Array(repeating: -6, count: Int(bandCount))
            #expect(state.capabilities.equalizer?.bandRange == -6...6 && state.equalizer?.clearBass == nil)
            #expect(try driver.equalizerPayload(.equalizerBands(bands: bands, clearBass: nil))
                    == [0x58, 1, 0xFF, bandCount] + Array(repeating: 0, count: Int(bandCount)))
            #expect(throws: (any Error).self) { try driver.equalizerPayload(.equalizerBands(bands: bands, clearBass: 0)) }
        }
    }
}
