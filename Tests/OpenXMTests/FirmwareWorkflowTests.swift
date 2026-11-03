import Foundation
import Testing
@testable import OpenXM

struct FirmwareCatalogTests {
    private func fixture(_ ext: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: "xm3-info", withExtension: ext, subdirectory: "Fixtures")))
    }

    @Test func independentlyEncryptedMetadataMatchesThePinnedPackage() throws {
        let result = try FirmwareMetadata.decode(fixture("enc"))
        #expect(result.offers.count == 1)
        let offer = try #require(result.offers.first)
        #expect(offer.sourceVersion == "2.0.0" && offer.targetVersion == "4.5.2")
        #expect(offer.pinnedRelease == .xm3v452)
        #expect(offer.url.scheme == "https")
        #expect(result.lastUpdate == "2020-04-23T04:26:20Z")
        #expect(try FirmwareMetadata.parseXML(fixture("xml")) == result)
    }

    @Test func envelopeIntegrityAndFormatAreMandatory() throws {
        let good = try fixture("enc")
        var damaged = good; damaged[damaged.count - 8] ^= 1
        #expect(throws: (any Error).self) { try FirmwareMetadata.decode(damaged) }
        #expect(throws: (any Error).self) { try FirmwareMetadata.decode(good.dropLast()) }
        var format = good; format[11] = Character("2").asciiValue!
        #expect(throws: (any Error).self) { try FirmwareMetadata.decode(format) }
        #expect(throws: (any Error).self) { try FirmwareMetadata.decode(Data(repeating: 0, count: 1_048_577)) }
        #expect(throws: (any Error).self) { try FirmwareMetadata.decode(fixture("xml")) }
    }

    @Test func metadataCannotChangeRegionDeviceOrServicePolicy() throws {
        let xml = String(decoding: try fixture("xml"), as: UTF8.self)
        for (old, new) in [
            ("MDRID291600", "MDRID291601"), ("MDRID291600", "MDRID291602"),
            ("WH-1000XM3", "WF-1000XM3"), ("DefaultServiceStatus=\"open\"", "DefaultServiceStatus=\"closed\""),
            ("Noop=\"false\"", "Noop=\"true\""), ("DefaultVariance=\"0\"", "DefaultVariance=\"50\""),
            ("Operator=\"Equal\"", "Operator=\"NotEqual\""), ("info.update.sony.net", "example.com"),
            ("<ControlConditions DefaultServiceStatus=\"open\" DefaultVariance=\"0\"/>", "")
        ] {
            #expect(throws: (any Error).self) { try FirmwareMetadata.parseXML(Data(xml.replacingOccurrences(of: old, with: new).utf8)) }
        }
        let entity = "<!DOCTYPE InformationFile [<!ENTITY external SYSTEM 'file:///tmp/private'>]>" + xml
        #expect(throws: (any Error).self) { try FirmwareMetadata.parseXML(Data(entity.utf8)) }
        let unknownHash = xml.replacingOccurrences(of: FirmwareRelease.xm3v452.sha1, with: String(repeating: "0", count: 40))
        #expect(try FirmwareMetadata.parseXML(Data(unknownHash.utf8)).offers.first?.pinnedRelease == nil)
    }

    @Test func downloadPolicyRejectsDowngradedTransportAndForeignHosts() {
        #expect(FirmwareNetworkPolicy.allowed(FirmwareRelease.xm3v200.downloadURL))
        #expect(FirmwareNetworkPolicy.allowed(FirmwareRelease.xm3v452.downloadURL))
        for url in ["http://info.update.sony.net/file", "https://info.update.sony.net.example.com/file",
                    "https://user:password@info.update.sony.net/file", "file:///tmp/firmware.bin",
                    "https://raw.githubusercontent.com:444/file"] {
            #expect(!FirmwareNetworkPolicy.allowed(URL(string: url)!))
        }
    }

    @Test func invalidCachedPackageIsPreservedWithoutDownloading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WH-1000XM3-international-4.5.2.bin")
        let original = Data([1, 2, 3])
        try original.write(to: url)
        do {
            _ = try await FirmwareDownloads.package(.xm3v452, directory: directory, progress: { _, _ in Issue.record("Must not download over an invalid cached file") })
            Issue.record("Invalid cached firmware must be rejected")
        } catch {}
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENXM_METADATA_FIXTURE"] != nil))
    func actualSonyEnvelopeStillListsTheKnownUpgrade() throws {
        let path = try #require(ProcessInfo.processInfo.environment["OPENXM_METADATA_FIXTURE"])
        let result = try FirmwareMetadata.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(result.offers.contains { $0.sourceVersion == "1.0.8" && $0.pinnedRelease == .xm3v452 })
        #expect(result.offers.contains { $0.sourceVersion == "2.0.0" && $0.pinnedRelease == .xm3v452 })
    }
}

struct FirmwareWorkflowTests {
    private func identity(_ version: String, service: String = "MDRID291600", battery: Int = 100) -> FirmwareIdentity {
        FirmwareIdentity(model: "WH-1000XM3", version: version, category: "HP001", service: service, battery: battery, charging: false)
    }

    @Test func installationAndResumePlansRemainBoundToTheExactDeviceAndImage() throws {
        let address = "AA:BB:CC:DD:EE:FF"
        #expect(try FirmwareInstallPlan.make(identity: identity("2.0.0"), address: address, release: .xm3v452, journal: nil) == .install(.upgrade))
        #expect(try FirmwareInstallPlan.make(identity: identity("4.5.2"), address: address, release: .xm3v200, journal: nil) == .install(.downgrade))
        #expect(throws: (any Error).self) { try FirmwareInstallPlan.make(identity: identity("4.5.2"), address: address, release: .xm3v452, journal: nil) }
        for service in ["MDRID291601", "MDRID291602"] {
            #expect(throws: (any Error).self) { try FirmwareInstallPlan.make(identity: identity("2.0.0", service: service), address: address, release: .xm3v452, journal: nil) }
        }
        #expect(try FirmwareInstallPlan.make(identity: identity("2.0.0", battery: 50), address: address, release: .xm3v452, journal: nil) == .install(.upgrade))
        #expect(throws: (any Error).self) { try FirmwareInstallPlan.make(identity: identity("2.0.0", battery: 49), address: address, release: .xm3v452, journal: nil) }
        var journal = FirmwareJournal(address: "aa-bb-cc-dd-ee-ff", sha256: FirmwareRelease.xm3v452.sha256,
            sourceVersion: "2.0.0", targetVersion: "4.5.2", started: Date(), phase: .transferring)
        #expect(try FirmwareInstallPlan.make(identity: identity("2.0.0"), address: address, release: .xm3v452, journal: journal) == .resume(.upgrade))
        #expect(throws: (any Error).self) { try FirmwareInstallPlan.make(identity: identity("2.0.0", battery: 49), address: address, release: .xm3v452, journal: journal) }
        #expect(throws: (any Error).self) { try FirmwareInstallPlan.make(identity: identity("2.0.0"), address: "00:00:00:00:00:00", release: .xm3v452, journal: journal) }
        #expect(throws: (any Error).self) { try FirmwareInstallPlan.make(identity: identity("2.0.0"), address: address, release: .xm3v200, journal: journal) }
        journal.phase = .complete
        let completed = try FirmwareInstallPlan.make(identity: identity("4.5.2", battery: 10), address: address, release: .xm3v452, journal: journal)
        #expect(completed == .verifyCompleted(.upgrade) && completed.command == .resume)
        #expect(throws: (any Error).self) { try FirmwareInstallPlan.make(identity: identity("2.0.0"), address: address, release: .xm3v452, journal: journal) }
    }

    @Test func kernelLockRejectsConcurrentOwnersAndDoesNotTrustFilePresence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("old process state".utf8).write(to: url)
        do {
            let owner = try FirmwareAccessLock(url: url)
            #expect(throws: (any Error).self) { try FirmwareAccessLock(url: url) }
            withExtendedLifetime(owner) {}
        }
        let next = try FirmwareAccessLock(url: url)
        withExtendedLifetime(next) {}
    }

    @Test func unreadableOrUnsupportedJournalsAreNeverTreatedAsAbsent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        #expect(try FirmwareJournalStore.read(from: url) == nil)
        let invalid = Data("invalid journal".utf8)
        try invalid.write(to: url)
        #expect(throws: (any Error).self) { try FirmwareJournalStore.read(from: url) }
        #expect(try Data(contentsOf: url) == invalid)
        let journal = FirmwareJournal(address: "AA:BB:CC:DD:EE:FF", sha256: FirmwareRelease.xm3v200.sha256,
            sourceVersion: "4.5.2", targetVersion: "2.0.0", started: Date(), phase: .rebooting)
        try FirmwareJournalStore.save(journal, to: url)
        #expect(try FirmwareJournalStore.read(from: url)?.phase == .rebooting)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @MainActor @Test func previewCannotClaimFirmwareControl() async {
        let controller = HeadphoneController()
        controller.startDemo()
        do { try await controller.beginFirmwareAccess(); Issue.record("Preview cannot access firmware") } catch {}
        #expect(!controller.firmwareOperationInProgress && !controller.firmwareUpdate.canReadDevice)
        #expect(controller.firmwareUpdate.installPlan == nil)
    }

    @Test func identityAutomaticallyRefreshesOncePerConnectionAndDefersWhileBusy() {
        var refresh = FirmwareIdentityRefreshState()
        let first = FirmwareIdentityRefreshState.Connection(address: "first", generation: 1)
        #expect(refresh.shouldRead(.init(connection: nil, canRead: true)) == false)
        #expect(refresh.shouldRead(.init(connection: first, canRead: false)) == false)
        #expect(refresh.shouldRead(.init(connection: first, canRead: true)) == true)
        // Beginning/ending the read toggles readiness; a failure must not cause a retry loop.
        #expect(refresh.shouldRead(.init(connection: first, canRead: false)) == false)
        #expect(refresh.shouldRead(.init(connection: first, canRead: true)) == false)
        // Reconnecting, switching headphones, and disconnecting invalidate the previous read.
        let reconnect = FirmwareIdentityRefreshState.Connection(address: "first", generation: 2)
        #expect(refresh.shouldRead(.init(connection: reconnect, canRead: true)) == true)
        let other = FirmwareIdentityRefreshState.Connection(address: "second", generation: 2)
        #expect(refresh.shouldRead(.init(connection: other, canRead: true)) == true)
        #expect(refresh.shouldRead(.init(connection: nil, canRead: false)) == false)
        #expect(refresh.connection == nil)
        #expect(refresh.shouldRead(.init(connection: other, canRead: true)) == true)
    }
}
