import Foundation
import Testing
@testable import OpenXM

struct GuidancePackageTests {
    private let request = GuidancePackageRequest(category: "TEST_CATEGORY", service: "TEST_EN_SERVICE",
        model: "WH-1000XM3", firmware: "2.0.0", serial: "0123456", language: .init(rawValue: 1))
    private let payload = Data("SYNTHETIC VOICE PACKAGE TEST DATA\n".utf8)
    private func fixture(_ name: String, _ ext: String = "enc") throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
    }
    private func source() throws -> GuidanceMetadataDownload {
        try GuidanceMetadataDownload(data: fixture("synthetic-voice-info"), request: request)
    }
    private func xml(_ transform: (String) -> String = { $0 }) throws -> GuidancePackageMetadata {
        let text = try #require(String(data: fixture("synthetic-voice-info", "xml"), encoding: .utf8))
        return try GuidancePackageMetadata.parseXML(Data(transform(text).utf8), for: request)
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test @MainActor func discoveryRequiresFreshModelRegionAndExactAdvertisedLanguageService() throws {
        let state = DeviceState()
        state.family = .v1; state.modelName = "WH-1000XM3"; state.firmware = "2.0.0"
        state.capabilities.voiceGuidanceCapability = .init(supportsOnOff: true, supportsLanguage: true, languages: [.init(rawValue: 1)])
        state.voiceGuidanceDetails.downloadService = .init(categoryID: request.category, serialNumber: request.serial,
            entries: [.init(language: request.language, serviceID: request.service)])
        func make(_ service: String = "MDRID291600", language: GuidanceLanguage = .init(rawValue: 1)) throws -> GuidancePackageRequest {
            try GuidancePackageRequest.make(state: state, firmwareCategory: "HP001", firmwareService: service, language: language)
        }
        #expect(try make() == request)
        for region in ["MDRID291601", "MDRID291602", ""] { #expect(throws: (any Error).self) { try make(region) } }
        #expect(throws: (any Error).self) { try make(language: .init(rawValue: 11)) }
        state.modelName = "WF-1000XM3"
        #expect(throws: (any Error).self) { try make() }
        state.modelName = "WH-1000XM3"; state.firmware = nil
        #expect(throws: (any Error).self) { try make() }
        state.firmware = "2.0.0"; state.voiceGuidanceDetails.downloadService = nil
        #expect(throws: (any Error).self) { try make() }
        state.voiceGuidanceDetails.downloadService = .init(categoryID: "HP001", serialNumber: request.serial,
            entries: [.init(language: request.language, serviceID: "MDRID291600")])
        #expect(throws: (any Error).self) { try make() }
        state.reset()
        #expect(throws: (any Error).self) { try make() }
    }

    @Test func realXM4MetadataDecodesOnlyInItsOwnServiceContextAndNeverAsXM3Firmware() throws {
        // A real Sony XM4 reference response, not an XM3 package or an XM3 service mapping.
        let data = try fixture("xm4-dutch-voice-info")
        let xm4 = GuidancePackageRequest(category: "HP002", service: "VGIDLPB0407", model: "WH-1000XM4",
                                        firmware: "2.5.0", serial: "0", language: .init(rawValue: 7))
        let decoded = try GuidancePackageMetadata.decode(data, for: xm4)
        let offer = try #require(decoded.offer)
        #expect(decoded.lastUpdate == "2020-03-19T11:49:22Z")
        #expect(offer.version == "3" && offer.size == 890144)
        #expect(offer.sha1 == "24803d3e57c9b1e730b3347e12554181acd4acb8")
        #expect(offer.url.absoluteString == "https://info.update.sony.net/HP002/VGIDLPB0407/contents/0002/VP_dutch_UPG_03.bin")
        #expect(throws: (any Error).self) { try GuidancePackageMetadata.decode(data, for: request) }
        #expect(throws: (any Error).self) { try FirmwareMetadata.decode(data) }
        var damaged = data; damaged[damaged.count - 10] ^= 1
        #expect(throws: (any Error).self) { try GuidancePackageMetadata.decode(damaged, for: xm4) }
        #expect(throws: (any Error).self) { try GuidancePackageMetadata.decode(data.dropLast(), for: xm4) }
    }

    @Test func eligibilityUsesEveryKnownRuleAndDoesNotGuessUnknownRules() throws {
        #expect(try source().metadata == xml())
        #expect(try xml { $0.replacingOccurrences(of: "WH-1000XM3", with: "WH-1000XM4") }.offer == nil)
        #expect(try xml { $0.replacingOccurrences(of: "2.0.0", with: "2.0.1") }.offer == nil)
        #expect(try xml { $0.replacingOccurrences(of: "Key=\"SerialNo\"", with: "Key=\"UnknownKey\"") }.offer == nil)
        #expect(try xml { $0.replacingOccurrences(of: "GreaterThanEqual", with: "UnknownOperator") }.offer == nil)
        #expect(try xml { $0.replacingOccurrences(of: "Type=\"System\"", with: "Type=\"Unknown\"") }.offer == nil)
        func rule(_ key: String, _ value: String, _ op: String) -> Bool {
            GuidanceRule.matches(["Type": "System", "Key": key, "Value": value, "Operator": op], request: request)
        }
        #expect(rule("FirmwareVersion", "2.0", "Equal"))
        #expect(rule("FirmwareVersion", "1.10.99", "GreaterThan"))
        #expect(rule("FirmwareVersion", "2.0.0.1", "LessThan"))
        #expect(!rule("FirmwareVersion", "2..0", "NotEqual"))
        #expect(!rule("FirmwareVersion", "2.0-beta", "NotEqual"))
        #expect(rule("SerialNo", "123456", "GreaterThanEqual"))
        #expect(rule("SerialNo", "99999999999999999999999999", "LessThan"))
        #expect(!rule("SerialNo", "any", "LessThan"))
    }

    @Test func ambiguousOrUnrecognizedMetadataNeverSelectsAnAsset() throws {
        let alterations: [(String, String)] = [
            ("DefaultServiceStatus=\"open\"", "DefaultServiceStatus=\"closed\""),
            ("DefaultVariance=\"0\"", "DefaultVariance=\"10\""),
            ("Noop=\"false\"", "Noop=\"true\""),
            ("<Rules>", "<OtherRule/><Rules>"),
            ("<Rules>", "<Rules><OtherRule/>"),
            ("<Distributions>", "<Distributions><OtherDistribution/>"),
            ("InstallParams=\"\"", "InstallParams=\"unknown=1\""),
            ("Size=\"34\"", "Size=\"32000001\""),
            ("Size=\"34\"", "Size=\"0\""),
            ("MAC=\"", "MAC=\"G"),
            ("<ApplyConditions>", "<ApplyConditions><Unexpected/>"),
            ("<ApplyConditions>", "<ApplyConditions/><ApplyConditions>"),
            ("</InformationFile>", "<UnknownConditions/></InformationFile>")
        ]
        for (old, new) in alterations {
            #expect(throws: (any Error).self) { try xml { $0.replacingOccurrences(of: old, with: new) } }
        }
        #expect(throws: (any Error).self) {
            try xml { text in
                let start = text.range(of: "<ApplyCondition ApplyOrder")!.lowerBound
                let end = text.range(of: "</ApplyCondition>")!.upperBound
                return text.replacingOccurrences(of: "</ApplyConditions>", with: String(text[start..<end]) + "</ApplyConditions>")
            }
        }
        #expect(throws: (any Error).self) { try xml { $0.replacingOccurrences(of: "<InformationFile", with: "<!DOCTYPE InformationFile><InformationFile") } }
    }

    @Test func packageAndRedirectURLsStayWithinExactSonyService() throws {
        let policy = FirmwareNetworkPolicy(scope: { request.permits($0) })
        #expect(policy.allows(request.metadataURL))
        #expect(policy.allows(try #require(source().metadata.offer).url))
        let denied = [
            "https://info.update.sony.net/OTHER/TEST_EN_SERVICE/contents/1/file.bin",
            "https://info.update.sony.net/TEST_CATEGORY/OTHER/contents/1/file.bin",
            "https://info.update.sony.net/TEST_CATEGORY/TEST_EN_SERVICE/contents/",
            "https://info.update.sony.net/TEST_CATEGORY/TEST_EN_SERVICE/contents/../file.bin",
            "https://info.update.sony.net/TEST_CATEGORY/TEST_EN_SERVICE/contents/%2e%2e/file.bin",
            "https://info.update.sony.net/TEST_CATEGORY/TEST_EN_SERVICE/contents/1/file.bin?token=1",
            "https://info.update.sony.net:443/TEST_CATEGORY/TEST_EN_SERVICE/contents/1/file.bin",
            "https://user@info.update.sony.net/TEST_CATEGORY/TEST_EN_SERVICE/contents/1/file.bin",
            "http://info.update.sony.net/TEST_CATEGORY/TEST_EN_SERVICE/contents/1/file.bin",
            "https://raw.githubusercontent.com/a/b/main/file.bin"
        ]
        for text in denied { #expect(!policy.allows(try #require(URL(string: text)))) }
        #expect(try xml { $0.replacingOccurrences(of: "https://", with: "http://") }.offer?.url.scheme == "https")
        #expect(throws: (any Error).self) { try xml { $0.replacingOccurrences(of: "/TEST_EN_SERVICE/contents/", with: "/OTHER/contents/") } }
    }

    @Test func verifiedArchiveRetainsOriginalBytesHashesAndProvenanceWithoutDeviceSerial() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source()
        let saved = try GuidanceDownloads.preserve(payload, source: source, directory: root)
        #expect(saved.size == 34 && saved.sha256 == "db038b0409729c6ef36e81a262703bfc57c98fc8eff1a5a89a2c9bf5733836f1")
        #expect(try Data(contentsOf: saved.packageURL) == payload)
        #expect(try Data(contentsOf: saved.directory.appendingPathComponent("metadata.enc")) == source.data)
        let text = try String(contentsOf: saved.directory.appendingPathComponent("provenance.json"), encoding: .utf8)
        #expect(text.contains(saved.sha256) && text.contains(request.service) && !text.contains(request.serial))
        #expect(try GuidanceDownloads.preserve(payload, source: source, directory: root) == saved)
        #expect(throws: (any Error).self) { try FirmwareImage(data: payload) }
        let updatedRequest = GuidancePackageRequest(category: request.category, service: request.service, model: request.model,
            firmware: "4.5.2", serial: request.serial, language: request.language)
        let updated = try GuidanceMetadataDownload(data: source.data, request: updatedRequest)
        let newRecord = try GuidanceDownloads.preserve(payload, source: updated, directory: root)
        #expect(newRecord.directory != saved.directory)
    }

    @Test func corruptPackagesAndExistingArchivesAreNeverPublishedOrOverwritten() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source()
        var bad = payload; bad[0] ^= 1
        for data in [bad, payload.dropLast(), payload + Data([0])] {
            #expect(throws: (any Error).self) { try GuidanceDownloads.preserve(data, source: source, directory: root) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let saved = try GuidanceDownloads.preserve(payload, source: source, directory: root)
        try bad.write(to: saved.packageURL)
        #expect(throws: (any Error).self) { try GuidanceDownloads.preserve(payload, source: source, directory: root) }
        #expect(try Data(contentsOf: saved.packageURL) == bad)
        #expect(try FileManager.default.contentsOfDirectory(atPath: saved.directory.deletingLastPathComponent().path).count == 1)
    }

    @Test func cancellationCannotPublishAnArchive() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GuidanceDownloads.preserve(payload, source: source, directory: root)
        }
        do { _ = try await task.value; Issue.record("Cancelled preservation succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENXM_VOICE_REFERENCE_ARCHIVE"] != nil))
    func optInLiveSonyXM4ReferenceDownload() async throws {
        // Explicit network integration check of an independently known XM4 service. This bypasses the
        // XM3-only production factory solely to test the generic downloader, and never accesses Bluetooth.
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["OPENXM_VOICE_REFERENCE_ARCHIVE"]), isDirectory: true)
        let xm4 = GuidancePackageRequest(category: "HP002", service: "VGIDLPB0407", model: "WH-1000XM4",
                                        firmware: "2.5.0", serial: "0", language: .init(rawValue: 7))
        let source = try await GuidanceDownloads.metadata(for: xm4)
        #expect(source.data == (try fixture("xm4-dutch-voice-info")))
        let archive = try await GuidanceDownloads.package(source, directory: root) { _, _ in }
        let notice = try #require(await GuidanceNoticeDownloads.notice(source, directory: root.appendingPathComponent("notices")))
        #expect(try Data(contentsOf: notice.noticeURL) == fixture("xm4-dutch-voice-notice", "xml"))
        #expect(notice.document.entries.count == 16)
        #expect(archive.size == 890144)
        #expect(try GuidanceDownloads.verify(Data(contentsOf: archive.packageURL), source: source) == archive.sha256)
        let saved = try GuidancePackageBackup(assets: .init(source: source, archive: archive, notice: notice))
        #expect(saved.package.sha256 == "ebe87b6b6e6373b90addca54d6482f8f20be1cd8c4926d071b6b502dee86cfcb")
        #expect(saved.notice?.sha256 == "6b01feb499136d42d2459f5e9cc7268f75c8a72be51972fe64056cf9a18179b9")
        let importedRoot = try temporary(); defer { try? FileManager.default.removeItem(at: importedRoot) }
        let restored = try GuidancePackageBackup.decode(saved.encoded()).restore(for: xm4, directory: importedRoot)
        #expect(restored.bytes == Array(saved.package.data) && restored.source.data == source.data)
        #expect(restored.notice?.document == notice.document)
        #expect(throws: (any Error).self) { try saved.restore(for: request, directory: importedRoot) }
        print("XM4 reference only: \(archive.size) bytes, SHA-256 \(archive.sha256)")
    }
}
