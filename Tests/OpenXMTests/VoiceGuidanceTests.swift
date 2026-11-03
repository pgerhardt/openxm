import Foundation
import Testing
@testable import OpenXM

@MainActor struct VoiceGuidanceTests {
    // Actual WH-1000XM3 4.5.2 capability reply, 2026-10-29. Other packets below are
    // reference-derived synthetic examples, not evidence of a language download or installation.
    static let xm3: [UInt8] = [0x41, 1, 1, 1, 15, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 16, 0xF0]

    private func receive(_ bytes: [UInt8], _ driver: V1Driver, table: MDRDataType = .dataMdrNo2) {
        driver.handle(MDRFrame(type: table, sequence: 0, payload: bytes))
    }

    private func string(_ value: String) -> [UInt8] { [UInt8(value.utf8.count)] + Array(value.utf8) }

    private var serviceReply: [UInt8] {
        // Deliberately synthetic identifiers; these must never be used to fetch a package.
        [0x47, 1, 4, 1] + string("TEST_CATEGORY") + string("1234567") + [2, 1]
            + string("TEST_EN_SERVICE") + [0x0B] + string("TEST_JA_SERVICE")
    }

    @Test func capturedXM3CapabilityUsesWireLanguageCodes() throws {
        let cap = try V1VoiceGuidance.capability(Self.xm3)
        #expect(cap.supportsOnOff && cap.supportsLanguage)
        #expect(cap.languages.count == 15)
        #expect(cap.languages.suffix(5).map(\.title) == ["Japanese", "Brazilian Portuguese", "Korean", "Turkish", "Chinese"])
        #expect(GuidanceLanguage(rawValue: 0x0C).title == "Simplified Chinese")
        #expect(GuidanceLanguage(rawValue: 0x0E).title == "Traditional Chinese")
        #expect(GuidanceLanguage(rawValue: 0xAB).title == "Unknown language (0xAB)")
        let unknown = try V1VoiceGuidance.capability([0x41, 1, 0, 1, 1, 0xAB])
        #expect(unknown.languages == [.init(rawValue: 0xAB)])
    }

    @Test func capabilityRejectsTruncationInvalidFlagsAndDuplicateLanguages() throws {
        for length in 0..<Self.xm3.count {
            #expect(throws: (any Error).self) { try V1VoiceGuidance.capability(Array(Self.xm3.prefix(length))) }
        }
        for invalid: [UInt8] in [[0x41, 2, 1, 0], [0x41, 1, 2, 0], [0x41, 1, 1, 2],
                                  [0x41, 1, 1, 0, 0], [0x41, 1, 1, 1, 0],
                                  [0x41, 1, 1, 1, 2, 1, 1], [0x41, 1, 1, 1, 1, 0], Self.xm3 + [0]] {
            #expect(throws: (any Error).self) { try V1VoiceGuidance.capability(invalid) }
        }
        #expect(try V1VoiceGuidance.capability([0x41, 1, 1, 0]) == .init(supportsOnOff: true, supportsLanguage: false, languages: []))
    }

    @Test func discoveryQueriesRequireCapabilityAndMatchTheirExactDetail() throws {
        #expect(V1VoiceGuidance.queries(for: nil).isEmpty)
        let none = try V1VoiceGuidance.capability([0x41, 1, 0, 0])
        #expect(V1VoiceGuidance.queries(for: none).isEmpty)
        let toggleOnly = try V1VoiceGuidance.capability([0x41, 1, 1, 0])
        #expect(V1VoiceGuidance.queries(for: toggleOnly).map(\.payload) == [[0x42, 1, 1], [0x46, 1, 1]])
        let queries = V1VoiceGuidance.queries(for: try V1VoiceGuidance.capability(Self.xm3))
        #expect(queries.map(\.payload) == [[0x42, 1, 1], [0x46, 1, 1], [0x42, 1, 2], [0x46, 1, 2], [0x46, 1, 3], [0x46, 1, 4], [0x46, 1, 5]])
        for query in queries {
            let reply = [query.command + 1, 1, query.detail, 1]
            #expect(query.reply.matches(.init(type: .dataMdrNo2, sequence: 0, payload: reply)))
            #expect(!query.reply.matches(.init(type: .dataMdr, sequence: 0, payload: reply)))
            #expect(!query.reply.matches(.init(type: .dataMdrNo2, sequence: 0, payload: [reply[0], 1, query.detail + 1, 1])))
        }
    }

    @Test func parametersRemainIndependentAndMalformedRepliesDoNotMutateState() throws {
        let state = DeviceState()
        let target = V1Driver(link: MDRLink(transport: nil), state: state)
        receive(Self.xm3, target)
        receive([0x47, 1, 1, 1], target)
        receive([0x47, 1, 2, 0x0B], target)
        receive([0x47, 1, 3, 45], target)
        receive([0x43, 1, 2, 1], target)
        #expect(state.voiceGuidance == true)
        #expect(state.voiceGuidanceDetails.language?.title == "Japanese")
        #expect(state.voiceGuidanceDetails.requiredTime == 45)
        #expect(state.voiceGuidanceDetails.languageUpdateEnabled == false)
        let before = state.voiceGuidanceDetails
        for invalid: [UInt8] in [[0x47, 1, 2], [0x47, 1, 2, 1, 0], [0x47, 2, 2, 1],
                                  [0x47, 1, 1, 2], [0x43, 1, 2], [0x47, 1, 3, 1, 2]] {
            receive(invalid, target)
            #expect(state.voiceGuidanceDetails == before)
            #expect(state.voiceGuidance == true)
        }
        receive([0x47, 1, 2, 0xAB], target)
        #expect(state.voiceGuidanceDetails.language?.rawValue == 0xAB)
        receive([0x45, 1, 2, 0xFF], target)
        #expect(state.voiceGuidanceDetails.languageUpdateEnabled == nil)
        receive([0x47, 1, 2], target, table: .dataMdr) // same opcode means surround on table 1
        #expect(state.surroundPreset == 2)
        #expect(state.voiceGuidanceDetails.language?.rawValue == 0xAB)
    }

    @Test func serviceIdentifiersAreExactAndMalformedListsCannotPartiallyReplaceThem() throws {
        let state = DeviceState()
        let target = V1Driver(link: MDRLink(transport: nil), state: state)
        receive(serviceReply, target)
        let service = try #require(state.voiceGuidanceDetails.downloadService)
        #expect(service.categoryID == "TEST_CATEGORY" && service.serialNumber == "1234567")
        #expect(service.entries.map(\.serviceID) == ["TEST_EN_SERVICE", "TEST_JA_SERVICE"])
        #expect(service.entries.map(\.language.rawValue) == [1, 11])
        for length in 0..<serviceReply.count {
            receive(Array(serviceReply.prefix(length)), target)
            #expect(state.voiceGuidanceDetails.downloadService == service)
        }
        let base: [UInt8] = [0x47, 1, 4, 1]
        let duplicates = base + string("TEST") + string("123") + [2, 1] + string("FIRST") + [1] + string("SECOND")
        let path = base + string("../HP001") + string("123") + [1, 1] + string("TEST")
        let tooLong = base + [129] + Array(repeating: UInt8(65), count: 129) + string("123") + [1, 1] + string("TEST")
        for invalid in [duplicates, path, tooLong, serviceReply + [0]] {
            #expect(throws: (any Error).self) { try V1VoiceGuidance.reply(invalid) }
            receive(invalid, target)
            #expect(state.voiceGuidanceDetails.downloadService == service)
        }
        receive([0x47, 1, 4, 0xAB], target)
        #expect(state.voiceGuidanceDetails.downloadService == nil)
    }

    @Test func csrMethodRequiresCompleteParametersAndUnknownMethodsStayUnknown() throws {
        guard case .updateMethod(let csr) = try V1VoiceGuidance.reply([0x47, 1, 5, 0x11, 0xFC, 50]) else {
            Issue.record("Expected CSR update method"); return
        }
        #expect(csr.isCSR && csr.code == 0x11 && csr.transmitPower == -4 && csr.batteryThreshold == 50)
        for invalid: [UInt8] in [[0x47, 1, 5], [0x47, 1, 5, 0x11], [0x47, 1, 5, 0x11, 1], [0x47, 1, 5, 0x11, 1, 50, 0]] {
            #expect(throws: (any Error).self) { try V1VoiceGuidance.reply(invalid) }
        }
        guard case .updateMethod(let unknown) = try V1VoiceGuidance.reply([0x47, 1, 5, 0xAB, 0xFC, 50]) else {
            Issue.record("Expected preserved unknown method"); return
        }
        #expect(!unknown.isCSR && unknown.code == 0xAB && unknown.transmitPower == nil && unknown.batteryThreshold == nil)
    }

    @Test func toggleWritesRequireDeviceSupportAndAvailability() throws {
        let state = DeviceState()
        state.supportFunctions = [0x39]
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        #expect(throws: (any Error).self) { try driver.voiceGuidancePayload(true) }
        receive(Self.xm3, driver)
        #expect(throws: (any Error).self) { try driver.voiceGuidancePayload(true) }
        receive([0x43, 1, 1, 0], driver)
        #expect(try driver.voiceGuidancePayload(true) == [0x48, 1, 1, 1])
        #expect(try driver.voiceGuidancePayload(false) == [0x48, 1, 1, 0])
        receive([0x45, 1, 1, 1], driver)
        #expect(throws: (any Error).self) { try driver.voiceGuidancePayload(true) }
        receive([0x45, 1, 1, 0xFF], driver)
        #expect(throws: (any Error).self) { try driver.voiceGuidancePayload(true) }
    }

    @Test func changedCapabilitiesAndDisconnectClearLanguageAndServices() throws {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        receive(Self.xm3, driver)
        receive([0x47, 1, 2, 1], driver)
        receive(serviceReply, driver)
        let before = state.voiceGuidanceDetails
        receive(Self.xm3, driver) // repeated same capability must not erase fresh values
        #expect(state.voiceGuidanceDetails == before)
        receive([0x41, 1, 1, 0], driver)
        #expect(state.voiceGuidanceDetails == VoiceGuidanceDetails())
        #expect(state.capabilities.voiceGuidance && state.capabilities.voiceGuidanceCapability?.supportsLanguage == false)
        receive(Self.xm3, driver)
        receive(serviceReply, driver)
        state.reset()
        #expect(state.voiceGuidanceDetails == VoiceGuidanceDetails())
        #expect(state.capabilities.voiceGuidanceCapability == nil && !state.capabilities.voiceGuidance)
    }
}
