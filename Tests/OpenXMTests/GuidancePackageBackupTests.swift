import Foundation
import Testing
@testable import OpenXM

struct GuidancePackageBackupTests {
    private let request = GuidancePackageRequest(category: "TEST_CATEGORY", service: "TEST_EN_SERVICE",
        model: "WH-1000XM3", firmware: "2.0.0", serial: "0123456", language: .init(rawValue: 1))
    private let payload = Data("SYNTHETIC VOICE PACKAGE TEST DATA\n".utf8)

    private func fixture(notice: Bool = true) throws -> (URL, GuidanceInstallationAssets) {
        func data(_ name: String, _ ext: String) throws -> Data {
            try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = try GuidanceMetadataDownload(data: data(notice ? "synthetic-voice-notice-info" : "synthetic-voice-info", "enc"), request: request)
        let archive = try GuidanceDownloads.preserve(payload, source: source, directory: root.appendingPathComponent("source"))
        let savedNotice = notice ? try GuidanceNoticeDownloads.preserve(data("synthetic-voice-notice", "xml"), source: source,
            directory: root.appendingPathComponent("source-notices")) : nil
        return (root, try .init(source: source, archive: archive, notice: savedNotice))
    }

    private func changed(_ saved: GuidancePackageBackup, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: saved.encoded()) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func portableBackupRetainsOriginalBytesAndProvenanceWithoutDeviceOrSessionFields() throws {
        let (root, assets) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try GuidancePackageBackup(assets: assets)
        let encoded = try saved.encoded()
        #expect(try GuidancePackageBackup.decode(encoded) == saved)
        #expect(saved.package.data == payload && saved.metadata.data == assets.source.data)
        #expect(saved.packageProvenance.data == (try Data(contentsOf: assets.archive.directory.appendingPathComponent("provenance.json"))))
        #expect(saved.notice?.data == (try Data(contentsOf: #require(assets.notice?.noticeURL))))
        #expect(saved.noticeProvenance?.data == (try Data(contentsOf: #require(assets.notice?.directory).appendingPathComponent("provenance.json"))))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let context = try #require(object["context"] as? [String: Any])
        #expect(Set(context.keys) == ["model", "firmwareAtDiscovery", "category", "service", "packageVersion", "language"])
        #expect(object["journal"] == nil && !String(decoding: encoded, as: UTF8.self).contains(root.path))
        let imports = root.appendingPathComponent("imports")
        let restored = try saved.restore(for: request, directory: imports)
        #expect(restored.bytes == Array(payload) && restored.source.data == assets.source.data)
        #expect(restored.notice?.document == assets.notice?.document)
        #expect(restored.archive.sha256 == assets.archive.sha256 && restored.notice?.sha256 == assets.notice?.sha256)
        let published = try #require(FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: published.appendingPathComponent("original-backup.json")) == encoded)
        #expect(try saved.restore(for: request, directory: imports).archive == restored.archive)
    }

    @Test func currentFirmwareAndSerialMustSatisfyOriginalRulesAndOldProvenanceStaysIntact() throws {
        let (root, assets) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try GuidancePackageBackup(assets: assets)
        func target(model: String = "WH-1000XM3", category: String = "TEST_CATEGORY", service: String = "TEST_EN_SERVICE",
                    firmware: String = "2.0.0", serial: String = "0123456", language: UInt8 = 1) -> GuidancePackageRequest {
            .init(category: category, service: service, model: model, firmware: firmware, serial: serial, language: .init(rawValue: language))
        }
        let rejected = root.appendingPathComponent("rejected")
        for request in [target(model: "WF-1000XM3"), target(category: "OTHER"), target(service: "MDRID291601"),
                        target(service: "MDRID291602"), target(language: 11), target(firmware: "1.0.8"), target(serial: "not-a-number")] {
            #expect(throws: (any Error).self) { try saved.restore(for: request, directory: rejected) }
            #expect(!FileManager.default.fileExists(atPath: rejected.path))
        }
        let current = target(firmware: "4.5.2", serial: "999")
        let restored = try saved.restore(for: current, directory: root.appendingPathComponent("eligible"))
        #expect(restored.source.request == current && restored.bytes == Array(payload))
        #expect(saved.context.firmwareAtDiscovery == "2.0.0")
        let provenance = try Data(contentsOf: restored.archive.directory.appendingPathComponent("provenance.json"))
        #expect(String(decoding: provenance, as: UTF8.self).contains("4.5.2"))
        #expect(saved.packageProvenance.data == (try Data(contentsOf: assets.archive.directory.appendingPathComponent("provenance.json"))))
    }

    @Test func selfConsistentChangedPackageOrNoticeCannotOverrideSonyMetadata() throws {
        let (root, assets) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try GuidancePackageBackup(assets: assets)
        for name in ["package", "notice"] {
            let data = try changed(saved) { object in
                var file = object[name] as! [String: Any]
                var bytes = Data(base64Encoded: file["data"] as! String)!
                bytes[0] ^= 1
                file["data"] = bytes.base64EncodedString()
                file["sha256"] = GuidanceDownloads.sha256(bytes)
                object[name] = file
            }
            let forged = try GuidancePackageBackup.decode(data) // Internal hashes alone are insufficient.
            let destination = root.appendingPathComponent(name)
            #expect(throws: (any Error).self) { try forged.restore(for: request, directory: destination) }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        let mislabeled = try GuidancePackageBackup.decode(changed(saved) { object in
            var context = object["context"] as! [String: Any]; context["packageVersion"] = "99"; object["context"] = context
        })
        #expect(throws: (any Error).self) { try mislabeled.restore(for: request, directory: root.appendingPathComponent("wrong-version")) }
    }

    @Test func requiredAndUnreferencedNoticesAreRejectedBeforePublishingAnyArchive() throws {
        let (root, assets) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try GuidancePackageBackup(assets: assets)
        let missing = try GuidancePackageBackup.decode(changed(saved) { $0.removeValue(forKey: "notice"); $0.removeValue(forKey: "noticeProvenance") })
        let destination = root.appendingPathComponent("rejected")
        #expect(throws: (any Error).self) { try missing.restore(for: request, directory: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let (otherRoot, noNoticeAssets) = try fixture(notice: false); defer { try? FileManager.default.removeItem(at: otherRoot) }
        let noNotice = try GuidancePackageBackup(assets: noNoticeAssets)
        #expect(try noNotice.restore(for: request, directory: otherRoot.appendingPathComponent("accepted")).notice == nil)
        let original = try #require(JSONSerialization.jsonObject(with: saved.encoded()) as? [String: Any])
        let extra = try GuidancePackageBackup.decode(changed(noNotice) { $0["notice"] = original["notice"]; $0["noticeProvenance"] = original["noticeProvenance"] })
        #expect(throws: (any Error).self) { try extra.restore(for: request, directory: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func malformedBackupsAndOversizedOrSymlinkedFilesFailOfflineValidation() throws {
        let (root, assets) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try GuidancePackageBackup(assets: assets)
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 2 }, { $0["format"] = "OpenXM settings" }, { $0.removeValue(forKey: "noticeProvenance") },
            { var c = $0["context"] as! [String: Any]; c["service"] = "../escape"; $0["context"] = c },
            { var c = $0["context"] as! [String: Any]; c["language"] = 0xFE; $0["context"] = c },
            { var f = $0["package"] as! [String: Any]; f["sha256"] = String(repeating: "0", count: 64); $0["package"] = f },
            { var f = $0["metadata"] as! [String: Any]; f["data"] = Data("bad envelope".utf8).base64EncodedString(); f["sha256"] = GuidanceDownloads.sha256(Data("bad envelope".utf8)); $0["metadata"] = f }
        ]
        for change in changes { #expect(throws: (any Error).self) { try GuidancePackageBackup.decode(changed(saved, change)) } }
        let file = root.appendingPathComponent("backup.json"); try saved.encoded().write(to: file)
        let link = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try GuidancePackageBackup.read(link) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(GuidancePackageBackup.encodedLimit + 1)); try handle.close()
        #expect(throws: (any Error).self) { try GuidancePackageBackup.read(file) }
    }

    @Test func exportRevalidatesFilesAndImportNeverOverwritesCorruptPublishedData() throws {
        for changedFile in ["package.bin", "provenance.json", "notice.xml"] {
            let (root, assets) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let saved = try GuidancePackageBackup(assets: assets)
            let restored = try saved.restore(for: request, directory: root.appendingPathComponent("imports"))
            let target = changedFile == "notice.xml" ? try #require(restored.notice?.noticeURL) : restored.archive.directory.appendingPathComponent(changedFile)
            let damaged = Data("changed after import".utf8); try damaged.write(to: target)
            #expect(throws: (any Error).self) { try saved.restore(for: request, directory: root.appendingPathComponent("imports")) }
            #expect(try Data(contentsOf: target) == damaged)
            let original = changedFile == "notice.xml" ? try #require(assets.notice?.noticeURL) : assets.archive.directory.appendingPathComponent(changedFile)
            try damaged.write(to: original)
            #expect(throws: (any Error).self) { try GuidancePackageBackup(assets: assets) }
            #expect(try Data(contentsOf: original) == damaged)
        }
        let (root, assets) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try GuidancePackageBackup(assets: assets)
        let imports = root.appendingPathComponent("imports")
        let restored = try saved.restore(for: request, directory: imports)
        let published = try #require(FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil).first)
        let original = published.appendingPathComponent("original-backup.json")
        let damaged = Data("changed original backup".utf8); try damaged.write(to: original)
        #expect(throws: (any Error).self) { try saved.restore(for: request, directory: imports) }
        #expect(try Data(contentsOf: original) == damaged && Data(contentsOf: restored.archive.packageURL) == payload)
    }

    @Test func cancelledImportDoesNotPublishFiles() async throws {
        let (root, assets) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try GuidancePackageBackup(assets: assets)
        let destination = root.appendingPathComponent("cancelled")
        let job = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try saved.restore(for: request, directory: destination)
        }
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
