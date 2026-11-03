import Foundation
import Testing
@testable import OpenXM

@MainActor struct NoiseOptimizerTests {
    // Saved XM3 4.5.2 read replies. Progress/control exchanges below are reference-derived fixtures,
    // not captures of a physical optimization run.
    private let capability: [UInt8] = [0x81, 1, 2, 1, 9, 1, 2]

    private func receive(_ p: [UInt8], _ driver: V1Driver, table: MDRDataType = .dataMdr) {
        driver.handle(.init(type: table, sequence: 0, payload: p))
    }

    @Test func capturedCapabilitiesAndResults() throws {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        receive(capability, driver)
        receive([0x83, 1, 0, 0], driver)
        receive([0x87, 1, 1, 1, 1, 8], driver)
        #expect(state.capabilities.ncOptimizer)
        #expect(state.capabilities.ncOptimizerCapability?.estimatedSeconds == 13)
        #expect(state.optimizer == .idle && state.optimizerAvailable == true)
        #expect(state.optimizerPersonalMeasured == true && state.optimizerMeasuredPressure == 8)
        #expect(try V1NoiseOptimizer.control(start: true, supported: true,
            capability: state.capabilities.ncOptimizerCapability,
            status: .init(available: true, phase: .idle)) == [0x84, 1, 0, 1])
        state.reset()
        #expect(state.optimizer == .unknown(nil) && state.optimizerAvailable == nil)
        #expect(state.optimizerPersonalMeasured == nil && state.optimizerMeasuredPressure == nil)
        #expect(state.capabilities.ncOptimizerCapability == nil)
    }

    @Test func idleNeverMeansSuccessfulCompletionAndUnknownIsNotRunning() {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        for (byte, phase): (UInt8, OptimizerPhase) in [(1, .measuringPersonal), (2, .measuringPressure), (0x10, .running)] {
            receive([0x85, 1, 0, byte], driver)
            #expect(state.optimizer == phase && state.optimizer.isActive)
            receive([0x85, 1, 0, 0], driver) // Cancellation / return to idle, not success.
            #expect(state.optimizer == .idle && !state.optimizer.isActive)
        }
        receive([0x85, 1, 0, 0x11], driver)
        #expect(state.optimizer == .finished)
        receive([0x85, 1, 0, 0xFF], driver)
        #expect(state.optimizer == .unknown(0xFF))
        #expect(!state.optimizer.canStart && !state.optimizer.isActive)
        receive([0x85, 1, 0xFF, 0], driver)
        #expect(state.optimizerAvailable == nil)
    }

    @Test func malformedAndUnrelatedPacketsDoNotChangeState() {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        receive(capability, driver)
        let knownCapability = state.capabilities.ncOptimizerCapability
        let packets: [[UInt8]] = [capability, [0x85, 1, 0, 0x11], [0x89, 1, 1, 1, 1, 7]]
        for packet in packets {
            for length in 1..<packet.count { receive(Array(packet.prefix(length)), driver) }
            receive(packet + [0], driver)
            var unrelated = packet; unrelated[1] = 2
            receive(unrelated, driver)
            receive(packet, driver, table: .dataMdrNo2)
        }
        #expect(state.capabilities.ncOptimizerCapability == knownCapability)
        #expect(state.optimizer == .unknown(nil) && state.optimizerAvailable == nil)
        #expect(state.optimizerPersonalMeasured == nil && state.optimizerMeasuredPressure == nil)
    }

    @Test func measurementTypesMustMatchAndUnknownValuesClearOldResults() {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        receive(capability, driver)
        receive([0x89, 1, 1, 1, 1, 10], driver)
        receive([0x89, 1, 0, 0, 1, 7], driver) // Wrong measurement type: ignore the whole reply.
        #expect(state.optimizerPersonalMeasured == true && state.optimizerMeasuredPressure == 10)
        receive([0x89, 1, 1, 0xFF, 1, 6], driver)
        #expect(state.optimizerPersonalMeasured == nil && state.optimizerMeasuredPressure == nil)
        receive([0x89, 1, 1, 0, 1, 0], driver)
        #expect(state.optimizerPersonalMeasured == false && state.optimizerMeasuredPressure == nil)
        receive([0x81, 1, 2, 0, 99, 1, 3], driver) // Unsupported personal stage contributes no time.
        #expect(state.capabilities.ncOptimizerCapability?.estimatedSeconds == 5)
        receive([0x89, 1, 0, 1, 1, 7], driver)
        #expect(state.optimizerPersonalMeasured == nil && state.optimizerMeasuredPressure == 7)
    }

    @Test func freshStatusBlocksUnavailableOrAlreadyRunningStarts() async throws {
        let cap = try #require(V1NoiseOptimizer.capability(capability))
        for current: [UInt8] in [[0x83, 1, 1, 0], [0x83, 1, 0xFF, 0], [0x83, 1, 0, 1], [0x83, 1, 0, 0xFF], [0x83, 1, 0]] {
            var sent: [[UInt8]] = []
            let request: ([UInt8], MDRLink.Matcher) async throws -> [UInt8] = { p, matcher in
                sent.append(p)
                #expect(matcher.command == 0x83 && matcher.selector == 1 && matcher.table == .dataMdr)
                return current
            }
            await #expect(throws: (any Error).self) {
                try await V1NoiseOptimizer.perform(start: true, supported: true, capability: cap, request: request)
            }
            #expect(sent == [[0x82, 1]])
        }
        var calls = 0
        let request: ([UInt8], MDRLink.Matcher) async throws -> [UInt8] = { _, _ in calls += 1; return [] }
        await #expect(throws: (any Error).self) {
            try await V1NoiseOptimizer.perform(start: true, supported: false, capability: cap, request: request)
        }
        await #expect(throws: (any Error).self) {
            try await V1NoiseOptimizer.perform(start: true, supported: true, capability: nil, request: request)
        }
        #expect(calls == 0)
    }

    @Test func controlNeedsNotificationAndNeverInventsState() async throws {
        let state = DeviceState()
        state.supportFunctions = [0x81]
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        receive(capability, driver)
        let cap = try #require(state.capabilities.ncOptimizerCapability)
        for start in [true, false] {
            var sent: [[UInt8]] = []
            let request: ([UInt8], MDRLink.Matcher) async throws -> [UInt8] = { p, matcher in
                sent.append(p)
                let response: [UInt8]
                if p[0] == 0x82 {
                    response = [0x83, 1, start ? 0 : 1, start ? 0 : 2]
                } else {
                    // Cancel remains possible while the reported running optimizer disables new starts.
                    response = [0x85, 1, 0, start ? 1 : 0]
                }
                #expect(matcher.matches(.init(type: .dataMdr, sequence: 0, payload: response)))
                receive(response, driver)
                return response
            }
            try await V1NoiseOptimizer.perform(start: start, supported: true, capability: cap, request: request)
            #expect(sent == [[0x82, 1], [0x84, 1, 0, start ? 1 : 0]])
            #expect(state.optimizer == (start ? .measuringPersonal : .idle))
        }
        for response: [UInt8]? in [nil, [0x85, 1, 0, 0], [0x85, 1, 0, 0xFF], [0x85, 1]] {
            let request: ([UInt8], MDRLink.Matcher) async throws -> [UInt8] = { p, _ in
                if p[0] == 0x82 { return [0x83, 1, 0, 0] }
                guard let response else { throw MDRLink.LinkError.replyTimeout(command: 0x84) }
                return response
            }
            await #expect(throws: (any Error).self) {
                try await V1NoiseOptimizer.perform(start: true, supported: true, capability: cap, request: request)
            }
            #expect(state.optimizer == .idle) // No optimistic .running mutation on a send/ACK/timeout.
        }
        await #expect(throws: MDRLink.LinkError.self) { try await driver.startNoiseOptimizer() }
        #expect(state.optimizer == .idle) // A replay link never writes.
    }
}
