import Foundation
import Testing
@testable import OpenXM

struct FirmwareRegionalTests {
    private func identity(_ release: FirmwareRelease, battery: Int = 100) -> FirmwareIdentity {
        FirmwareIdentity(model: "WH-1000XM3", version: release.version, category: "HP001",
                         service: release.region.serviceID, battery: battery, charging: false)
    }
    private func journal(_ source: FirmwareRelease, _ target: FirmwareRelease) -> FirmwareJournal {
        FirmwareJournal(address: "AA:BB:CC:DD:EE:FF", sha256: target.sha256, sourceVersion: source.version,
                        targetVersion: target.version, started: Date(), sourceService: source.region.serviceID,
                        targetService: target.region.serviceID)
    }

    @Test func catalogContainsExactlyTheTenRequestedPackagesWithDistinctIdentities() {
        #expect(FirmwareRelease.allCases.count == 10)
        for (region, versions): (FirmwareRegion, [String]) in [
            (.international, ["2.0.0", "4.1.1", "4.2.2", "4.5.2"]),
            (.japan, ["4.1.1", "4.2.2", "4.5.2"]), (.china, ["4.1.3", "4.2.2", "4.5.2"])
        ] {
            #expect(FirmwareRelease.allCases.filter { $0.region == region }.map(\.version) == versions)
        }
        #expect(Set(FirmwareRelease.allCases.map(\.id)).count == 10)
        #expect(Set(FirmwareRelease.allCases.map(\.cacheFilename)).count == 10)
        #expect(Set(FirmwareRelease.allCases.map(\.sha256)).count == 10)
    }

    @Test func everyDistinctCatalogPairHasAnExplicitPlanAndRegionBoundResume() throws {
        for source in FirmwareRelease.allCases {
            for target in FirmwareRelease.allCases {
                if source == target {
                    #expect(throws: FirmwareError.self) { try FirmwareTransition.make(identity: identity(source), target: target) }
                    continue
                }
                let plan = try FirmwareInstallPlan.make(identity: identity(source), address: "AA:BB:CC:DD:EE:FF", release: target, journal: nil)
                #expect(plan.command == .install)
                #expect(plan.transition.source == source && plan.transition.target == target)
                #expect((identity(source).regionWarning(for: target.region) != nil) == (source.region != target.region))
                let saved = try JSONDecoder().decode(FirmwareJournal.self, from: JSONEncoder().encode(journal(source, target)))
                #expect(try saved.transition(for: target) == plan.transition)
                try plan.transition.checkIdentity(identity(target), resuming: true)
                try plan.transition.verifyInstalled(identity(target, battery: 0))
                #expect(!plan.transition.matchesSource(identity(target)))
                for wrong in FirmwareRelease.allCases where wrong != source && wrong != target {
                    #expect(throws: FirmwareError.self) { try plan.transition.checkIdentity(identity(wrong), resuming: true) }
                }
                for wrong in FirmwareRelease.allCases where wrong != target {
                    #expect(throws: FirmwareError.self) { try plan.transition.verifyInstalled(identity(wrong)) }
                    #expect(throws: FirmwareError.self) { try saved.transition(for: wrong) }
                }
            }
        }
    }

    @Test func sameVersionRegionChangeCannotMistakeTheSourceForCompletion() throws {
        let source = FirmwareRelease.xm3cn452, target = FirmwareRelease.xm3v452
        let transition = try FirmwareTransition.make(identity: identity(source), target: target)
        #expect(transition.title == "Change Region" && transition.changesRegion)
        #expect(transition.matchesSource(identity(source)))
        #expect(!transition.matchesSource(identity(target)))
        #expect(throws: FirmwareError.self) { try transition.verifyInstalled(identity(source)) }
        #expect(throws: FirmwareError.self) { try FirmwareCommand.upgrade.checkTransition(transition) }
        #expect(throws: FirmwareError.self) { try FirmwareCommand.downgrade.checkTransition(transition) }
        try FirmwareCommand.install.checkTransition(transition)
        var saved = journal(source, target)
        #expect(try FirmwareInstallPlan.make(identity: identity(target), address: saved.address, release: target, journal: saved) == .resume(transition))
        saved.phase = .complete
        #expect(throws: FirmwareError.self) { try FirmwareInstallPlan.make(identity: identity(source), address: saved.address, release: target, journal: saved) }
        #expect(try FirmwareInstallPlan.make(identity: identity(target, battery: 5), address: saved.address, release: target, journal: saved) == .verifyCompleted(transition))
    }

    @Test func corruptedAndPartiallyRegionalJournalsFailClosed() {
        let target = FirmwareRelease.xm3jp422
        for (sourceService, targetService): (String?, String?) in [
            (nil, nil), (nil, target.region.serviceID), ("MDRID291600", nil),
            ("MDRID291603", target.region.serviceID), ("MDRID291600", "MDRID291602")
        ] {
            var saved = journal(.xm3v411, target)
            saved.sourceService = sourceService; saved.targetService = targetService
            #expect(throws: FirmwareError.self) { try saved.transition(for: target) }
        }
    }

    @MainActor @Test func switchingRegionsKeepsTheVersionWhenAvailableOtherwiseChoosesLatest() {
        let controller = HeadphoneController()
        let workflow = controller.firmwareUpdate
        workflow.selectRelease(.xm3v411)
        workflow.selectRegion(.japan)
        #expect(workflow.selectedRelease == .xm3jp411)
        workflow.selectRegion(.china)
        #expect(workflow.selectedRelease == .xm3cn452)
        #expect(workflow.regionReleases.map(\.version) == ["4.1.3", "4.2.2", "4.5.2"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENXM_REGIONAL_FIRMWARE_FIXTURES"] != nil))
    func preservedRegionalBytesMatchCatalogAndTheirOwnMetadata() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["OPENXM_REGIONAL_FIRMWARE_FIXTURES"]))
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any])
        let entries = try #require(manifest["firmware"] as? [[String: Any]])
        #expect(entries.count == 6)
        for entry in entries {
            let file = try #require(entry["file"] as? String)
            let bytes = try Data(contentsOf: directory.appendingPathComponent(file))
            let image = try FirmwareImage(data: bytes)
            #expect(image.version == entry["version"] as? String)
            #expect(image.serviceID == entry["service_id"] as? String)
            #expect(image.sha256 == entry["sha256"] as? String)
            #expect(image.release.size == entry["size_bytes"] as? Int)
            #expect(image.release.downloadURL.absoluteString == entry["source_url"] as? String)
            var corrupt = bytes; corrupt[corrupt.count / 2] ^= 1
            #expect(throws: FirmwareError.self) { try FirmwareImage(data: corrupt) }
        }
        for region in [FirmwareRegion.japan, .china] {
            let metadata = try FirmwareMetadata.decode(Data(contentsOf: directory.appendingPathComponent("metadata/\(region.serviceID)/info.encrypted.xml")), region: region)
            #expect(metadata.region == region)
            #expect(metadata.offers.contains { $0.pinnedRelease == FirmwareRelease(version: "4.5.2", region: region) })
            let xml = try Data(contentsOf: directory.appendingPathComponent("metadata/\(region.serviceID)/info.decoded.xml"))
            #expect(throws: FirmwareError.self) { try FirmwareMetadata.parseXML(xml, region: .international) }
        }
    }
}
