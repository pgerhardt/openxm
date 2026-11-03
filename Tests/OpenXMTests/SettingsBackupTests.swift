import Foundation
import Testing
@testable import OpenXM

@MainActor struct SettingsBackupTests {
    @Test func refreshingReviewPreservesChoicesAndCannotReenableDeselectedSettings() {
        let entries: [SettingsRestoreEntry] = [
            .init(setting: .upscaling(true), changes: [], unavailableReason: nil, alreadyMatches: false),
            .init(setting: .volume(8), changes: [], unavailableReason: nil, alreadyMatches: false),
            .init(setting: .autoPowerOff(1), changes: [], unavailableReason: "Unavailable", alreadyMatches: false),
            .init(setting: .voiceLanguage(.init(rawValue: 1)), changes: [], unavailableReason: nil, alreadyMatches: false)
        ]
        let dsee = entries[0].id, volume = entries[1].id, unavailable = entries[2].id, language = entries[3].id
        #expect(SettingsRestoreSelection.reviewed(entries) == [dsee])
        #expect(SettingsRestoreSelection.reviewed(entries, keeping: []) == [])
        #expect(SettingsRestoreSelection.reviewed(entries, keeping: [volume]) == [volume])
        #expect(SettingsRestoreSelection.reviewed(entries, keeping: [dsee, volume, unavailable, language, "unknown"])
            == [dsee, volume])
    }

    private func headset() -> DeviceState {
        let state = DeviceState()
        state.family = .v1; state.modelName = "WH-1000XM3"; state.firmware = "4.5.2"; state.capabilitiesKnown = true
        state.capabilities.upscalingName = "DSEE HX"; state.upscaling = UpscalingState(enabled: false, active: false)
        state.settingReadbacks.insert(.upscalingEnabled)
        state.capabilities.connectionPriority = true; state.connectionPriority = .soundQuality
        state.capabilities.noise = NoiseControlCapability(modes: [.noiseCancelling, .ambient, .off], ambientRange: 1...20,
                                                          supportsVoiceFocus: true, supportsAutoAmbient: false)
        state.noise = NoiseControl(mode: .noiseCancelling, ambientLevel: 12, focusOnVoice: false)
        state.noiseAvailable = true
        state.capabilities.generalSettingSlots = [0xD1]
        state.generalSettings = [GeneralSetting(slot: 0xD1, key: "ASSIGNABLE_KEY_SETTING", summaryKey: "", isBoolean: false,
            options: [GeneralSettingOption(index: 0, key: "ASSIGNABLE_KEY_ELEM_NCASM", summaryKey: ""),
                      GeneralSettingOption(index: 1, key: "ASSIGNABLE_KEY_ELEM_GOOGLE_ASSISTANT", summaryKey: "")], selectedIndex: 1)]
        return state
    }

    @Test func voiceLanguageBackupPreservesSelectionWithoutDeviceServiceIdentityOrUpdateCommands() throws {
        let state = headset()
        state.capabilities.voiceGuidanceCapability = .init(supportsOnOff: true, supportsLanguage: true,
            languages: [.init(rawValue: 1), .init(rawValue: 11)])
        state.voiceGuidanceDetails.language = .init(rawValue: 11)
        state.voiceGuidanceDetails.downloadService = .init(categoryID: "PRIVATE-CATEGORY", serialNumber: "PRIVATE-SERIAL",
            entries: [.init(language: .init(rawValue: 11), serviceID: "PRIVATE-SERVICE")])
        state.voiceGuidanceDetails.updateMethod = .init(code: 0x10, parameters: [0, 50])
        state.voiceGuidanceDetails.languageUpdateEnabled = false
        let saved = try SettingsBackup.capture(state)
        let bytes = try saved.encoded()
        #expect(saved.version == 3 && saved.voiceLanguage == .init(rawValue: 11))
        #expect(try SettingsBackup.decode(bytes) == saved)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("PRIVATE-") && !text.contains("updateMethod") && !text.contains("languageUpdateEnabled"))
        let entry = try #require(try saved.plan(for: state).first { $0.id == "voiceLanguage" })
        #expect(entry.alreadyMatches && entry.changes.isEmpty && entry.unavailableReason == nil)
        for version in [1, 2] {
            var mislabeled = saved; mislabeled.version = version
            #expect(throws: (any Error).self) { try SettingsBackup.decode(mislabeled.encoded()) }
        }
        var unknown = saved
        unknown.settings = [.voiceLanguage(.init(rawValue: 0xFE))]
        #expect(throws: (any Error).self) { try SettingsBackup.decode(unknown.encoded()) }
    }

    @Test func voiceLanguageCaptureRequiresAnAdvertisedKnownCurrentValue() throws {
        let state = headset()
        state.capabilities.voiceGuidanceCapability = .init(supportsOnOff: true, supportsLanguage: true,
            languages: [.init(rawValue: 1), .init(rawValue: 0xFE)])
        for value: UInt8? in [nil, 11, 0xFE] {
            state.voiceGuidanceDetails.language = value.map { .init(rawValue: $0) }
            let saved = try SettingsBackup.capture(state)
            #expect(saved.voiceLanguage == nil && saved.version == 1)
            #expect(saved.omissions.contains { $0.hasPrefix("Voice-guidance language:") })
        }
        state.voiceGuidanceDetails.language = .init(rawValue: 1)
        state.family = .v2
        #expect(try SettingsBackup.capture(state).voiceLanguage == nil)
    }

    @Test func differentOrUnavailableLanguageCannotBecomeAnOrdinarySettingsWrite() async throws {
        let state = headset()
        state.capabilities.voiceGuidanceCapability = .init(supportsOnOff: true, supportsLanguage: true,
            languages: [.init(rawValue: 1), .init(rawValue: 11)])
        state.voiceGuidanceDetails.language = .init(rawValue: 11)
        let saved = try SettingsBackup.capture(state)
        let selection = try saved.plan(for: state).filter { $0.id == "voiceLanguage" || $0.id == "upscaling" }
        var writes = 0
        state.voiceGuidanceDetails.language = .init(rawValue: 1)
        let mismatch = try #require(try saved.plan(for: state).first { $0.id == "voiceLanguage" })
        #expect(!mismatch.alreadyMatches && mismatch.unavailableReason != nil && mismatch.changes.isEmpty)
        await #expect(throws: (any Error).self) {
            try await SettingsRestoreExecutor.run(backup: saved, entries: selection, read: { state },
                write: { _ in writes += 1; return .confirmed }, reconnect: {}, progress: { _, _ in })
        }
        #expect(writes == 0)
        state.capabilities.voiceGuidanceCapability = .init(supportsOnOff: true, supportsLanguage: true, languages: [.init(rawValue: 1)])
        #expect(throws: (any Error).self) { try SavedHeadphoneSetting.voiceLanguage(.init(rawValue: 11)).changes(for: state) }
        state.voiceGuidanceDetails.language = nil
        #expect(throws: (any Error).self) { try SavedHeadphoneSetting.voiceLanguage(.init(rawValue: 1)).changes(for: state) }
    }

    @Test func languageVerificationCannotSucceedIfTheLastReadChanges() async throws {
        let state = headset()
        state.capabilities.voiceGuidanceCapability = .init(supportsOnOff: true, supportsLanguage: true,
            languages: [.init(rawValue: 1), .init(rawValue: 11)])
        state.voiceGuidanceDetails.language = .init(rawValue: 11)
        let saved = try SettingsBackup.capture(state)
        let entries = try saved.plan(for: state).filter { $0.id == "voiceLanguage" }
        var reads = 0
        var outcomes: [String: SettingsRestoreOutcome] = [:]
        let verify: (SettingsRestoreEntry) async -> SettingsRestoreOutcome = { entry in
            let changes = try? entry.setting.changes(for: state)
            #expect(changes?.isEmpty == true)
            return .confirmed
        }
        await #expect(throws: (any Error).self) {
            try await SettingsRestoreExecutor.run(backup: saved, entries: entries, read: {
                reads += 1
                if reads == 2 { state.voiceGuidanceDetails.language = .init(rawValue: 1) }
                return state
            }, write: verify, reconnect: {}, progress: { id, result in if let result { outcomes[id] = result } })
        }
        guard case .failed = outcomes["voiceLanguage"] else { Issue.record("Changed language must not be verified"); return }
    }

    @Test func backupRoundTripsWithoutDeviceIdentityOrRawSlots() throws {
        let state = headset()
        state.uniqueID = "PRIVATE-DEVICE-ID"
        let backup = try SettingsBackup.capture(state, now: Date(timeIntervalSince1970: 12345))
        let bytes = try backup.encoded()
        #expect(try SettingsBackup.decode(bytes) == backup)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("PRIVATE-DEVICE-ID") && !text.contains("selectedIndex") && !text.contains("slot"))
        #expect(text.contains("ASSIGNABLE_KEY_ELEM_GOOGLE_ASSISTANT"))
        #expect(backup.omissions.contains { $0.contains("remembered values") })
        var future = backup; future.version = 4
        #expect(throws: (any Error).self) { try SettingsBackup.decode(future.encoded()) }
        var duplicate = backup; duplicate.settings.append(duplicate.settings[0])
        #expect(throws: (any Error).self) { try SettingsBackup.decode(duplicate.encoded()) }
        #expect(throws: (any Error).self) { try SettingsBackup.decode(Data(repeating: 0, count: 1_048_577)) }
    }

    @Test func buttonRestoreUsesStableNamesAndRefusesAmbiguity() throws {
        let state = headset()
        let backup = try SettingsBackup.capture(state)
        state.generalSettings[0] = GeneralSetting(slot: 0xD3, key: "ASSIGNABLE_KEY_SETTING", summaryKey: "", isBoolean: false,
            options: [GeneralSettingOption(index: 2, key: "ASSIGNABLE_KEY_ELEM_GOOGLE_ASSISTANT", summaryKey: "")], selectedIndex: 2)
        let entry = try #require(backup.plan(for: state).first { $0.id == "general:ASSIGNABLE_KEY_SETTING" })
        #expect(entry.changes == [.generalSettingChoice(slot: 0xD3, index: 2)])
        #expect(entry.alreadyMatches)
        state.generalSettings[0].options = []
        #expect(try backup.plan(for: state).first { $0.id == entry.id }?.unavailableReason != nil)
        state.modelName = "WF-1000XM3"
        #expect(throws: (any Error).self) { try backup.plan(for: state) }
        state.modelName = backup.model; state.family = .v2
        #expect(throws: (any Error).self) { try backup.plan(for: state) }
    }

    @Test func unavailableValuesAreOmittedAndInvalidRangesCannotBeWritten() throws {
        let state = headset()
        state.upscaling = nil
        let backup = try SettingsBackup.capture(state)
        #expect(!backup.settings.contains { $0.id == "upscaling" })
        #expect(backup.omissions.contains { $0.contains("DSEE: no current value") })
        state.capabilities.equalizer = EqualizerCapability(presets: [EqualizerPreset(id: 0xA1, name: "Custom 1")],
            bandCount: 5, bandRange: -10...10, hasClearBass: true)
        state.equalizerAvailable = true
        let curve = SavedHeadphoneSetting.equalizer(EqualizerState(presetID: 0xA1, bands: [1, 2, 3, 4, 5], clearBass: 2))
        #expect(try curve.changes(for: state) == [.equalizerPreset(0xA1), .equalizerBands(bands: [1, 2, 3, 4, 5], clearBass: 2)])
        #expect(throws: (any Error).self) {
            try SavedHeadphoneSetting.equalizer(EqualizerState(presetID: 0xA1, bands: [99, 2, 3, 4, 5], clearBass: 2)).changes(for: state)
        }
        state.equalizerAvailable = false
        #expect(throws: (any Error).self) { try curve.changes(for: state) }
        #expect(throws: (any Error).self) { try SavedHeadphoneSetting.volume(31).changes(for: state) }
        #expect(throws: (any Error).self) {
            try SavedHeadphoneSetting.noise(NoiseControl(mode: .ambient, ambientLevel: 21, focusOnVoice: false)).changes(for: state)
        }
    }

    @Test func reconnectMustConfirmBeforeAnyLaterSettingIsWritten() async throws {
        let state = headset()
        state.capabilities.autoPause = true; state.autoPause = false
        var backup = try SettingsBackup.capture(state)
        backup.settings = [.upscaling(true), .autoPause(true)]
        let entries = try backup.plan(for: state)
        var writes = 0, reads = 0, reconnects = 0
        var results: [String: SettingsRestoreOutcome] = [:]
        do {
            try await SettingsRestoreExecutor.run(backup: backup, entries: entries, read: { reads += 1; return state },
                write: { _ in writes += 1; return .waitingForReconnect }, reconnect: { reconnects += 1 },
                progress: { id, result in if let result { results[id] = result } })
            Issue.record("An unchanged value after reconnect must fail")
        } catch {}
        #expect(writes == 1 && reads == 2 && reconnects == 1)
        if case .failed = results[entries[0].id] {} else { Issue.record("Missing failed read-back") }
    }

    @Test func successfulReconnectAndFinalVerificationAreRequired() async throws {
        let state = headset()
        var backup = try SettingsBackup.capture(state)
        backup.settings = [.upscaling(true), .connectionPriority(.stableConnection)]
        let entries = try backup.plan(for: state)
        var reads = 0, writes = 0, reconnects = 0
        var results: [String: SettingsRestoreOutcome] = [:]
        try await SettingsRestoreExecutor.run(backup: backup, entries: entries,
            read: { reads += 1; return state },
            write: { entry in
                writes += 1
                if entry.id == "upscaling" { state.upscaling = UpscalingState(enabled: true, active: false); return .confirmed }
                return .waitingForReconnect
            }, reconnect: { reconnects += 1; state.connectionPriority = .stableConnection },
            progress: { id, result in if let result { results[id] = result } })
        #expect(reads == 3 && writes == 2 && reconnects == 1)
        #expect(results.values.allSatisfy { $0 == .confirmed })
    }

    @Test func finalReadDetectsSettingsUndoneByLaterWrites() async throws {
        let state = headset()
        var backup = try SettingsBackup.capture(state)
        backup.settings = [.upscaling(true), .connectionPriority(.stableConnection)]
        let entries = try backup.plan(for: state)
        var writes = 0, reads = 0
        var results: [String: SettingsRestoreOutcome] = [:]
        do {
            try await SettingsRestoreExecutor.run(backup: backup, entries: entries,
                read: { reads += 1; return state },
                write: { entry in
                    writes += 1
                    if entry.id == "upscaling" { state.upscaling = UpscalingState(enabled: true, active: false) }
                    else { state.connectionPriority = .stableConnection; state.upscaling = UpscalingState(enabled: false, active: false) }
                    return .confirmed
                }, reconnect: { Issue.record("Unexpected reconnect") },
                progress: { id, result in if let result { results[id] = result } })
            Issue.record("A later write undid DSEE and must be reported")
        } catch {}
        #expect(writes == 2 && reads == 2)
        if case .failed = results["upscaling"] {} else { Issue.record("Missing final mismatch") }
    }

    @Test func capabilityDriftPreventsAllWritesAndFailureStopsTheSequence() async throws {
        let state = headset()
        var backup = try SettingsBackup.capture(state)
        backup.settings = [.upscaling(true), .connectionPriority(.stableConnection)]
        let entries = try backup.plan(for: state)
        state.capabilities.connectionPriority = false
        var writes = 0
        do {
            try await SettingsRestoreExecutor.run(backup: backup, entries: entries, read: { state },
                write: { _ in writes += 1; return .confirmed }, reconnect: {}, progress: { _, _ in })
            Issue.record("Capability loss must fail before writing")
        } catch {}
        #expect(writes == 0)
        state.capabilities.connectionPriority = true
        do {
            try await SettingsRestoreExecutor.run(backup: backup, entries: entries, read: { state },
                write: { _ in writes += 1; return .failed("Link dropped unexpectedly") }, reconnect: {}, progress: { _, _ in })
            Issue.record("Unexpected disconnect must stop the sequence")
        } catch {}
        #expect(writes == 1)
    }

    @Test func backupRequiresLiveConnectionAndVoiceFocusReadbackIsExact() throws {
        let controller = HeadphoneController()
        controller.startDemo()
        #expect(throws: (any Error).self) { try controller.beginSettingsOperation() }
        #expect(!controller.settingsOperationInProgress)
        let state = headset()
        state.speakToChat = SpeakToChat(enabled: true, sensitivity: .auto, timeout: .standard, voiceFocus: false)
        // Explicit backup restoration includes the V1 flag; ordinary UI changes preserve the current flag.
        #expect(DeviceChange.speakToChatOptions(.auto, .standard, voiceFocus: true).isReflected(in: state) == false)
        #expect(DeviceChange.speakToChatOptions(.auto, .standard).isReflected(in: state) == true)
    }

    @Test func partialRepliesCannotBackUpGuessedEnableValues() throws {
        let state = headset()
        state.settingReadbacks = []; state.upscaling = nil
        state.capabilities.speakToChat = true; state.capabilities.speakToChatOptions = true
        let driver = V1Driver(link: MDRLink(transport: nil), state: state, subscribesToAlerts: false)
        func receive(_ bytes: [UInt8]) { driver.handle(MDRFrame(type: .dataMdr, sequence: 0, payload: bytes)) }
        receive([0x15, 0x00, 0x00, 0x01]) // Activity is not the DSEE enable preference.
        receive([0xFB, 0x05, 0x00, 0x00, 0x01, 0x01]) // Extended options don't report the enable switch.
        let partial = try SettingsBackup.capture(state)
        #expect(!partial.settings.contains { $0.id == "upscaling" || $0.id == "speakToChat" })
        #expect(throws: (any Error).self) { try SavedHeadphoneSetting.upscaling(true).changes(for: state) }
        receive([0xE7, 0x02, 0x00, 0x01])
        receive([0xF7, 0x05, 0x01, 0x01])
        let complete = try SettingsBackup.capture(state)
        #expect(complete.settings.contains(.upscaling(true)))
        #expect(complete.settings.contains(.speakToChat(SpeakToChat(enabled: true, sensitivity: .auto, timeout: .standard, voiceFocus: true))))
    }

    @Test func listeningModeRequiresEverySupportedModeReply() {
        let state = DeviceState()
        state.capabilities.listeningMode = ListeningModeCapability(backgroundMusic: true, cinema: true)
        let driver = V2Driver(link: MDRLink(transport: nil), state: state, subscribesToAlerts: false)
        driver.handle(MDRFrame(type: .dataMdr, sequence: 0, payload: [0xE7, 0x09, 0x01, 0x00]))
        #expect(state.listeningMode == nil) // Cinema has not replied; Standard would be a guess.
        driver.handle(MDRFrame(type: .dataMdr, sequence: 0, payload: [0xE7, 0x04, 0x01]))
        #expect(state.listeningMode == .standard)
        driver.handle(MDRFrame(type: .dataMdr, sequence: 0, payload: [0xE7, 0x09, 0x00, 0xFF]))
        #expect(state.listeningMode == .standard) // Invalid room cannot invent My Room.
    }
}
