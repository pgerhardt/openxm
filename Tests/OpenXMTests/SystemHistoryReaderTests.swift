import Foundation
import Testing
@testable import OpenXM

@MainActor struct SystemHistoryReaderTests {
    private func payload(title: String = "Unicode 🎵", artist: String? = "Böhmer", pid: Int = 123) throws -> Data {
        var value: [String: Any] = ["bundleIdentifier": "com.example.player", "processIdentifier": pid,
                                    "title": title, "playing": true]
        if let artist { value["artist"] = artist }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func receive(_ value: Data, by reader: SystemNowPlaying) throws {
        let payload = try JSONSerialization.jsonObject(with: value)
        reader.consume(try JSONSerialization.data(withJSONObject: ["type": "data", "diff": false, "payload": payload]))
    }

    private func fixture(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-reader-\(UUID()).json")
        try data.write(to: url)
        return url
    }

    @Test func freshHelperSnapshotMatchesStreamAndCanBeReadAgain() async throws {
        let data = try payload(), url = try fixture(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = SystemNowPlaying(historyProcessFactory: {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/cat"); process.arguments = [url.path]
            return process
        })
        try receive(data, by: reader)
        for _ in 0..<2 {
            guard case .ready(let value) = await reader.readHistorySnapshot() else { Issue.record("A matching fresh helper snapshot was rejected"); return }
            #expect(value.title == "Unicode 🎵" && value.artist == "Böhmer" && value.processIdentifier == 123)
        }
    }

    @Test func changedPlayerAndMissingFieldsAreNotMixedWithStreamMetadata() async throws {
        let original = try payload(), url = try fixture(payload(artist: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = SystemNowPlaying(historyProcessFactory: {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/cat"); process.arguments = [url.path]
            return process
        })
        try receive(original, by: reader)
        guard case .changed = await reader.readHistorySnapshot() else { Issue.record("Missing artist inherited old metadata"); return }
        try payload(pid: 124).write(to: url)
        guard case .changed = await reader.readHistorySnapshot() else { Issue.record("A different process was attributed to the old player"); return }
        try Data("not JSON".utf8).write(to: url)
        guard case .unavailable(.invalidResponse) = await reader.readHistorySnapshot() else { Issue.record("Malformed helper output was accepted"); return }
    }

    @Test func changedStreamDuringAReadAndCancelledReadsDoNotPublish() async throws {
        let original = try payload(), url = try fixture(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = SystemNowPlaying(historyProcessFactory: {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", "select undef, undef, undef, 0.2; open my $f, '<', $ARGV[0] or die; local $/; print <$f>;", url.path]
            return process
        })
        try receive(original, by: reader)
        let changed = Task { await reader.readHistorySnapshot() }
        try await Task.sleep(for: .milliseconds(50))
        try receive(payload(title: "New track"), by: reader)
        guard case .changed = await changed.value else { Issue.record("A late read overwrote the newer track"); return }
        try receive(original, by: reader)
        let cancelled = Task { await reader.readHistorySnapshot() }
        try await Task.sleep(for: .milliseconds(50)); cancelled.cancel()
        guard case .changed = await cancelled.value else { Issue.record("A cancelled read published metadata"); return }
    }

    @Test func unavailableReadsDistinguishMissingIdentityAndProcessFailures() async throws {
        let reader = SystemNowPlaying(historyProcessFactory: { nil })
        guard case .unavailable(.noPlayer) = await reader.readHistorySnapshot() else { Issue.record("Missing player was not diagnosed"); return }
        var withoutPID = try JSONSerialization.jsonObject(with: payload()) as! [String: Any]
        withoutPID.removeValue(forKey: "processIdentifier")
        try receive(JSONSerialization.data(withJSONObject: withoutPID), by: reader)
        guard case .unavailable(.missingProcess) = await reader.readHistorySnapshot() else { Issue.record("Missing process identity was not diagnosed"); return }
        try receive(payload(), by: reader)
        guard case .unavailable(.missingHelper) = await reader.readHistorySnapshot() else { Issue.record("Missing helper was not diagnosed"); return }

        for (executable, arguments, reason) in [
            ("/not/a/media-reader", [], SystemNowPlaying.HistoryReadFailure.launchFailed),
            ("/usr/bin/perl", ["-e", "exit 7"], .helperFailed(7)),
            ("/usr/bin/perl", ["-e", "print 'x' x 16385"], .oversized)
        ] {
            let failing = SystemNowPlaying(historyProcessFactory: {
                let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                return process
            })
            try receive(payload(), by: failing)
            guard case .unavailable(let actual) = await failing.readHistorySnapshot() else { Issue.record("Failed process was accepted"); continue }
            #expect(actual == reason)
        }
    }
}
