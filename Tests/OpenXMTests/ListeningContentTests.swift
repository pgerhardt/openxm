import Foundation
import Testing
@testable import OpenXM

@MainActor struct ListeningContentTests {
    private let now = Date(timeIntervalSince1970: 1_793_340_000)
    private var utc: Calendar { AppDataHistoryDay.calendar(timeZone: .gmt) }
    private var song: ListeningContent {
        .init(metadata: .init(title: "Beyond Beliefs 🎵", album: "Begin Again", artist: "Ben Böhmer"), source: .headphones)
    }
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("content-\(UUID()).json") }
    private func record(_ offset: TimeInterval = 0, content: ListeningContent? = nil) -> ListeningContentRecord {
        .init(interval: .init(model: "WH-1000XM3", startedAt: now.addingTimeInterval(offset),
                             endedAt: now.addingTimeInterval(offset + 15), calendar: utc), content: content ?? song)
    }
    private func playback(at date: Date? = nil) -> NowPlaying {
        var value = NowPlaying(); value.receivePlaybackStatus(.playing, at: date ?? now)
        return value
    }

    @Test func separateOptInAndUnicodeRoundTripWithoutPrivateIdentifiers() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let store = ListeningContentHistory(fileURL: url, calendar: utc, now: now)
        func sample(_ time: TimeInterval) { store.sample(device: "private-address", model: "WH-1000XM3", content: song, at: now.addingTimeInterval(time)) }
        sample(0); sample(15)
        #expect(!store.enabled && store.records.isEmpty && !FileManager.default.fileExists(atPath: url.path))
        store.setEnabled(true); sample(20); sample(35)
        store.pause(device: "private-address", model: "WH-1000XM3", at: now.addingTimeInterval(40))
        #expect(store.records.count == 1 && store.records[0].interval.seconds == 20 && store.activeRecordID == nil)
        let saved = try Data(contentsOf: url)
        #expect(!String(decoding: saved, as: UTF8.self).contains("private-address"))
        let loaded = ListeningContentHistory(fileURL: url, calendar: utc, now: now)
        #expect(loaded.records == store.records && loaded.enabled && loaded.activeRecordID == nil)
        #expect(Array(loaded.records[0].content.metadata.artist!.utf8) == Array("Ben Böhmer".utf8))
        var decomposed = song; decomposed.metadata.artist = "Ben Bo\u{308}hmer"
        let roundtrip = try JSONDecoder().decode(ListeningContent.self, from: JSONEncoder().encode(decomposed))
        #expect(Array(roundtrip.metadata.artist!.utf8) == Array(decomposed.metadata.artist!.utf8))
        loaded.setEnabled(false)
        loaded.sample(device: "private-address", model: "WH-1000XM3", content: song, at: now.addingTimeInterval(45))
        #expect(loaded.records == store.records)
    }

    @Test func trackChangesUnknownSourcesSleepAndDeviceSwitchesEndContinuity() {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let store = ListeningContentHistory(fileURL: url, calendar: utc, now: now); store.setEnabled(true)
        var next = song; next.metadata.title = "Another track"; next.metadata.album = nil
        func sample(_ time: TimeInterval, _ content: ListeningContent?, _ device: String? = "A") {
            store.sample(device: device, model: "WH-1000XM3", content: content, at: now.addingTimeInterval(time))
        }
        sample(0, song); sample(15, song); sample(20, next); sample(25, next)
        #expect(store.records.count == 2 && store.records[0].interval.seconds == 5 && store.records[1].interval.seconds == 20)
        #expect(store.records[0].content.metadata.album == nil)
        sample(30, nil); sample(35, song); sample(50, song)
        sample(55, song, "B"); sample(70, song, "B")
        sample(1000, song, "B"); sample(1015, song, "B"); sample(1020, nil, nil)
        #expect(store.records.count == 5 && store.records.reduce(0) { $0 + $1.interval.seconds } == 70)
        #expect(store.activeRecordID == nil)
        store.pause(device: "B", model: "WH-1000XM3", at: now.addingTimeInterval(1030))
        #expect(store.records.reduce(0) { $0 + $1.interval.seconds } == 70)
    }

    @Test func midnightSplittingAndClearingKeepPreference() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let midnight = utc.startOfDay(for: now)
        let store = ListeningContentHistory(fileURL: url, calendar: utc, now: now); store.setEnabled(true)
        for offset: TimeInterval in [-10, 5, 20] {
            store.sample(device: "A", model: "WH-1000XM3", content: song, at: midnight.addingTimeInterval(offset))
        }
        #expect(store.records.map { $0.interval.seconds } == [20, 10])
        try ListeningContentRecord.validate(store.records)
        store.clear()
        #expect(store.records.isEmpty && store.enabled && store.activeRecordID == nil)
    }

    @Test func attributionRejectsUnverifiedRoutesCallsPausesAndExpiredMetadata() {
        var value = playback()
        let item = SystemNowPlaying.Item(bundleIdentifier: "com.example.player", title: "Track", artist: "Böhmer", album: nil,
                                        playing: true, artworkData: nil, processIdentifier: 123)
        #expect(ListeningContentAttribution.mac(item, playback: value, routeMatches: false, at: now) == nil)
        #expect(ListeningContentAttribution.mac(item, playback: value, routeMatches: true, at: now)?.source == .macApp)
        value.receiveMetadata(song.metadata, at: now)
        #expect(ListeningContentAttribution.headphone(value, at: now)?.metadata == song.metadata)
        value.receivePlaybackStatus(.playing, at: now.addingTimeInterval(90))
        #expect(ListeningContentAttribution.headphone(value, at: now.addingTimeInterval(90)) == nil)
        value.receivePlaybackStatus(.paused, at: now)
        #expect(ListeningContentAttribution.mac(item, playback: value, routeMatches: true, at: now) == nil)
        value.receivePlaybackStatus(.playing, music: false, at: now)
        #expect(ListeningContentAttribution.mac(item, playback: value, routeMatches: true, at: now) == nil)
        #expect(ListeningContentAttribution.mac(item, playback: playback(), routeMatches: true, at: now.addingTimeInterval(90)) == nil)
    }

    @Test func processIdentityAndOutputUIDMustMatchExactly() throws {
        let bytes = Data("{\"processIdentifier\":123,\"bundleIdentifier\":\"com.example.player\",\"title\":\"Track\",\"playing\":true}".utf8)
        let item = try JSONDecoder().decode(SystemNowPlaying.Item.self, from: bytes)
        #expect(item.processIdentifier == 123)
        var other = item; other.processIdentifier = 124
        #expect(!item.sameContentAndPlayer(as: other))
        #expect(PlayerAudioRoute.matchesUID("AA-BB-CC-DD-EE-FF:output", headphoneAddress: "aa:bb:cc:dd:ee:ff"))
        for uid in ["AA-BB-CC-DD-EE-00:output", "AA-BB-CC-DD-EE-FF:input", "AggregateDevice", "output", "AA-BB-CC-DD-EE-FF"] {
            #expect(!PlayerAudioRoute.matchesUID(uid, headphoneAddress: "aa:bb:cc:dd:ee:ff"))
        }
        #expect(!PlayerAudioRoute.matches(processIdentifier: nil, bundleIdentifier: "", headphoneAddress: ""))
    }

    @Test func mergeExtendsMatchingSnapshotRejectsRewrittenContentAndRetainsBounds() throws {
        let first = record(); var longer = first; longer.interval.endedAt = now.addingTimeInterval(30)
        let merged = try ListeningContentRecord.merge([longer], into: [first], calendar: utc, now: now)
        #expect(merged == [longer])
        #expect(try ListeningContentRecord.merge([first], into: merged, calendar: utc, now: now) == merged)
        var wrong = first; wrong.content.metadata.artist = "Someone else"
        #expect(throws: (any Error).self) { try ListeningContentRecord.merge([wrong], into: [first], calendar: utc, now: now) }
        wrong = first; wrong.interval.startedAt = now.addingTimeInterval(1)
        #expect(throws: (any Error).self) { try ListeningContentRecord.merge([wrong], into: [first], calendar: utc, now: now) }
        let old = record(-366 * 86_400)
        let full = (0..<5_001).map { _ in record() }
        let retained = ListeningContentRecord.retained(full + [old], calendar: utc, now: now)
        #expect(retained.count == 5_000 && !retained.contains(old))
        #expect(throws: (any Error).self) { try ListeningContentRecord.validate(full) }
        #expect(throws: (any Error).self) { try ListeningContentRecord.validate([first, first]) }
    }

    @Test func corruptStorageAndInvalidTextArePreserved() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("{\"version\":999,\"enabled\":true,\"records\":[]}".utf8); try bytes.write(to: url)
        let store = ListeningContentHistory(fileURL: url, calendar: utc, now: now)
        store.setEnabled(true); store.sample(device: "A", model: "WH-1000XM3", content: song, at: now)
        #expect(!store.enabled && store.saveError != nil)
        #expect(try Data(contentsOf: url) == bytes)
        var invalid = song; invalid.metadata.title = "  "
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = song; invalid.metadata.artist = String(repeating: "ö", count: 257)
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = song; invalid.source = .macApp
        #expect(throws: (any Error).self) { try invalid.validate() }
        #expect(throws: (any Error).self) { try store.checkedBackupFile() }
    }

    @Test func fullSizedHistoryAndBackupRemainBoundedAndOldFormatsCannotCarrySongData() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let store = ListeningContentHistory(fileURL: url, calendar: utc, now: now)
        var wide = song
        wide.metadata = .init(title: String(repeating: "T", count: 512), album: String(repeating: "A", count: 512), artist: String(repeating: "ö", count: 256))
        let values = (0..<5_000).map { _ in record(content: wide) }.sorted(by: ListeningContentRecord.newestFirst)
        #expect(try store.encodedRestoration(values).count < ListeningContentHistory.maximumBytes)
        var backup = AppDataBackup(createdAt: now, listeningContent: values)
        let data = try backup.encoded()
        #expect(data.count < AppDataBackup.maximumBytes)
        #expect(try AppDataBackup.decode(data).listeningContent == values)
        for version in [1, 2] {
            backup.version = version
            #expect(throws: (any Error).self) { try backup.encoded() }
        }
    }

    @Test func backupSelectionRestoreAndStaleReviewPreserveLocalOptIn() throws {
        let directory = file().deletingPathExtension()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = HeadphoneController()
        let scenes = SceneStore(controller: controller, fileURL: directory.appendingPathComponent("scenes.json"))
        let history = ListeningHistory(fileURL: directory.appendingPathComponent("history.json"), calendar: utc, now: now)
        let content = ListeningContentHistory(fileURL: directory.appendingPathComponent("content.json"), calendar: utc, now: now)
        let workflow = AppDataBackupWorkflow(controller: controller, scenes: scenes, history: history, contentHistory: content)
        #expect(try workflow.capture(now: now).listeningContent == nil)
        let backupURL = directory.appendingPathComponent("backup.json")
        try AppDataBackup(createdAt: now, listeningContent: [record()]).encoded().write(to: backupURL)
        workflow.load(backupURL); workflow.review(now: now)
        #expect(workflow.canRestore)
        content.setEnabled(true); workflow.restore()
        #expect(workflow.error?.contains("changed after review") == true && content.records.isEmpty)
        content.setEnabled(false); workflow.review(now: now); workflow.restore()
        #expect(workflow.error == nil && content.records.count == 1 && !content.enabled && history.days.isEmpty)
        workflow.exportScenes = false; workflow.exportHistory = false; workflow.exportContent = true
        let exported = try workflow.capture(now: now)
        #expect(exported.listeningContent == content.records && exported.history == nil)
        #expect(!String(decoding: try exported.encoded(), as: UTF8.self).contains("enabled"))
        var legacy = AppDataBackup(createdAt: now, history: []); legacy.version = 1
        try legacy.encoded().write(to: backupURL)
        workflow.load(backupURL); workflow.review(now: now); workflow.restore()
        #expect(!workflow.restoreContent && content.records.count == 1 && !content.enabled)
    }

    @Test func thirdFileFailureRollsBackScenesHistoryAndContentBeforePublishing() throws {
        let directory = file().deletingPathExtension(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = HeadphoneController()
        let scenes = SceneStore(controller: controller, fileURL: directory.appendingPathComponent("scenes.json"))
        let history = ListeningHistory(fileURL: directory.appendingPathComponent("history.json"), calendar: utc, now: now)
        let content = ListeningContentHistory(fileURL: directory.appendingPathComponent("content.json"), calendar: utc, now: now)
        history.setEnabled(false); content.setEnabled(false)
        let originalHistory = try Data(contentsOf: history.storageLocation), originalContent = try Data(contentsOf: content.storageLocation)
        let backupURL = directory.appendingPathComponent("backup.json")
        try AppDataBackup(createdAt: now, scenes: [], history: [.init(date: "2026-10-28", model: "WH-1000XM3", seconds: 50)],
                          listeningContent: [record()]).encoded().write(to: backupURL)
        let workflow = AppDataBackupWorkflow(controller: controller, scenes: scenes, history: history, contentHistory: content)
        workflow.load(backupURL); workflow.review(now: now)
        #expect(workflow.canRestore)
        workflow.restore { data, url in
            try data.write(to: url, options: .atomic)
            if url == content.storageLocation { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(workflow.error != nil && history.days.isEmpty && content.records.isEmpty && scenes.scenes.isEmpty)
        #expect(try Data(contentsOf: history.storageLocation) == originalHistory)
        #expect(try Data(contentsOf: content.storageLocation) == originalContent)
        #expect(!FileManager.default.fileExists(atPath: scenes.storageLocation.path))
    }
}
