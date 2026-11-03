import Foundation
import Testing
@testable import OpenXM

@MainActor struct CodecTransportLifecycleTests {
    private func fixture(crash: Bool = false, disconnected: Bool = false, pauseBlocked: Bool = false,
                         preferences: UserDefaults? = nil) throws -> (CodecTransportController, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenXM-codec-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-helper")
        let script = """
        #!/bin/sh
        if [ "$1" = "--inspect" ]; then
          echo '{"event":"inspection","driverInstalled":true}'
          exit 0
        fi
        if [ "$1" = "--recover" ]; then
          \(pauseBlocked ? """
          echo "${3:-automatic}" >> '\(directory.appendingPathComponent("recoveries.txt").path)'
          if [ "${3:-}" != "--allow-playing" ]; then
            echo '{"event":"recovery","routeRestored":false,"playbackBlocked":true,"message":"Media pause could not be confirmed. Audio is kept silent."}'
            exit 0
          fi
          rm -f "$2"
          """ : "")
          echo '{"event":"recovery","routeRestored":true}'
          exit 0
        fi
        printf '%s\\n' "$5" > '\(directory.appendingPathComponent("startup-settings.json").path)'
        echo '{"event":"status","phase":"streaming","requested":"ldac","activeCodec":"ldac","sampleRate":44100,"routed":true,"recentKbps":618.4,"targetKbps":606,"volumeSynced":true,"volume":33}'
        \(pauseBlocked ? "touch '\(directory.appendingPathComponent("route.plist").path)'" : "")
        \(crash ? "sleep 0.2; exit 9" : "")
        \(disconnected ? """
        sleep 0.1
        echo '{"event":"status","phase":"stopping","requested":"ldac","message":"Headphone audio disconnected."}'
        sleep 0.4
        \(pauseBlocked ? "echo '{\"event\":\"stopped\",\"routeRestored\":false,\"playbackBlocked\":true,\"message\":\"Media pause could not be confirmed. Audio is kept silent.\"}'" : "echo '{\"event\":\"stopped\",\"routeRestored\":true,\"message\":\"Headphone audio disconnected. Using Mac speakers.\"}'")
        exit 1
        """ : "")
        while IFS= read -r command; do
          case "$command" in
            *stop*)
              echo "$command" > '\(directory.appendingPathComponent("stop.json").path)'
              break ;;
            *volume*)
              echo "$command" >> '\(directory.appendingPathComponent("commands.jsonl").path)'
              sleep 0.1
              echo '{"event":"status","phase":"streaming","requested":"ldac","activeCodec":"ldac","sampleRate":44100,"routed":true,"volumeSynced":true,"volume":25}'
              ;;
            *select*)
              echo "$command" >> '\(directory.appendingPathComponent("commands.jsonl").path)'
              case "$command" in
                *'"codec":"ldac"'*)
                  echo '{"event":"status","phase":"streaming","requested":"ldac","activeCodec":"ldac","sampleRate":44100,"routed":true,"settingsRevision":0}'
                  sleep 0.2
                  echo '{"event":"status","phase":"streaming","requested":"ldac","activeCodec":"ldac","sampleRate":48000,"routed":true,"settingsRevision":1,"ldacQuality":0,"fastRecovery":false,"targetKbps":990}'
                  ;;
                *)
                  sleep 0.05
                  echo '{"event":"status","phase":"streaming","requested":"aptx","activeCodec":"aptx","sampleRate":44100,"routed":true,"recentKbps":353,"targetKbps":352.8,"settingsRevision":1}'
                  ;;
              esac
              ;;
          esac
        done
        echo '{"event":"stopped","routeRestored":true}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (CodecTransportController(executable: executable, journal: directory.appendingPathComponent("route.plist"), preferences: preferences), directory)
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        // Utility calls have a five-second bound. Allow that bound plus scheduling
        // overhead when several process-backed lifecycle tests run together.
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func automaticClosesHelperAndClearsNegotiatedEvidence() async throws {
        let (transport, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transport.refreshAvailability()
        #expect(await until { transport.driverInstalled })
        transport.select(.ldac, address: "AA:BB:CC:DD:EE:FF")
        #expect(await until { transport.hasConfirmedSession })
        #expect(transport.activeCodec == .ldac && transport.routed)
        #expect(transport.recentKbps == 618.4 && transport.targetKbps == 606)
        #expect(transport.volumeSynced)
        #expect(transport.confirmedVolume == 33 && transport.volumePercent == 26)
        transport.select(.aptX, address: "AA:BB:CC:DD:EE:FF")
        #expect(transport.switchingCodec && transport.headline == "Switching to aptX…")
        #expect(transport.recentKbps == nil && transport.targetKbps == nil)
        #expect(!transport.volumeSynced)
        #expect(transport.confirmedVolume == nil)
        #expect(await until { transport.activeCodec == .aptX })
        #expect(!transport.switchingCodec)
        #expect(transport.recentKbps == 353 && transport.targetKbps == 352.8)
        var stopped = false
        transport.stop { stopped = true }
        #expect(transport.requested == .automatic && transport.activeCodec == nil)
        #expect(transport.recentKbps == nil && transport.targetKbps == nil)
        #expect(await until { stopped })
        #expect(transport.phase == .automatic && !transport.isEngaged)
        #expect(transport.message == nil)
    }

    @Test func crashDoesNotLeaveAnActiveCodecOrRequestedPreference() async throws {
        let (transport, directory) = try fixture(crash: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        transport.refreshAvailability()
        #expect(await until { transport.driverInstalled })
        transport.select(.ldac, address: "AA:BB:CC:DD:EE:FF")
        #expect(await until { transport.phase == .failed })
        #expect(transport.requested == .automatic)
        #expect(transport.activeCodec == nil && !transport.routed)
        #expect(!transport.volumeSynced)
        #expect(transport.confirmedVolume == nil)
        #expect(transport.recentKbps == nil && transport.targetKbps == nil)
        #expect(transport.message?.contains("unexpectedly") == true)
    }

    @Test func appVolumeWaitsForHelperAcknowledgementAndStopsWithSession() async throws {
        let (transport, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transport.setVolumePercent(20) // No active connection: no command.
        transport.refreshAvailability()
        #expect(await until { transport.driverInstalled })
        transport.select(.ldac, address: "AA:BB:CC:DD:EE:FF")
        #expect(await until { transport.canSetVolume })
        transport.setVolumePercent(-1); transport.setVolumePercent(101)
        transport.setVolumePercent(20)
        #expect(transport.confirmedVolume == 33) // Sending is not confirmation.
        #expect(await until { transport.confirmedVolume == 25 })
        #expect(transport.volumePercent == 20)
        let data = try Data(contentsOf: directory.appendingPathComponent("commands.jsonl"))
        let command = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(command["command"] as? String == "volume")
        #expect(command["volume"] as? Int == 25)
        var stopped = false
        transport.stop { stopped = true }
        #expect(!transport.canSetVolume && transport.volumePercent == nil)
        #expect(await until { stopped })
    }

    @Test func advancedSelectionRequiresFreshConfigurationEvidence() async throws {
        let (transport, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        transport.refreshAvailability()
        #expect(await until { transport.driverInstalled })
        transport.select(.ldac, address: "AA:BB:CC:DD:EE:FF")
        #expect(await until { transport.hasConfirmedSession })
        let settings = CodecAdvancedSettings(ldacQuality: .high, sampleRate: .hz48000, fastRecovery: true)
        transport.setAdvancedSettings(settings)
        #expect(!transport.hasConfirmedSession && transport.activeLDACQuality == nil && transport.sampleRate == nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(!transport.hasConfirmedSession) // Earlier same-codec status cannot confirm new options.
        #expect(await until { transport.hasConfirmedSession })
        #expect(transport.activeLDACQuality == .high && transport.sampleRate == 48000 && transport.targetKbps == 990)
        let data = try Data(contentsOf: directory.appendingPathComponent("commands.jsonl"))
        let command = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sent = try #require(command["settings"] as? [String: Any])
        #expect(sent["ldacQuality"] as? Int == 0 && sent["sampleRate"] as? Int == 48000)
        #expect(sent["fastRecovery"] as? Bool == true && sent["revision"] as? Int == 1)
        var stopped = false; transport.stop { stopped = true }
        #expect(await until { stopped })
        #expect(transport.activeLDACQuality == nil && transport.activeFastRecovery == nil)
    }

    @Test func advancedPreferencesLoadWithoutStartingBeforeHeadphonesConnect() throws {
        let suite = "OpenXM-codec-preferences-test-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = CodecTransportController(executable: nil, preferences: preferences)
        let settings = CodecAdvancedSettings(ldacQuality: .medium, sampleRate: .hz44100, fastRecovery: true)
        first.setAdvancedSettings(settings)
        let restored = CodecTransportController(executable: nil, preferences: preferences)
        #expect(restored.advancedSettings == settings)
        #expect(restored.requested == .automatic && !restored.isEngaged)
    }

    @Test func unexpectedLossClearsStreamingWhileHelperRestoresSpeakers() async throws {
        let (transport, directory) = try fixture(disconnected: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var notices: [String] = []
        transport.onRouteNotice = { notices.append($0) }
        transport.refreshAvailability()
        #expect(await until { transport.driverInstalled })
        transport.select(.ldac, address: "AA:BB:CC:DD:EE:FF")
        #expect(await until { transport.hasConfirmedSession })
        #expect(await until { transport.phase == .stopping })
        #expect(transport.requested == .automatic && transport.activeCodec == nil && !transport.routed)
        #expect(!transport.canSetVolume && transport.recentKbps == nil)
        #expect(await until { transport.phase == .failed })
        #expect(transport.message == "Headphone audio disconnected. Using Mac speakers.")
        #expect(notices == ["Headphone audio disconnected. Using Mac speakers."])
        #expect(!transport.isEngaged && !transport.switchingCodec)
    }

    @Test func blockedPauseRequiresExplicitRecoveryAndCannotRestartCustomAudio() async throws {
        let (transport, directory) = try fixture(disconnected: true, pauseBlocked: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        transport.refreshAvailability()
        #expect(await until { transport.driverInstalled })
        transport.select(.ldac, address: "AA:BB:CC:DD:EE:FF")
        #expect(await until { transport.phase == .failed && !transport.recoveringOutput })
        #expect(transport.playbackBlocked && transport.message?.contains("kept silent") == true)
        let journal = directory.appendingPathComponent("route.plist")
        #expect(FileManager.default.fileExists(atPath: journal.path))
        transport.select(.aptX, address: "AA:BB:CC:DD:EE:FF")
        #expect(await until { !transport.recoveringOutput })
        #expect(!transport.isEngaged && transport.requested == .automatic && transport.playbackBlocked)
        let attempts = try String(contentsOf: directory.appendingPathComponent("recoveries.txt"), encoding: .utf8)
        #expect(!attempts.contains("--allow-playing"))
        transport.recoverIfNeeded(allowPlaying: true)
        #expect(await until { !transport.recoveringOutput })
        #expect(!transport.playbackBlocked && !FileManager.default.fileExists(atPath: journal.path))
        #expect(transport.message == "Audio output restored.")
        #expect(try String(contentsOf: directory.appendingPathComponent("recoveries.txt"), encoding: .utf8).hasSuffix("--allow-playing\n"))
    }

    @Test func onlyUnexpectedStopsRequestAutomaticPause() async throws {
        for unexpected in [false, true] {
            let (transport, directory) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            transport.refreshAvailability()
            #expect(await until { transport.driverInstalled })
            transport.select(.ldac, address: "AA:BB:CC:DD:EE:FF")
            #expect(await until { transport.hasConfirmedSession })
            var stopped = false
            transport.stop(reason: unexpected ? "Transport failed" : "The selected headphones changed.", unexpectedLoss: unexpected) { stopped = true }
            #expect(await until { stopped })
            let data = try Data(contentsOf: directory.appendingPathComponent("stop.json"))
            let command = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(command["unexpected"] as? Bool == unexpected)
        }
    }

    @Test func immediateExitCannotOvertakeFinalRecoveryEvidence() async throws {
        for _ in 0..<8 {
            let (transport, directory) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            transport.refreshAvailability()
            #expect(await until { transport.driverInstalled })
            transport.select(.ldac, address: "AA:BB:CC:DD:EE:FF")
            #expect(await until { transport.hasConfirmedSession })
            var stopped = false
            transport.stop { stopped = true }
            #expect(await until { stopped })
            #expect(transport.phase == .automatic && transport.message == nil)
        }
    }

    @Test func savedCodecSurvivesShutdownAndRestoresOnceForTheSameHeadphones() async throws {
        let suite = "OpenXM-codec-restore-test-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let address = "AA:BB:CC:DD:EE:FF"
        let (first, directory) = try fixture(preferences: preferences)
        defer { try? FileManager.default.removeItem(at: directory) }
        first.refreshAvailability()
        try #require(await until { first.driverInstalled })
        let advanced = CodecAdvancedSettings(ldacQuality: .high, sampleRate: .hz48000, fastRecovery: true)
        first.setAdvancedSettings(advanced)
        first.select(.ldac, address: address)
        try #require(await until { first.hasConfirmedSession })
        var stopped = false
        first.stop { stopped = true } // Quit/sleep/disconnect cleanup is not a preference change.
        try #require(await until { stopped })
        #expect(first.preferredCodec(for: address) == .ldac)
        #expect(first.requested == .automatic && first.activeCodec == nil)

        let restored = CodecTransportController(executable: directory.appendingPathComponent("fake-helper"),
            journal: directory.appendingPathComponent("route.plist"), preferences: preferences)
        #expect(restored.preferredCodec(for: "aa-bb-cc-dd-ee-ff") == .ldac)
        #expect(restored.preferredCodec(for: "11:22:33:44:55:66") == .automatic)
        #expect(restored.advancedSettings == advanced && !restored.isEngaged)
        #expect(restored.takeLaunchSelection(address: address) == nil) // Driver check is pending.
        restored.refreshAvailability()
        try #require(await until { restored.driverInstalled })
        #expect(restored.takeLaunchSelection(address: "11:22:33:44:55:66") == nil)
        let selection = try #require(restored.takeLaunchSelection(address: address))
        #expect(selection == .ldac)
        #expect(restored.takeLaunchSelection(address: address) == nil)
        restored.select(selection, address: address)
        try #require(await until { restored.hasConfirmedSession })
        let settingsData = try Data(contentsOf: directory.appendingPathComponent("startup-settings.json"))
        let settings = try #require(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        #expect(settings["sampleRate"] as? Int == 48000)
        #expect(settings["ldacQuality"] as? Int == 0 && settings["fastRecovery"] as? Bool == true)
        restored.select(.automatic, address: address)
        try #require(await until { !restored.isEngaged })
        let automatic = CodecTransportController(executable: nil, preferences: preferences)
        #expect(automatic.preferredCodec(for: address) == .automatic)
        #expect(automatic.takeLaunchSelection(address: address) == nil)
        #expect(automatic.advancedSettings == advanced)
    }

    @Test func savedCodecFailureDoesNotRetryOrEraseThePreference() async throws {
        let suite = "OpenXM-codec-failed-restore-test-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let address = "AA:BB:CC:DD:EE:FF"
        preferences.set([address: "ldac"], forKey: "preferredCodecs")
        let (transport, directory) = try fixture(crash: true, preferences: preferences)
        defer { try? FileManager.default.removeItem(at: directory) }
        transport.refreshAvailability()
        try #require(await until { transport.driverInstalled })
        let selection = try #require(transport.takeLaunchSelection(address: address))
        transport.select(selection, address: address)
        try #require(await until { transport.phase == .failed })
        #expect(transport.activeCodec == nil && transport.requested == .automatic)
        #expect(transport.takeLaunchSelection(address: address) == nil)
        #expect(transport.preferredCodec(for: address) == .ldac)
        let nextLaunch = CodecTransportController(executable: nil, preferences: preferences)
        #expect(nextLaunch.preferredCodec(for: address) == .ldac)
    }

    @Test func routeRecoveryCancelsLaunchRestorationEvenAfterExplicitRecovery() async throws {
        let suite = "OpenXM-codec-protected-restore-test-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let address = "AA:BB:CC:DD:EE:FF"
        preferences.set([address: "ldac"], forKey: "preferredCodecs")
        let (transport, directory) = try fixture(pauseBlocked: true, preferences: preferences)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("route.plist"))
        transport.refreshAvailability()
        try #require(await until { transport.driverInstalled })
        #expect(transport.takeLaunchSelection(address: address) == nil)
        transport.recoverIfNeeded()
        #expect(transport.takeLaunchSelection(address: address) == nil)
        try #require(await until { !transport.recoveringOutput })
        #expect(transport.playbackBlocked)
        transport.recoverIfNeeded(allowPlaying: true)
        try #require(await until { !transport.recoveringOutput })
        #expect(transport.canStartSession)
        #expect(transport.takeLaunchSelection(address: address) == nil)
        #expect(transport.preferredCodec(for: address) == .ldac)
    }

    @Test func invalidSavedCodecsDefaultToAutomaticWithoutDiscardingOtherHeadphones() throws {
        let suite = "OpenXM-codec-invalid-preferences-test-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(["AA:BB:CC:DD:EE:FF": "ldac", "11:22:33:44:55:66": "unsupported",
                         "22:33:44:55:66:77": 12] as [String: Any], forKey: "preferredCodecs")
        let transport = CodecTransportController(executable: nil, preferences: preferences)
        #expect(transport.preferredCodec(for: "AA:BB:CC:DD:EE:FF") == .ldac)
        #expect(transport.preferredCodec(for: "11:22:33:44:55:66") == .automatic)
        #expect(transport.preferredCodec(for: "22:33:44:55:66:77") == .automatic)
        transport.select(.automatic, address: "11:22:33:44:55:66")
        #expect(transport.preferredCodec(for: "AA:BB:CC:DD:EE:FF") == .ldac)
        #expect(transport.preferredCodec(for: nil) == .automatic)
    }
}
