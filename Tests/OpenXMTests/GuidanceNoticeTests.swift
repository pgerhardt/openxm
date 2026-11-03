import Foundation
import Testing
@testable import OpenXM

struct GuidanceNoticeTests {
    // XM4 reference only. These rule inputs are synthetic and do not establish XM3 compatibility.
    private let request = GuidancePackageRequest(category: "HP002", service: "VGIDLPB0407", model: "WH-1000XM4",
        firmware: "2.5.0", serial: "9999912345678901234", language: .init(rawValue: 7))
    private func fixture(_ name: String, ext: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
    }
    private func source() throws -> GuidanceMetadataDownload {
        try GuidanceMetadataDownload(data: fixture("xm4-dutch-voice-info", ext: "enc"), request: request)
    }
    private func notice() throws -> Data { try fixture("xm4-dutch-voice-notice", ext: "xml") }
    private func xml(_ transform: (String) -> String) throws -> GuidancePackageMetadata {
        let data = try SonyMetadataEnvelope.decode(source().data, category: request.category, service: request.service)
        return try GuidancePackageMetadata.parseXML(Data(transform(String(decoding: data, as: UTF8.self)).utf8), for: request)
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test func actualXM4MetadataBindsTheNoticeAndPreparationTextToItsEligiblePackage() throws {
        let offer = try #require(source().metadata.offer)
        let ref = try #require(offer.notice)
        #expect(ref.id == "Disclaimer" && ref.version == "1" && ref.size == 2019)
        #expect(ref.sha1 == "2455d4c5cf8cf3488fa8b2a2ed36133d2aacf4d0")
        #expect(ref.url.absoluteString == "https://info.update.sony.net/HP002/VGIDLPB0407/contents/0002/disclaimer.xml")
        let instructions = try #require(offer.instructions)
        #expect(instructions.defaultLanguage == "English" && instructions.entries.count == 16)
        #expect(instructions.preferred?.text.contains("Do not insert audio cables or USB cables.") == true)
        #expect(instructions.entries.contains { $0.language == "Japanese" && $0.text.contains("オーディオ") })
        #expect(try xml { $0.replacingOccurrences(of: "Operator=\"GreaterThanEqual\"", with: "Operator=\"LessThan\"") }.offer == nil)
    }

    @Test func noticeReferencesRejectCrossServiceAmbiguityAndIncompleteInstructions() throws {
        let changes = [
            ("/VGIDLPB0407/contents/0002/disclaimer.xml", "/OTHER/contents/0002/disclaimer.xml"),
            ("Size=\"2019\"", "Size=\"1048577\""),
            ("2455d4c5cf8cf3488fa8b2a2ed36133d2aacf4d0", "not-a-digest"),
            ("InstallType=\"notice\"", "InstallType=\"unknown\""),
            ("DefaultLang=\"English\"", "DefaultLang=\"Missing\""),
            ("Lang=\"Japanese\"", "Lang=\"English\""),
            ("</Descriptions>", "<Unknown/></Descriptions>")
        ]
        for (old, new) in changes {
            #expect(throws: (any Error).self) { try xml { $0.replacingOccurrences(of: old, with: new) } }
        }
        #expect(throws: (any Error).self) {
            try xml { text in
                let start = text.range(of: "<Distribution ID=\"Disclaimer\"")!.lowerBound
                let end = text.range(of: "/>", range: start..<text.endIndex)!.upperBound
                return text.replacingOccurrences(of: "</Distributions>", with: String(text[start..<end]) + "</Distributions>")
            }
        }
    }

    @Test func originalNoticeParsesLeadingWhitespaceAndPreservesLocalizedTextVerbatim() throws {
        let data = try notice()
        #expect(data.count == 2019)
        let doc = try GuidanceNoticeDocument.parse(data)
        #expect(doc.defaultLocale == "UK" && doc.entries.count == 16)
        #expect(doc.preferred?.locale == "UK")
        #expect(doc.preferred?.text == "\nDisclaimer Contents for UK\nEnglish\n")
        #expect(doc.entries.first(where: { $0.locale == "Japan" })?.text.contains("日本語") == true)
        let markup = Data("<NoticeFile Version=\"1.0\" DefaultLocale=\"UK\"><Notice Locale=\"UK\"><Text><![CDATA[<script>text only</script> & literal]]></Text></Notice></NoticeFile>".utf8)
        #expect(try GuidanceNoticeDocument.parse(markup).preferred?.text == "<script>text only</script> & literal")
    }

    @Test func unknownOrMalformedNoticeDocumentsCannotBecomeDisplayedNotices() throws {
        let valid = "<NoticeFile Version=\"1.0\" DefaultLocale=\"UK\"><Notice Locale=\"UK\"><Text>Original text</Text></Notice></NoticeFile>"
        let invalid = [
            valid.replacingOccurrences(of: "Version=\"1.0\"", with: "Version=\"2.0\""),
            valid.replacingOccurrences(of: "DefaultLocale=\"UK\"", with: "DefaultLocale=\"Missing\""),
            valid.replacingOccurrences(of: "Original text", with: ""),
            valid.replacingOccurrences(of: "Original text", with: "<HTML>unhandled markup</HTML>"),
            valid.replacingOccurrences(of: "</Text>", with: "</Text><Text>duplicate</Text>"),
            valid.replacingOccurrences(of: "</NoticeFile>", with: "<Notice Locale=\"UK\"><Text>duplicate</Text></Notice></NoticeFile>"),
            valid.replacingOccurrences(of: "<Notice Locale", with: "hidden text<Notice Locale"),
            valid.replacingOccurrences(of: "Original text", with: String(repeating: "a", count: 65_537)),
            "<!DOCTYPE NoticeFile [<!ENTITY external SYSTEM 'file:///unread'>]>" + valid,
            String(valid.dropLast(4))
        ]
        for text in invalid { #expect(throws: (any Error).self) { try GuidanceNoticeDocument.parse(Data(text.utf8)) } }
        #expect(throws: (any Error).self) { try GuidanceNoticeDocument.parse(Data([0xFF, 0xFE])) }
    }

    @Test func noticeArchiveIsVerifiedImmutableAndKeepsOriginalBytesWithoutDeviceSerial() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(), data = try notice()
        var bad = data; bad[0] ^= 1
        for corrupt in [bad, data.dropLast(), data + Data([0])] {
            #expect(throws: (any Error).self) { try GuidanceNoticeDownloads.preserve(corrupt, source: source, directory: root) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let saved = try GuidanceNoticeDownloads.preserve(data, source: source, directory: root)
        #expect(try Data(contentsOf: saved.noticeURL) == data)
        #expect(try Data(contentsOf: saved.directory.appendingPathComponent("metadata.enc")) == source.data)
        let provenance = try String(contentsOf: saved.directory.appendingPathComponent("provenance.json"), encoding: .utf8)
        #expect(provenance.contains(saved.sha256) && provenance.contains("disclaimer.xml") && !provenance.contains(request.serial))
        #expect(try GuidanceNoticeDownloads.preserve(data, source: source, directory: root) == saved)
        try bad.write(to: saved.noticeURL)
        #expect(throws: (any Error).self) { try GuidanceNoticeDownloads.preserve(data, source: source, directory: root) }
        #expect(try Data(contentsOf: saved.noticeURL) == bad)
        #expect(try FileManager.default.contentsOfDirectory(atPath: saved.directory.deletingLastPathComponent().path).count == 1)
    }

    @Test func cancellationDoesNotPublishANoticeArchive() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try source(), data = try notice()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GuidanceNoticeDownloads.preserve(data, source: source, directory: root)
        }
        do { _ = try await task.value; Issue.record("Cancelled notice was published") }
        catch { #expect(error is CancellationError) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
