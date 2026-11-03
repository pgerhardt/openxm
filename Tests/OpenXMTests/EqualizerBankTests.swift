import Foundation
import Testing
@testable import OpenXM

@MainActor struct EqualizerBankTests {
    private func driver(_ family: ProtocolFamily = .v1) -> BankTestDriver { BankTestDriver(family: family) }

    @Test(arguments: [ProtocolFamily.v1, .v2]) func captureReadsEveryEditableSlotAndRestoresOriginalWithoutBandWrites(family: ProtocolFamily) async throws {
        let d = driver(family)
        let before = d.curves
        let bank = try await d.captureEqualizerBank()
        #expect(bank.activePresetID == 0x10)
        #expect(Set(bank.curves.map(\.presetID)) == [0xA0, 0xA1, 0xA2])
        #expect(d.selections == [0xA0, 0xA1, 0xA2, 0x10])
        #expect(d.bandWrites == 0 && d.curves == before && d.state.equalizer == before[0x10])
        #expect(DeviceChange.equalizerBank(bank).isReflected(in: d.state) == true)
    }

    @Test(arguments: [ProtocolFamily.v1, .v2]) func failedOrIncompleteReadStillRestoresOriginalAndCannotProduceABank(family: ProtocolFamily) async {
        for incomplete in [false, true] {
            let d = driver(family)
            d.beforeSelection = { id in
                if id == 0xA1 {
                    if incomplete { d.curves[id]?.bands = [] }
                    else { throw DriverError.malformed("synthetic slot read failure") }
                }
            }
            do { _ = try await d.captureEqualizerBank(); Issue.record("Bad reads cannot produce backups") } catch {}
            #expect(d.state.equalizer?.presetID == 0x10 && d.selections.last == 0x10)
            #expect(d.state.equalizerBank == nil && d.bandWrites == 0)
        }
    }

    @Test(arguments: [ProtocolFamily.v1, .v2]) func cancellationRestoresSelectionUsingAnUncancelledCleanupTask(family: ProtocolFamily) async {
        let d = driver(family)
        d.beforeSelection = { id in
            if id == 0xA1 { withUnsafeCurrentTask { $0?.cancel() } }
            try Task.checkCancellation()
        }
        let result = await Task { @MainActor in
            do { _ = try await d.captureEqualizerBank(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(result && d.state.equalizer?.presetID == 0x10)
        #expect(d.selections.last == 0x10 && d.state.equalizerBank == nil)
    }

    @Test(arguments: [ProtocolFamily.v1, .v2]) func failedCleanupIsReportedInsteadOfReturningTheCollectedCurves(family: ProtocolFamily) async {
        let d = driver(family)
        d.beforeSelection = { id in if id == 0x10 { throw MDRLink.LinkError.closed } }
        do { _ = try await d.captureEqualizerBank(); Issue.record("Cleanup failure must be visible") }
        catch { #expect(error.localizedDescription.contains("Could not confirm restoration")) }
        #expect(d.state.equalizerBank == nil)
    }

    @Test(arguments: [ProtocolFamily.v1, .v2]) func restoreChecksEverySlotAfterSwitchingAndLeavesTheSavedPresetActive(family: ProtocolFamily) async throws {
        let d = driver(family)
        var bank = try await d.captureEqualizerBank()
        bank.activePresetID = 0xA1
        for i in bank.curves.indices { bank.curves[i].bands = [i, 2, -3, 4, -5]; bank.curves[i].clearBass = i - 1 }
        try await d.restoreEqualizerBank(bank)
        #expect(d.bandWrites == 3 && d.selected == 0xA1)
        #expect(bank.matches(d.state.equalizerBank))
        #expect(bank.curves.allSatisfy { d.curves[$0.presetID] == $0 })
        // A slot that accepts a write but loses it on the next selection must fail persistence validation.
        let unstable = driver(family)
        var lost = false
        unstable.beforeSelection = { id in
            if id == 0xA2 && unstable.bandWrites > 0 && !lost {
                unstable.curves[0xA0]?.bands = [0, 0, 0, 0, 0]; lost = true
            }
        }
        do { try await unstable.restoreEqualizerBank(bank); Issue.record("Lost curve must fail verification") }
        catch { #expect(error.localizedDescription.contains("did not persist")) }
        #expect(unstable.selected == 0x10 && unstable.state.equalizerBank == nil)
    }

    @Test(arguments: [ProtocolFamily.v1, .v2]) func wrongSelectionCannotSendBandsToAnotherSlotAndInvalidBankSendsNothing(family: ProtocolFamily) async throws {
        let d = driver(family)
        let bank = try await d.captureEqualizerBank()
        d.wrongSelection = 0xA0
        do { try await d.restoreEqualizerBank(bank); Issue.record("Unconfirmed selection must stop") } catch {}
        #expect(d.bandWrites == 0 && d.selected == 0x10)
        let other = driver(family)
        var invalid = bank; invalid.curves[0].bands[0] = 99
        do { try await other.restoreEqualizerBank(invalid); Issue.record("Out-of-range curve must fail before selection") } catch {}
        #expect(other.selections.isEmpty && other.bandWrites == 0)
        invalid = bank; invalid.curves.removeLast()
        #expect(throws: (any Error).self) { try invalid.validate(other.state.capabilities.equalizer!) }
    }

    @Test(arguments: [ProtocolFamily.v1, .v2]) func stoppingRestoreKeepsAppliedCurvesAndRestoresTheOriginalSelection(family: ProtocolFamily) async throws {
        let d = driver(family)
        var bank = try await d.captureEqualizerBank()
        bank.curves[0].bands = [5, 4, 3, 2, 1]
        d.beforeSelection = { id in
            if id == 0xA1 { withUnsafeCurrentTask { $0?.cancel() } }
            try Task.checkCancellation()
        }
        let cancelled = await Task { @MainActor in
            do { try await d.restoreEqualizerBank(bank); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(cancelled && d.selected == 0x10 && d.bandWrites == 1)
        #expect(d.curves[0xA0]?.bands == [5, 4, 3, 2, 1] && d.state.equalizerBank == nil)
    }

    @Test(arguments: [ProtocolFamily.v1, .v2]) func backupVersioningAndCapabilityDriftKeepCompleteBanksDistinctFromActiveEQ(family: ProtocolFamily) async throws {
        let d = driver(family)
        _ = try await d.captureEqualizerBank()
        let saved = try SettingsBackup.capture(d.state)
        #expect(saved.version == 2 && saved.hasEqualizerBank)
        #expect(try SettingsBackup.decode(saved.encoded()) == saved)
        #expect(saved.settings.filter { $0.id == "equalizer" }.count == 1)
        #expect(try saved.plan(for: d.state).first { $0.id == "equalizer" }?.alreadyMatches == true)
        d.state.capabilities.equalizer?.presets.removeLast()
        #expect(try saved.plan(for: d.state).first { $0.id == "equalizer" }?.unavailableReason != nil)
        var legacy = saved; legacy.version = 1
        #expect(throws: (any Error).self) { try SettingsBackup.decode(legacy.encoded()) }
        legacy.settings = [.equalizer(EqualizerState(presetID: 0x10, bands: [], clearBass: nil))]
        #expect(try SettingsBackup.decode(legacy.encoded()) == legacy)
        var duplicate = saved; duplicate.settings.append(legacy.settings[0])
        #expect(throws: (any Error).self) { try SettingsBackup.decode(duplicate.encoded()) }
    }

    @Test func emptyEQRepliesNeverInheritAnotherPresetsCurveAndNotificationsInvalidateBank() async throws {
        for family in [ProtocolFamily.v1, .v2] {
            let d = driver()
            _ = try await d.captureEqualizerBank()
            let parser: HeadphoneDriver = family == .v1 ? V1Driver(link: d.link, state: d.state) : V2Driver(link: d.link, state: d.state)
            parser.handle(MDRFrame(type: .dataMdr, sequence: 0, payload: [0x59, family == .v1 ? 1 : 0, 0xA2, 0]))
            #expect(d.state.equalizer?.presetID == 0xA2 && d.state.equalizer?.bands == [])
            #expect(d.state.equalizer?.clearBass == nil && d.state.equalizerBank == nil)
            d.state.equalizerBank = EqualizerBank(activePresetID: 0xA2, curves: [])
            d.state.reset()
            #expect(d.state.equalizerBank == nil)
        }
    }

    @Test func v2TenBandBankKeepsEveryDestinationAndRejectsUnconfirmedWrites() async throws {
        let d = BankTestDriver(family: .v2, tenBand: true)
        var bank = try await d.captureEqualizerBank()
        bank.activePresetID = 0xA2
        for i in bank.curves.indices { bank.curves[i].bands = Array(repeating: i - 2, count: 10) }
        try await d.restoreEqualizerBank(bank)
        #expect(bank.matches(d.state.equalizerBank) && d.selected == 0xA2 && d.bandWrites == 3)
        d.dropBandReply = true
        // Even already-equal curves require a fresh complete read-back.
        do { try await d.restoreEqualizerBank(bank); Issue.record("A missing curve cannot confirm restoration") }
        catch { #expect(error.localizedDescription.contains("did not confirm")) }
        #expect(d.selected == 0xA2 && d.state.equalizerBank == nil)
        d.state.capabilities.equalizer?.supportsCustomBank = false
        let count = d.selections.count
        do { _ = try await d.captureEqualizerBank(); Issue.record("Unverified layouts cannot collect slots") } catch {}
        do { try await d.restoreEqualizerBank(bank); Issue.record("Unverified layouts cannot restore slots") } catch {}
        #expect(d.selections.count == count)
        #expect(throws: (any Error).self) { try SavedHeadphoneSetting.equalizerBank(bank).changes(for: d.state) }
    }
}

@MainActor final class BankTestDriver: HeadphoneDriver {
    let link = MDRLink(transport: nil)
    let state = DeviceState()
    var selected: UInt8 = 0x10
    var curves: [UInt8: EqualizerState] = [:]
    var selections: [UInt8] = []
    var bandWrites = 0
    var beforeSelection: ((UInt8) throws -> Void)?
    var wrongSelection: UInt8?
    var dropBandReply = false

    init(family: ProtocolFamily = .v1, tenBand: Bool = false) {
        state.family = family; state.modelName = family == .v1 ? "WH-1000XM3" : "Synthetic V2"; state.firmware = "4.5.2"; state.capabilitiesKnown = true
        let ids: [UInt8] = [0x10, 0xA0, 0xA1, 0xA2]
        state.capabilities.equalizer = EqualizerCapability(presets: ids.map { EqualizerPreset(id: $0, name: "") },
            bandCount: tenBand ? 10 : 5, bandRange: tenBand ? -6...6 : -10...10, hasClearBass: !tenBand)
        for (index, id) in ids.enumerated() {
            curves[id] = EqualizerState(presetID: id, bands: tenBand ? Array(repeating: index, count: 10) : [index, 0, 1, -2, 3], clearBass: tenBand ? nil : index)
        }
        state.equalizer = curves[selected]; state.equalizerAvailable = true
    }

    func apply(_ change: DeviceChange) async throws {
        state.equalizerBank = nil
        switch change {
        case .equalizerPreset(let id):
            selections.append(id)
            try beforeSelection?(id)
            if id != wrongSelection { selected = id }
        case .equalizerBands(let bands, let bass):
            if state.family == .v2 {
                // Exercise the production V2 encoder at the exact point bank restoration calls it.
                let payload = try V2Driver(link: link, state: state).equalizerPayload(change)
                guard payload[2] == selected else { throw DriverError.malformed("wrong synthetic destination") }
            } else {
                let payload = try V1Driver(link: link, state: state).equalizerPayload(change)
                guard payload[2] == 0xFF, state.equalizer?.presetID == selected else {
                    throw DriverError.malformed("unconfirmed synthetic V1 destination")
                }
            }
            state.equalizer = nil
            bandWrites += 1
            curves[selected] = EqualizerState(presetID: selected, bands: bands, clearBass: bass)
            if dropBandReply { return }
        default: throw DriverError.unsupported("synthetic driver change")
        }
        state.equalizer = curves[selected]
    }
    func handle(_ frame: MDRFrame) {}
    func describe(_ frame: MDRFrame) -> String { "" }
    func initialize() async throws {}
    func refreshStatus() async throws {}
    func answerAlert(_ alert: DeviceAlert, accept: Bool) async throws {}
    func startNoiseOptimizer() async throws {}
    func cancelNoiseOptimizer() async throws {}
    func powerOff() async throws {}
}
