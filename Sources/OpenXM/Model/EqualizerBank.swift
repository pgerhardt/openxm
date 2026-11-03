import Foundation

/// User-editable curves plus the selected preset. Fixed Sony curves need only their preset ID.
struct EqualizerBank: Codable, Equatable, Sendable {
    var activePresetID: UInt8
    var curves: [EqualizerState]

    func validate(_ capability: EqualizerCapability) throws {
        let expected = Set(capability.presets.filter(\.isEditable).map(\.id))
        guard capability.supportsCustomBank, !expected.isEmpty, expected.count <= 6, curves.count == expected.count,
              Set(curves.map(\.presetID)) == expected,
              capability.presets.contains(where: { $0.id == activePresetID }) else {
            throw SettingsBackupError.invalid("The saved custom EQ slots differ from the connected headphones. No curves were written.")
        }
        for curve in curves { try Self.validateCurve(curve, capability: capability) }
    }

    static func validateCurve(_ curve: EqualizerState, capability: EqualizerCapability) throws {
        guard curve.bands.count == capability.bandCount, curve.bands.allSatisfy(capability.bandRange.contains),
              capability.hasClearBass ? curve.clearBass.map({ (-10...10).contains($0) }) == true : curve.clearBass == nil else {
            throw SettingsBackupError.invalid("The headphones did not report a complete EQ curve within the supported range.")
        }
    }

    func matches(_ other: Self?) -> Bool {
        guard let other, activePresetID == other.activePresetID, curves.count == other.curves.count else { return false }
        return curves.sorted { $0.presetID < $1.presetID } == other.curves.sorted { $0.presetID < $1.presetID }
    }
}

/// Both protocol families expose the active curve, so reading inactive slots temporarily selects them. The caller holds the
/// link transaction throughout. Cleanup runs even after cancellation; it never rewrites curve contents.
@MainActor
enum EqualizerBankAccess {
    static func capture(original: EqualizerState, capability: EqualizerCapability,
                        select: @escaping @MainActor (UInt8) async throws -> EqualizerState) async throws -> EqualizerBank {
        guard capability.presets.contains(where: { $0.id == original.presetID }) else {
            throw SettingsBackupError.invalid("Read the original EQ preset before collecting custom curves.")
        }
        let slots = capability.presets.filter(\.isEditable).map(\.id)
        guard !slots.isEmpty, slots.count <= 6, Set(slots).count == slots.count else {
            throw SettingsBackupError.invalid("No unambiguous editable EQ slots were reported.")
        }
        if slots.contains(original.presetID) { try EqualizerBank.validateCurve(original, capability: capability) }
        var curves: [EqualizerState] = []
        var failure: (any Error)?
        var attemptedSelection = false
        do {
            for slot in slots {
                try Task.checkCancellation()
                attemptedSelection = true // A timed-out command may still have changed the device.
                let curve = try await select(slot)
                guard curve.presetID == slot else { throw SettingsBackupError.invalid("The headphones did not select the requested EQ slot.") }
                try EqualizerBank.validateCurve(curve, capability: capability)
                curves.append(curve)
            }
        } catch { failure = error }
        if attemptedSelection {
            do {
                // An unstructured task does not inherit the cancelled task's cancellation flag.
                let restored = try await Task { @MainActor in try await select(original.presetID) }.value
                guard restored.presetID == original.presetID,
                      !slots.contains(original.presetID) || restored == original else {
                    throw SettingsBackupError.invalid("The original EQ selection or curve did not match.")
                }
            } catch {
                throw SettingsBackupError.invalid("Could not confirm restoration of \(EqualizerPreset.displayName(for: original.presetID)) after reading custom EQ. Reconnect and select it again. \(error.localizedDescription)")
            }
        }
        if let failure { throw failure }
        let bank = EqualizerBank(activePresetID: original.presetID, curves: curves)
        try bank.validate(capability)
        return bank
    }
}

extension HeadphoneDriver {
    /// Must run inside the caller's exclusive transaction, with fresh identity/capabilities/current EQ.
    func captureEqualizerBank() async throws -> EqualizerBank {
        guard state.family != nil, state.equalizerAvailable == true,
              let capability = state.capabilities.equalizer, capability.supportsCustomBank,
              let original = state.equalizer else {
            throw SettingsBackupError.invalid("Custom EQ backup requires a supported model with EQ available and a current preset read.")
        }
        state.equalizerBank = nil
        let bank = try await EqualizerBankAccess.capture(original: original, capability: capability) { [self] id in
            // A malformed reply must not confirm a selection using an older value.
            state.equalizer = nil
            try await apply(.equalizerPreset(id))
            guard let value = state.equalizer else { throw SettingsBackupError.invalid("No complete EQ reply was received.") }
            return value
        }
        state.equalizerBank = bank
        return bank
    }

    func restoreEqualizerBank(_ bank: EqualizerBank) async throws {
        guard state.family != nil, state.equalizerAvailable == true, let capability = state.capabilities.equalizer,
              let original = state.equalizer else { throw DriverError.unsupported("Custom EQ restoration in the current mode") }
        try bank.validate(capability)
        state.equalizerBank = nil
        do {
            for curve in bank.curves.sorted(by: { $0.presetID < $1.presetID }) {
                try Task.checkCancellation()
                state.equalizer = nil
                try await apply(.equalizerPreset(curve.presetID))
                guard state.equalizer?.presetID == curve.presetID else { throw SettingsBackupError.invalid("The EQ slot selection was not confirmed; no bands were sent to it.") }
                // V2 needs this confirmed preset ID to address the write. Each driver clears the old
                // value after encoding the command, so only a fresh reply can confirm the curve.
                try await apply(.equalizerBands(bands: curve.bands, clearBass: curve.clearBass))
                guard state.equalizer == curve else { throw SettingsBackupError.invalid("The headphones did not confirm a saved EQ curve.") }
            }
            state.equalizer = nil
            try await apply(.equalizerPreset(bank.activePresetID))
            guard state.equalizer?.presetID == bank.activePresetID else { throw SettingsBackupError.invalid("The saved active EQ preset was not confirmed.") }
            let result = try await captureEqualizerBank()
            guard bank.matches(result) else { throw SettingsBackupError.invalid("A custom EQ curve did not persist after changing presets.") }
        } catch {
            let failure = error
            // Keep already-applied curves, but return to the pre-restore selection on failure or Stop.
            do {
                try await Task { @MainActor [self] in
                    state.equalizer = nil
                    try await apply(.equalizerPreset(original.presetID))
                    guard state.equalizer?.presetID == original.presetID else { throw DriverError.malformed("original EQ selection") }
                }.value
            } catch {
                throw SettingsBackupError.invalid("Restore stopped and the original EQ selection could not be confirmed. Reconnect and select \(EqualizerPreset.displayName(for: original.presetID)). \(failure.localizedDescription)")
            }
            throw failure
        }
    }
}
