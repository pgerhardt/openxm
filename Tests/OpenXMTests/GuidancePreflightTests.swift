import Foundation
import Testing
@testable import OpenXM

@MainActor struct GuidancePreflightTests {
    private let address = "00:11:22:33:44:55" // Synthetic address; no Bluetooth access in this suite.
    private let request = GuidancePackageRequest(category: "TEST_CATEGORY", service: "TEST_EN_SERVICE",
        model: "WH-1000XM3", firmware: "2.0.0", serial: "0123456", language: .init(rawValue: 1))
    private let payload = Data("SYNTHETIC VOICE PACKAGE TEST DATA\n".utf8)

    private func fixture(_ name: String, ext: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
    }
    private func source(notice: Bool = false) throws -> GuidanceMetadataDownload {
        try .init(data: fixture(notice ? "synthetic-voice-notice-info" : "synthetic-voice-info", ext: "enc"), request: request)
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func state() -> DeviceState {
        let state = DeviceState()
        state.family = .v1; state.modelName = request.model; state.firmware = request.firmware
        state.capabilities.voiceGuidanceCapability = .init(supportsOnOff: true, supportsLanguage: true,
                                                           languages: [.init(rawValue: 1), .init(rawValue: 11)])
        state.voiceGuidanceDetails.language = .init(rawValue: 11)
        state.voiceGuidanceDetails.languageUpdateEnabled = false
        state.voiceGuidanceDetails.updateMethod = .init(code: 0x11, parameters: [0xFC, 50])
        state.voiceGuidanceDetails.downloadService = .init(categoryID: request.category, serialNumber: request.serial,
            entries: [.init(language: request.language, serviceID: request.service)])
        return state
    }
    private func snapshot(_ state: DeviceState? = nil, address: String? = nil,
                          service: String = "MDRID291600", battery: [UInt8] = [0x11, 0, 90, 0]) throws -> GuidanceDeviceSnapshot {
        try .make(state: state ?? self.state(), address: address ?? self.address, firmwareCategory: "HP001",
                  firmwareService: service, language: request.language, batteryReply: battery)
    }

    @Test func aFreshReadRequiresKnownCurrentLanguageStatusMethodAndExactBatteryReply() throws {
        #expect(try snapshot().battery == 90)
        #expect(try snapshot(address: "00-11-22-33-44-55").address == address)
        for change: (DeviceState) -> Void in [
            { $0.voiceGuidanceDetails.language = nil },
            { $0.voiceGuidanceDetails.language = .init(rawValue: 0) },
            { $0.voiceGuidanceDetails.language = .init(rawValue: 0xAB) },
            {
                $0.voiceGuidanceDetails.language = .init(rawValue: 0xAB)
                $0.capabilities.voiceGuidanceCapability = .init(supportsOnOff: true, supportsLanguage: true,
                    languages: [.init(rawValue: 1), .init(rawValue: 0xAB)])
            },
            { $0.voiceGuidanceDetails.languageUpdateEnabled = nil },
            { $0.voiceGuidanceDetails.updateMethod = nil },
            { $0.voiceGuidanceDetails.downloadService = nil },
            { $0.modelName = "WF-1000XM3" },
            { $0.family = .v2 }
        ] {
            let state = state(); change(state)
            #expect(throws: (any Error).self) { try snapshot(state) }
        }
        for battery: [UInt8] in [[], [0x11, 0, 90], [0x11, 0, 90, 0, 0], [0x11, 0, 101, 0],
                                  [0x11, 0, 90, 2], [0x13, 0, 90, 0], [0x11, 1, 90, 0]] {
            #expect(throws: (any Error).self) { try snapshot(battery: battery) }
        }
        for region in ["MDRID291601", "MDRID291602", ""] {
            #expect(throws: (any Error).self) { try snapshot(service: region) }
        }
        #expect(throws: (any Error).self) { try snapshot(address: "") }
    }

    @Test func originalFilesAndBothOverEarMethodsPassWithoutSendingCommands() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(), archive = try GuidanceDownloads.preserve(payload, source: source, directory: root)
        let date = Date(timeIntervalSince1970: 1234)
        for code: UInt8 in [0x10, 0x11] {
            let state = state(); state.voiceGuidanceDetails.updateMethod = .init(code: code, parameters: [0xFC, 50])
            let result = try GuidancePreflight.check(snapshot: snapshot(state), discoveryAddress: "00-11-22-33-44-55",
                source: source, archive: archive, notice: nil, now: date)
            #expect(result.currentLanguage.rawValue == 11 && result.targetLanguage.rawValue == 1)
            #expect(result.battery == 90 && result.minimumBattery == 80)
            #expect(result.supportsResume == (code == 0x11) && result.checkedAt == date)
        }
        #expect(try Data(contentsOf: archive.packageURL) == payload)
    }

    @Test func preparationBindsTheOriginalHeadsetFirmwareSerialAndLanguageMapping() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(), archive = try GuidanceDownloads.preserve(payload, source: source, directory: root)
        for change: (DeviceState) -> Void in [
            { $0.firmware = "4.5.2" },
            { $0.voiceGuidanceDetails.downloadService = .init(categoryID: "OTHER_CATEGORY", serialNumber: request.serial,
                entries: [.init(language: request.language, serviceID: request.service)]) },
            { $0.voiceGuidanceDetails.downloadService = .init(categoryID: request.category, serialNumber: "7654321",
                entries: [.init(language: request.language, serviceID: request.service)]) },
            { $0.voiceGuidanceDetails.downloadService = .init(categoryID: request.category, serialNumber: request.serial,
                entries: [.init(language: request.language, serviceID: "OTHER_SERVICE")]) }
        ] {
            let state = state(); change(state)
            #expect(throws: (any Error).self) {
                try GuidancePreflight.check(snapshot: snapshot(state), discoveryAddress: address, source: source, archive: archive, notice: nil)
            }
        }
        for wrongAddress in ["00:11:22:33:44:56", ""] {
            #expect(throws: (any Error).self) {
                try GuidancePreflight.check(snapshot: snapshot(), discoveryAddress: wrongAddress, source: source, archive: archive, notice: nil)
            }
        }
    }

    @Test func earbudUnknownAndMalformedMethodsCannotAuthorizePreparation() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(), archive = try GuidanceDownloads.preserve(payload, source: source, directory: root)
        for method in [GuidanceUpdateMethod(code: 0x12, parameters: [0, 50]), .init(code: 0x13, parameters: [0, 50]),
                       .init(code: 0xAB, parameters: [0, 50]), .init(code: 0x10, parameters: [50]),
                       .init(code: 0x11, parameters: [0, 50, 0])] {
            let state = state(); state.voiceGuidanceDetails.updateMethod = method
            #expect(throws: (any Error).self) {
                try GuidancePreflight.check(snapshot: snapshot(state), discoveryAddress: address, source: source, archive: archive, notice: nil)
            }
        }
    }

    @Test func batteryMustExceedDeviceThresholdAndMeetAppFloorWithUSBUnplugged() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(), archive = try GuidanceDownloads.preserve(payload, source: source, directory: root)
        func check(threshold: UInt8, battery: UInt8, charging: UInt8 = 0) throws -> GuidancePreflight {
            let state = state(); state.voiceGuidanceDetails.updateMethod = .init(code: 0x11, parameters: [0, threshold])
            return try GuidancePreflight.check(snapshot: snapshot(state, battery: [0x11, 0, battery, charging]),
                discoveryAddress: address, source: source, archive: archive, notice: nil)
        }
        #expect(try check(threshold: 50, battery: 80).minimumBattery == 80)
        #expect(try check(threshold: 80, battery: 81).minimumBattery == 81)
        #expect(try check(threshold: 99, battery: 100).minimumBattery == 100)
        for pair: (UInt8, UInt8) in [(0, 79), (50, 50), (80, 80), (99, 99), (100, 100), (255, 100)] {
            #expect(throws: (any Error).self) { try check(threshold: pair.0, battery: pair.1) }
        }
        #expect(throws: (any Error).self) { try check(threshold: 50, battery: 100, charging: 1) }
    }

    @Test func enabledUpdateModeAndAlreadyInstalledLanguageAreNotFreshInstallPermission() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(), archive = try GuidanceDownloads.preserve(payload, source: source, directory: root)
        for change: (DeviceState) -> Void in [
            { $0.voiceGuidanceDetails.languageUpdateEnabled = true },
            { $0.voiceGuidanceDetails.language = request.language }
        ] {
            let state = state(); change(state)
            #expect(throws: (any Error).self) {
                try GuidancePreflight.check(snapshot: snapshot(state), discoveryAddress: address, source: source, archive: archive, notice: nil)
            }
        }
    }

    @Test func preparationReopensPackageMetadataAndProvenanceInsteadOfTrustingRememberedHashes() throws {
        for file in ["package.bin", "metadata.enc", "provenance.json"] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let source = try source(), archive = try GuidanceDownloads.preserve(payload, source: source, directory: root)
            let url = archive.directory.appendingPathComponent(file)
            var bytes = try Data(contentsOf: url); bytes[0] ^= 1; try bytes.write(to: url)
            #expect(throws: (any Error).self) {
                try GuidancePreflight.check(snapshot: snapshot(), discoveryAddress: address, source: source, archive: archive, notice: nil)
            }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func referencedNoticeMustBePresentAndReverifiedAgainstTheSameMetadata() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(notice: true)
        let archive = try GuidanceDownloads.preserve(payload, source: source, directory: root.appendingPathComponent("packages"))
        let data = try fixture("synthetic-voice-notice", ext: "xml")
        let notice = try GuidanceNoticeDownloads.preserve(data, source: source, directory: root.appendingPathComponent("notices"))
        #expect(throws: (any Error).self) {
            try GuidancePreflight.check(snapshot: snapshot(), discoveryAddress: address, source: source, archive: archive, notice: nil)
        }
        #expect(try GuidancePreflight.check(snapshot: snapshot(), discoveryAddress: address, source: source, archive: archive, notice: notice).battery == 90)
        var damaged = data; damaged[0] ^= 1; try damaged.write(to: notice.noticeURL)
        #expect(throws: (any Error).self) {
            try GuidancePreflight.check(snapshot: snapshot(), discoveryAddress: address, source: source, archive: archive, notice: notice)
        }
        #expect(try Data(contentsOf: notice.noticeURL) == damaged)
    }

    @Test func cancelledPreparationDoesNotChangePreservedFiles() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(), archive = try GuidanceDownloads.preserve(payload, source: source, directory: root)
        let snapshot = try snapshot()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try GuidancePreflight.check(snapshot: snapshot, discoveryAddress: address, source: source, archive: archive, notice: nil)
        }
        do { _ = try await task.value; Issue.record("Cancelled preparation must fail") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(try Data(contentsOf: archive.packageURL) == payload)
    }
}
