import Foundation

/// Independently designed listening comparisons, not Sony's proprietary preference algorithm.
/// This workflow targets the XM3's five bands and Clear Bass, and saves the result to Custom 2.
struct EqualizerGuideCurve: Codable, Equatable, Sendable {
    var bands: [Int]
    var bass: Int

    func setting(_ slot: UInt8 = 0xA0) -> EqualizerState {
        EqualizerState(presetID: slot, bands: bands, clearBass: bass)
    }
}

enum EqualizerGuideRound: Int, CaseIterable {
    case balance, bass, detail, review

    var title: String {
        switch self {
        case .balance: "Choose a sound balance"
        case .bass: "Refine the bass"
        case .detail: "Refine the detail"
        case .review: "Your equalizer"
        }
    }

    func choices(around base: EqualizerGuideCurve?) -> [EqualizerGuideCurve] {
        if self == .balance {
            return [
                .init(bands: [0, 0, 0, 0, 0], bass: 0),
                .init(bands: [2, 1, 0, -2, -2], bass: 2),
                .init(bands: [-1, 0, 1, 3, 3], bass: -1),
                .init(bands: [-1, 2, 3, 1, 0], bass: 0),
                .init(bands: [1, -1, -1, 2, 2], bass: 3)
            ]
        }
        guard let base, base.bands.count == 5 else { return [] }
        switch self {
        case .bass:
            return [-4, -2, 0, 2, 4].map { amount in
                .init(bands: base.bands, bass: min(10, max(-10, base.bass + amount)))
            }
        case .detail:
            return [-4, -2, 0, 2, 4].map { amount in
                var bands = base.bands
                bands[2] = min(10, max(-10, bands[2] + amount / 2))
                bands[3] = min(10, max(-10, bands[3] + amount))
                bands[4] = min(10, max(-10, bands[4] + amount))
                return .init(bands: bands, bass: base.bass)
            }
        case .review: return []
        case .balance: return []
        }
    }
}

/// Written before even temporarily selecting a different slot. A partial capture can therefore recover
/// its selection; once capture completes, every editable curve survives a disconnect or app restart.
struct EqualizerGuideRecord: Codable, Equatable, Sendable {
    var version = 1
    let address: String
    let model: String
    let firmware: String
    let family: ProtocolFamily
    let presetIDs: [UInt8]
    let original: EqualizerState
    var bank: EqualizerBank?

    @MainActor static func supported(_ state: DeviceState) -> Bool {
        guard state.modelName == "WH-1000XM3", state.family == .v1,
              let cap = state.capabilities.equalizer else { return false }
        return cap.supportsCustomBank && cap.supportsBandEditing && cap.bandCount == 5
            && cap.bandRange == -10...10 && cap.hasClearBass
            && Set(cap.presets.filter(\.isEditable).map(\.id)) == [0xA0, 0xA1, 0xA2]
    }

    @MainActor static func make(state: DeviceState, address: String) throws -> Self {
        guard supported(state), state.equalizerAvailable == true, let original = state.equalizer,
              let model = state.modelName, let firmware = state.firmware, !firmware.isEmpty,
              let family = state.family, let cap = state.capabilities.equalizer, !address.isEmpty else {
            throw SettingsBackupError.invalid("Connect a WH-1000XM3 with an available five-band equalizer before starting.")
        }
        let record = Self(address: address, model: model, firmware: firmware, family: family,
                          presetIDs: cap.presets.map(\.id).sorted(), original: original)
        try record.validate(state: state, address: address)
        return record
    }

    @MainActor func validate(state: DeviceState, address: String) throws {
        guard version == 1, self.address == address, model == state.modelName, firmware == state.firmware,
              family == state.family, Self.supported(state), state.equalizerAvailable == true,
              let cap = state.capabilities.equalizer, presetIDs == cap.presets.map(\.id).sorted(),
              Set(presetIDs).count == presetIDs.count, presetIDs.contains(original.presetID) else {
            throw SettingsBackupError.invalid("Reconnect the same headphones on firmware \(firmware) with EQ available. The saved recovery belongs to a different device, firmware or EQ layout.")
        }
        try EqualizerBank.validateCurve(original, capability: cap)
        if let bank {
            try bank.validate(cap)
            guard bank.activePresetID == original.presetID,
                  !EqualizerPreset(id: original.presetID, name: "").isEditable
                    || bank.curves.first(where: { $0.presetID == original.presetID }) == original else {
                throw SettingsBackupError.invalid("The recovery's original selection and EQ bank disagree.")
            }
        }
    }

    func result(saving curve: EqualizerGuideCurve?) throws -> EqualizerBank {
        guard var bank else { throw SettingsBackupError.invalid("The original EQ curves have not been collected.") }
        if let curve {
            guard curve.bands.count == 5, curve.bands.allSatisfy({ (-10...10).contains($0) }),
                  (-10...10).contains(curve.bass), let index = bank.curves.firstIndex(where: { $0.presetID == 0xA2 }) else {
                throw SettingsBackupError.invalid("The chosen curve cannot be saved to Custom 2.")
            }
            bank.curves[index] = curve.setting(0xA2)
            bank.activePresetID = 0xA2
        }
        return bank
    }
}

struct EqualizerGuideStore {
    let url: URL
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundConnect/equalizer-guide-recovery.json")
    }
    init(url: URL = Self.defaultURL) { self.url = url }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func load() throws -> EqualizerGuideRecord? {
        guard exists else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65_536 else {
            throw SettingsBackupError.invalid("The EQ recovery file is too large. It has been preserved.")
        }
        let record = try JSONDecoder().decode(EqualizerGuideRecord.self, from: Data(contentsOf: url))
        guard record.version == 1 else { throw SettingsBackupError.invalid("This EQ recovery file needs a newer OpenXM version.") }
        return record
    }

    func save(_ record: EqualizerGuideRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func clear(matching record: EqualizerGuideRecord) throws {
        guard try load() == record else { throw SettingsBackupError.invalid("The EQ recovery file changed outside OpenXM. It has been preserved.") }
        try FileManager.default.removeItem(at: url)
    }

    /// Explicit user choice only. Keep the exact original bytes for later manual recovery.
    func archive() throws {
        let destination = url.deletingPathExtension().appendingPathExtension("\(UUID().uuidString).saved.json")
        try FileManager.default.moveItem(at: url, to: destination)
    }
}

@MainActor enum EqualizerGuideDeviceAccess {
    static func prepare(driver: HeadphoneDriver, address: String,
                        persist: (EqualizerGuideRecord) throws -> Void) async throws -> EqualizerGuideRecord {
        var record = try EqualizerGuideRecord.make(state: driver.state, address: address)
        try persist(record)
        record.bank = try await driver.captureEqualizerBank()
        try record.validate(state: driver.state, address: address)
        try persist(record)
        return record
    }

    static func preview(_ curve: EqualizerGuideCurve?, record: EqualizerGuideRecord,
                        address: String, driver: HeadphoneDriver) async throws {
        try record.validate(state: driver.state, address: address)
        guard record.bank != nil else { throw SettingsBackupError.invalid("Finish collecting the original EQ curves first.") }
        if let curve {
            try EqualizerBank.validateCurve(curve.setting(), capability: driver.state.capabilities.equalizer!)
            try await write(curve.setting(), driver: driver)
        } else if record.original.presetID == 0xA0 {
            try await write(record.original, driver: driver)
        } else {
            try await select(record.original.presetID, driver: driver)
            guard driver.state.equalizer == record.original else { throw SettingsBackupError.invalid("The original sound was not confirmed.") }
        }
    }

    static func finish(saving curve: EqualizerGuideCurve?, record: EqualizerGuideRecord,
                       address: String, driver: HeadphoneDriver) async throws {
        try record.validate(state: driver.state, address: address)
        if record.bank == nil && curve == nil {
            // Capture only selects slots; it cannot have changed their contents.
            try await select(record.original.presetID, driver: driver)
            guard driver.state.equalizer == record.original else { throw SettingsBackupError.invalid("The original EQ selection could not be verified.") }
        } else {
            let target = try record.result(saving: curve)
            try await driver.restoreEqualizerBank(target)
            guard target.matches(driver.state.equalizerBank) else { throw SettingsBackupError.invalid("The final EQ bank was not verified.") }
        }
    }

    private static func select(_ slot: UInt8, driver: HeadphoneDriver) async throws {
        driver.state.equalizer = nil
        try await driver.apply(.equalizerPreset(slot))
        guard driver.state.equalizer?.presetID == slot else { throw SettingsBackupError.invalid("The EQ slot was not confirmed. No curve was sent.") }
    }

    private static func write(_ curve: EqualizerState, driver: HeadphoneDriver) async throws {
        try await select(curve.presetID, driver: driver)
        try await driver.apply(.equalizerBands(bands: curve.bands, clearBass: curve.clearBass))
        guard driver.state.equalizer == curve else { throw SettingsBackupError.invalid("The headphones did not confirm this sound balance.") }
    }
}
