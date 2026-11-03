import Foundation
import Testing
@testable import OpenXM

@MainActor struct NoiseControlTests {
    // These three replies were captured from the user's WH-1000XM3 4.5.2.
    // Other values and control sequences below are explicitly synthetic, including failure cases.
    private let capability: [UInt8] = [0x61, 2, 2, 0, 1, 2, 0, 20, 1, 20]
    private let status: [UInt8] = [0x63, 2, 0]
    private let parameter: [UInt8] = [0x67, 2, 1, 2, 2, 1, 0, 0]

    private func receive(_ p: [UInt8], _ driver: V1Driver, table: MDRDataType = .dataMdr) {
        driver.handle(.init(type: table, sequence: 0, payload: p))
    }

    private func fixture() -> (DeviceState, V1Driver) {
        let state = DeviceState()
        state.family = .v1; state.modelName = "WH-1000XM3"; state.firmware = "4.5.2"
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        for p in [capability, status, parameter] { receive(p, driver) }
        return (state, driver)
    }

    @Test func recordedStatusControlsAvailabilityAndResetClearsIt() {
        let (state, driver) = fixture()
        #expect(state.noise?.mode == .noiseCancelling && state.noiseControlAvailable)
        receive([0x65, 2, 1], driver)
        #expect(state.noiseAvailable == false && !state.noiseControlAvailable)
        // Status changes do not pretend the reported setting changed.
        #expect(state.noise?.mode == .noiseCancelling)
        for invalid: [UInt8] in [[0x65, 2, 0xFF], [0x63, 2], [0x63, 2, 0, 0]] {
            receive(status, driver)
            receive(invalid, driver)
            #expect(state.noiseAvailable == nil && !state.noiseControlAvailable)
        }
        receive(status, driver)
        receive([0x65, 3, 1], driver)
        receive([0x65, 2, 1], driver, table: .dataMdrNo2)
        #expect(state.noiseAvailable == true)
        state.reset()
        #expect(state.noiseAvailable == nil && !state.noiseControlAvailable)
    }

    @Test func malformedParametersCannotConfirmEarlierValuesOrAnotherSettingType() {
        let (state, driver) = fixture()
        for index in [2, 3, 4, 5, 6, 7] {
            var invalid = parameter; invalid[index] = 0xFF
            receive(parameter, driver)
            receive(invalid, driver)
            #expect(state.noise == nil && !state.noiseControlAvailable)
        }
        for invalid in [Array(parameter.dropLast()), parameter + [0],
                        [0x67, 2, 1, 0, 1, 1, 0, 0], // setting type differs from capability
                        [0x67, 2, 1, 2, 0, 1, 0, 0]] { // active ambient with no level
            receive(parameter, driver)
            receive(invalid, driver)
            #expect(state.noise == nil)
        }
        receive(parameter, driver)
        let before = state.noise
        receive([0x69, 3, 1, 1, 0, 12], driver)
        receive([0x69, 2, 1, 2, 0, 1, 1, 12], driver, table: .dataMdrNo2)
        #expect(state.noise == before)
    }

    @Test func unavailableScenesAndRestoresDoNotScheduleNoiseWrites() throws {
        let (state, _) = fixture()
        let saved = SavedHeadphoneSetting.noise(try #require(state.noise))
        var scene = SoundScene(name: "Ambient", symbol: "ear", tint: .sage)
        scene.noise = .init(mode: .ambient, ambientLevel: 12, focusOnVoice: true)
        for available: Bool? in [nil, false] {
            state.noiseAvailable = available
            #expect(scene.changes(for: state).changes.isEmpty)
            #expect(scene.changes(for: state).skipped == [NoiseMode.ambient.title])
            #expect(throws: SettingsBackupError.self) { try saved.changes(for: state) }
        }
        state.noiseAvailable = true
        #expect(scene.changes(for: state).changes.count == 1)
        #expect(try saved.changes(for: state).count == 1)
        // V2 availability has a different protocol path, unchanged by this V1 implementation.
        state.family = .v2; state.noiseAvailable = nil
        #expect(state.noiseControlAvailable)
    }

    @Test func freshUnavailableOrMissingStatusCannotSendAChange() async throws {
        for reply: [UInt8]? in [[0x63, 2, 1], [0x63, 2, 0xFF], [0x63, 2], [0x63, 3, 0], nil] {
            let (state, driver) = fixture()
            let target = try #require(state.noise)
            var sent: [[UInt8]] = []
            var requested: [[UInt8]] = []
            do {
                try await driver.applyNoise(target, dragging: false, send: { sent.append($0) }, request: { p, matcher in
                    requested.append(p)
                    #expect(matcher.command == 0x63 && matcher.selector == 2)
                    guard let reply else { throw MDRLink.LinkError.closed }
                    receive(reply, driver)
                })
                Issue.record("An unavailable or unknown status cannot authorize a write")
            } catch {}
            #expect(sent.isEmpty && requested == [[0x62, 2]])
            #expect(state.noiseAvailable != true)
        }
        for available: Bool? in [nil, false] {
            let (state, driver) = fixture(); state.noiseAvailable = available
            for dragging in [false, true] {
                await #expect(throws: DriverError.self) {
                    try await driver.applyNoise(try #require(state.noise), dragging: dragging,
                        send: { _ in Issue.record("Disabled control sent a command") },
                        request: { _, _ in Issue.record("Disabled control started a request") })
                }
            }
        }
    }

    @Test func offResumeStillCommitsRequestedModeAndKeepsLastReportedAmbientLevel() async throws {
        let (state, driver) = fixture()
        receive([0x67, 2, 1, 2, 0, 1, 0, 12], driver)
        receive([0x67, 2, 0, 2, 1, 1, 0, 0], driver)
        let target = NoiseControl(mode: .ambient, ambientLevel: 20, focusOnVoice: false)
        var sent: [[UInt8]] = []
        var requests: [[UInt8]] = []
        try await driver.applyNoise(target, dragging: false, send: { sent.append($0) }, request: { p, _ in
            requests.append(p)
            if p[0] == 0x62 { receive(status, driver); return }
            receive(sent.count == 1 ? [0x67, 2, 1, 2, 1, 1, 0, 0] : [0x67, 2, 1, 2, 0, 1, 0, 20], driver)
        })
        #expect(sent == [[0x68, 2, 1, 2, 0, 1, 0, 20], [0x68, 2, 0x11, 2, 0, 1, 0, 20]])
        #expect(requests == [[0x62, 2], [0x66, 2], [0x66, 2]])
        #expect(DeviceChange.noise(target, dragging: false).isReflected(in: state) == true)
        try await driver.applyNoise(.init(mode: .noiseCancelling, ambientLevel: 20, focusOnVoice: false), dragging: false,
            send: { _ in }, request: { p, _ in receive(p[0] == 0x62 ? status : parameter, driver) })
        #expect(state.noise?.mode == .noiseCancelling && state.noise?.ambientLevel == 20)
    }

    @Test func failedOrMalformedReadbackCannotReusePreWriteState() async throws {
        for failure in 0...2 {
            let (state, driver) = fixture()
            let target = try #require(state.noise)
            do {
                try await driver.applyNoise(target, dragging: false, send: { _ in
                    if failure == 0 { throw MDRLink.LinkError.closed }
                }, request: { p, _ in
                    if p[0] == 0x62 { receive(status, driver); return }
                    if failure == 1 { throw MDRLink.LinkError.closed }
                    receive(Array(parameter.dropLast()), driver)
                })
                Issue.record("Missing read-back was accepted")
            } catch {}
            #expect(state.noise == nil)
            #expect(DeviceChange.noise(target, dragging: false).isReflected(in: state) == false)
        }
    }

    @Test func availabilityLossDuringResumePreventsTheSecondWrite() async throws {
        let (state, driver) = fixture()
        receive([0x67, 2, 0, 2, 1, 1, 0, 0], driver)
        var sent = 0
        await #expect(throws: DriverError.self) {
            try await driver.applyNoise(.init(mode: .ambient, ambientLevel: 12, focusOnVoice: false), dragging: false,
                send: { _ in sent += 1 }, request: { p, _ in
                    if p[0] == 0x62 { receive(status, driver); return }
                    receive([0x65, 2, 1], driver)
                    receive([0x67, 2, 1, 2, 1, 1, 0, 0], driver)
                })
        }
        #expect(sent == 1 && state.noiseAvailable == false)
    }

    @Test func dragChecksStatusAndRangeWhileNewerNotificationsRemainAuthoritative() async throws {
        let (state, driver) = fixture()
        let target = NoiseControl(mode: .ambient, ambientLevel: 12, focusOnVoice: true)
        var sent: [[UInt8]] = []
        try await driver.applyNoise(target, dragging: true, send: { sent.append($0) },
            request: { _, _ in Issue.record("A drag should not start a status/read-back round trip") })
        #expect(sent == [[0x68, 2, 0x10, 2, 0, 1, 1, 12]])
        #expect(state.noise?.mode == .noiseCancelling) // Sending is not confirmation.
        await #expect(throws: DriverError.self) {
            try await driver.applyNoise(.init(mode: .ambient, ambientLevel: 21, focusOnVoice: false), dragging: true,
                send: { _ in Issue.record("Out-of-range drag was sent") }, request: { _, _ in })
        }
        let original = try #require(state.noise)
        try await driver.applyNoise(original, dragging: false, send: { _ in }, request: { p, _ in
            if p[0] == 0x62 { receive(status, driver); return }
            receive(parameter, driver)
            receive([0x69, 2, 1, 2, 0, 1, 1, 12], driver)
        })
        #expect(state.noise?.mode == .ambient && state.noise?.focusOnVoice == true)
        #expect(DeviceChange.noise(original, dragging: false).isReflected(in: state) == false)
    }
}
