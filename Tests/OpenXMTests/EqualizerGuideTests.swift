import Foundation
import Testing
@testable import OpenXM

@MainActor struct EqualizerGuideTests {
    let address = "AA:BB:CC:DD:EE:FF"

    @Test func everyListeningPathHasFiveDistinctValidChoices() throws {
        let driver = BankTestDriver()
        let cap = try #require(driver.state.capabilities.equalizer)
        let balances = EqualizerGuideRound.balance.choices(around: nil)
        #expect(balances.count == 5)
        for balance in balances {
            let basses = EqualizerGuideRound.bass.choices(around: balance)
            #expect(basses.count == 5 && Set(basses.map(\.bass)).count == 5)
            for bass in basses {
                let details = EqualizerGuideRound.detail.choices(around: bass)
                #expect(details.count == 5 && Set(details.map(\.bands)).count == 5)
                for curve in details { try EqualizerBank.validateCurve(curve.setting(), capability: cap) }
            }
        }
    }

    @Test func recoveryIsPersistedBeforeAnySelectionAndDiskFailurePreventsChanges() async throws {
        let driver = BankTestDriver()
        var snapshots: [EqualizerGuideRecord] = []
        let record = try await EqualizerGuideDeviceAccess.prepare(driver: driver, address: address) { value in
            if snapshots.isEmpty { #expect(driver.selections.isEmpty && value.bank == nil) }
            else { #expect(value.bank != nil && driver.selected == value.original.presetID) }
            snapshots.append(value)
        }
        #expect(snapshots.count == 2 && snapshots.last == record && driver.bandWrites == 0)
        let failed = BankTestDriver()
        do {
            _ = try await EqualizerGuideDeviceAccess.prepare(driver: failed, address: address) { _ in throw DriverError.malformed("disk unavailable") }
            Issue.record("Must not start without recovery")
        } catch {}
        #expect(failed.selections.isEmpty && failed.bandWrites == 0)
    }

    @Test func auditionsOnlyUseManualAndCancelRestoresEveryCurveIncludingAnOriginallyActiveManual() async throws {
        for originalID: UInt8 in [0x10, 0xA0, 0xA1, 0xA2] {
            let driver = BankTestDriver()
            try await driver.apply(.equalizerPreset(originalID))
            let original = driver.curves
            let record = try await EqualizerGuideDeviceAccess.prepare(driver: driver, address: address) { _ in }
            let curve = EqualizerGuideRound.balance.choices(around: nil)[4]
            try await EqualizerGuideDeviceAccess.preview(curve, record: record, address: address, driver: driver)
            #expect(driver.selected == 0xA0 && driver.curves[0xA0] == curve.setting())
            #expect(driver.curves[0xA1] == original[0xA1] && driver.curves[0xA2] == original[0xA2])
            try await EqualizerGuideDeviceAccess.preview(nil, record: record, address: address, driver: driver)
            #expect(driver.state.equalizer == record.original)
            try await EqualizerGuideDeviceAccess.preview(curve, record: record, address: address, driver: driver)
            try await EqualizerGuideDeviceAccess.finish(saving: nil, record: record, address: address, driver: driver)
            #expect(driver.curves == original && driver.selected == originalID)
            #expect(record.bank?.matches(driver.state.equalizerBank) == true)
        }
    }

    @Test func savingCustom2PreservesManualAndCustom1AndRequiresFreshFinalBank() async throws {
        let driver = BankTestDriver()
        let original = driver.curves
        let record = try await EqualizerGuideDeviceAccess.prepare(driver: driver, address: address) { _ in }
        let balance = EqualizerGuideRound.balance.choices(around: nil)[2]
        let bass = EqualizerGuideRound.bass.choices(around: balance)[3]
        let result = EqualizerGuideRound.detail.choices(around: bass)[1]
        try await EqualizerGuideDeviceAccess.preview(result, record: record, address: address, driver: driver)
        try await EqualizerGuideDeviceAccess.finish(saving: result, record: record, address: address, driver: driver)
        #expect(driver.selected == 0xA2 && driver.curves[0xA2] == result.setting(0xA2))
        #expect(driver.curves[0xA0] == original[0xA0] && driver.curves[0xA1] == original[0xA1])
        #expect(try record.result(saving: result).matches(driver.state.equalizerBank))
        // The unchanged original record can roll back even after Custom 2 was overwritten.
        try await EqualizerGuideDeviceAccess.finish(saving: nil, record: record, address: address, driver: driver)
        #expect(driver.curves == original && driver.selected == record.original.presetID)
    }

    @Test func wrongDeviceFirmwareLayoutAndIncompleteSnapshotsRejectBeforeWrites() async throws {
        let driver = BankTestDriver()
        let record = try await EqualizerGuideDeviceAccess.prepare(driver: driver, address: address) { _ in }
        let curve = EqualizerGuideRound.balance.choices(around: nil)[1]
        for mutation in 0..<6 {
            let other = BankTestDriver()
            var candidate = record
            var actualAddress = address
            switch mutation {
            case 0: actualAddress = "00:11:22:33:44:55"
            case 1: other.state.firmware = "2.0.0"
            case 2: other.state.modelName = "WF-1000XM3"
            case 3: other.state.capabilities.equalizer?.bandRange = -6...6
            case 4: other.state.equalizerAvailable = false
            default: candidate.bank?.curves.removeLast()
            }
            do {
                try await EqualizerGuideDeviceAccess.preview(curve, record: candidate, address: actualAddress, driver: other)
                Issue.record("Changed identity or incomplete recovery must be refused")
            } catch {}
            #expect(other.selections.isEmpty && other.bandWrites == 0)
        }
        do {
            try await EqualizerGuideDeviceAccess.preview(.init(bands: [99], bass: 0), record: record, address: address, driver: driver)
            Issue.record("Invalid curve must be refused")
        } catch {}
        #expect(driver.bandWrites == 0)
    }

    @Test func partialCaptureRecoveryRestoresSelectionWithoutWritingAnyBands() async throws {
        let driver = BankTestDriver()
        var durable: EqualizerGuideRecord?
        driver.beforeSelection = { slot in
            if slot == 0xA1 || slot == 0x10 { throw MDRLink.LinkError.closed }
        }
        do {
            _ = try await EqualizerGuideDeviceAccess.prepare(driver: driver, address: address) { durable = $0 }
            Issue.record("Disconnected capture cannot succeed")
        } catch {}
        let record = try #require(durable)
        #expect(record.bank == nil && driver.selected == 0xA0 && driver.bandWrites == 0)
        driver.beforeSelection = nil
        try await EqualizerGuideDeviceAccess.finish(saving: nil, record: record, address: address, driver: driver)
        #expect(driver.selected == 0x10 && driver.bandWrites == 0)
    }

    @Test func unconfirmedAuditionAndInterruptedSaveCanRecoverUsingTheSameOriginalRecord() async throws {
        let driver = BankTestDriver()
        let original = driver.curves
        let record = try await EqualizerGuideDeviceAccess.prepare(driver: driver, address: address) { _ in }
        let result = EqualizerGuideRound.balance.choices(around: nil)[3]
        driver.dropBandReply = true
        do {
            try await EqualizerGuideDeviceAccess.preview(result, record: record, address: address, driver: driver)
            Issue.record("An unconfirmed audition must fail")
        } catch {}
        #expect(driver.state.equalizer == nil)
        driver.dropBandReply = false
        // A reconnect initializes the selected EQ again, as the real driver does.
        driver.state.equalizer = driver.curves[driver.selected]
        driver.beforeSelection = { id in if id == 0xA2 { throw MDRLink.LinkError.closed } }
        do {
            try await EqualizerGuideDeviceAccess.finish(saving: result, record: record, address: address, driver: driver)
            Issue.record("Partial save cannot succeed")
        } catch {}
        driver.beforeSelection = nil
        try await EqualizerGuideDeviceAccess.finish(saving: nil, record: record, address: address, driver: driver)
        #expect(driver.curves == original && driver.selected == record.original.presetID)
    }

    @Test func recoveryFileRoundTripsAndUnexpectedChangesCannotBeDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EqualizerGuideStore(url: directory.appendingPathComponent("recovery.json"))
        let driver = BankTestDriver()
        let record = try await EqualizerGuideDeviceAccess.prepare(driver: driver, address: address, persist: store.save)
        #expect(try store.load() == record)
        var changed = record; changed.bank?.curves[0].bands[0] = -8
        try store.save(changed)
        #expect(throws: (any Error).self) { try store.clear(matching: record) }
        #expect(try store.load() == changed)
        let bytes = try Data(contentsOf: store.url)
        try store.archive()
        let archives = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(!store.exists)
        try #require(archives.count == 1)
        #expect(try Data(contentsOf: archives[0]) == bytes)
        try store.save(record)
        try store.clear(matching: record)
        #expect(!store.exists)
        try Data("not a recovery".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(store.exists)
    }
}
