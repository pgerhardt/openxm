import Foundation
import Testing
@testable import OpenXM

@MainActor struct AppDataBackupTests {
    private let now = Date(timeIntervalSince1970: 1_793_340_000)
    private var utc: Calendar { AppDataHistoryDay.calendar(timeZone: TimeZone(secondsFromGMT: 0)!) }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openxm-app-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scene(_ name: String = "Synthetic scene", trigger: SceneTrigger = .onConnect) -> SoundScene {
        SoundScene(name: name, symbol: "headphones", tint: .sage, upscaling: true, trigger: trigger)
    }

    @Test func portableRoundTripPreservesConfigurationAndOmitsRunResults() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = HeadphoneController()
        let store = SceneStore(controller: controller, fileURL: directory.appendingPathComponent("scenes.json"))
        let history = ListeningHistory(fileURL: directory.appendingPathComponent("history.json"), calendar: utc, now: now)
        var saved = scene(trigger: .location(.init(name: "Synthetic place", center: .init(latitude: 0, longitude: 0), radius: 500, event: .arrival)))
        saved.lastResult = .init(date: now, confirmed: 1, total: 1, problems: [], skipped: [], automatic: false)
        store.upsert(saved)
        let workflow = AppDataBackupWorkflow(controller: controller, scenes: store, history: history)
        let backup = try workflow.capture(now: now)
        #expect(backup.placeCount == 1)
        #expect(backup.scenes?.first?.lastResult == nil)
        #expect(store.scenes.first?.lastResult != nil)
        #expect(try AppDataBackup.decode(backup.encoded()) == backup)
        let text = String(decoding: try backup.encoded(), as: UTF8.self)
        #expect(!text.contains("recordingEnabled") && !text.contains("lastResult"))
        workflow.exportScenes = false
        #expect(try workflow.capture(now: now).scenes == nil)
        workflow.exportHistory = false
        #expect(throws: (any Error).self) { try workflow.capture(now: now) }
    }

    @Test func rejectsMalformedVersionsDuplicatesTriggersAndDates() throws {
        var backup = AppDataBackup(createdAt: now, scenes: [scene()])
        backup.version = 4
        #expect(throws: (any Error).self) { try backup.encoded() }
        backup.version = 1
        backup.scenes!.append(backup.scenes![0])
        #expect(throws: (any Error).self) { try backup.encoded() }
        for schedule in [SceneSchedule(hour: 24, minute: 0, weekdays: [1]),
                         SceneSchedule(hour: 1, minute: 60, weekdays: [1]),
                         SceneSchedule(hour: 1, minute: 0, weekdays: [0, 8])] {
            backup.scenes = [scene(trigger: .schedule(schedule))]
            #expect(throws: (any Error).self) { try backup.encoded() }
        }
        backup.scenes = nil
        backup.history = [.init(date: "2026-02-30", model: "WH-1000XM3", seconds: 1)]
        #expect(throws: (any Error).self) { try backup.encoded() }
        backup.history = [.init(date: "2026-02-28", model: "WH-1000XM3", seconds: -1)]
        #expect(throws: (any Error).self) { try backup.encoded() }
        backup.history![0].seconds = 1
        backup.history!.append(backup.history![0])
        #expect(throws: (any Error).self) { try backup.encoded() }
        #expect(throws: (any Error).self) { try AppDataBackup.decode(Data(repeating: 32, count: AppDataBackup.maximumBytes + 1)) }
    }

    @Test func mergeDisablesImportedAutomationAndKeepsUnrelatedScenes() {
        let existing = scene("Existing")
        let untouched = scene("Untouched")
        var replacement = existing
        replacement.name = "Imported replacement"
        let imported = scene("New", trigger: .schedule(.init(hour: 8, minute: 30, weekdays: [2, 3])))
        let result = AppDataBackup.mergedScenes([replacement, imported], into: [existing, untouched])
        #expect(result.count == 3 && result[0].name == replacement.name)
        #expect(!result[0].triggerEnabled && !result[2].triggerEnabled)
        #expect(result[1] == untouched)
    }

    @Test func historyIsIdempotentRetainedAndUsesCivilDatesAcrossTimeZones() throws {
        let source = AppDataHistoryDay.calendar(timeZone: TimeZone(secondsFromGMT: 9 * 3600)!)
        let target = AppDataHistoryDay.calendar(timeZone: TimeZone(secondsFromGMT: -7 * 3600)!)
        let row = AppDataHistoryDay(date: "2026-10-28", model: "WH-1000XM3", seconds: 100)
        let original = ListeningDay(day: try row.localDate(in: source), model: row.model, seconds: 100)
        #expect(AppDataHistoryDay(original, calendar: source) == row)
        let existing = ListeningDay(day: try row.localDate(in: target), model: row.model, seconds: 120)
        let old = AppDataHistoryDay(date: "2020-01-01", model: row.model, seconds: 9)
        let merged = try AppDataHistoryDay.merge([row, old], into: [existing], calendar: target, now: now)
        #expect(merged == [existing])
        #expect(try AppDataHistoryDay.merge([row, old], into: merged, calendar: target, now: now) == merged)
        #expect(AppDataHistoryDay(merged[0], calendar: target).date == "2026-10-28")
    }

    @Test func restorePublishesAfterSavingAndPreservesRecordingPreference() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = HeadphoneController()
        let store = SceneStore(controller: controller, fileURL: directory.appendingPathComponent("scenes.json"))
        let history = ListeningHistory(fileURL: directory.appendingPathComponent("history.json"), calendar: utc, now: now)
        let original = scene("Local")
        store.upsert(original)
        let originalBytes = try Data(contentsOf: store.storageLocation)
        let imported = scene("Imported")
        let backup = AppDataBackup(createdAt: now, scenes: [imported], history: [.init(date: "2026-10-28", model: "WH-1000XM3", seconds: 120)])
        let file = directory.appendingPathComponent("backup.json")
        try backup.encoded().write(to: file)
        let workflow = AppDataBackupWorkflow(controller: controller, scenes: store, history: history)
        workflow.load(file)
        #expect(!workflow.canRestore)
        workflow.review(now: now)
        #expect(workflow.canRestore && workflow.plan?.addedScenes == 1)
        #expect(store.scenes == [original] && history.days.isEmpty)
        workflow.restore()
        #expect(workflow.error == nil && workflow.plan == nil)
        #expect(store.scenes.count == 2 && !store.scenes[1].triggerEnabled)
        #expect(history.days.count == 1 && history.days[0].seconds == 120 && !history.enabled)
        let reloaded = ListeningHistory(fileURL: history.storageLocation, calendar: utc, now: now)
        #expect(reloaded.days == history.days && !reloaded.enabled)
        let recovery = try #require(workflow.recoveryDirectory)
        #expect(try Data(contentsOf: recovery.appendingPathComponent("0-scenes.json")) == originalBytes)
        workflow.review(now: now); workflow.restore()
        #expect(store.scenes.count == 2 && history.days[0].seconds == 120)
    }

    @Test func failedSecondWriteRollsBackBothFilesWithoutPublishingMemory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = HeadphoneController()
        let store = SceneStore(controller: controller, fileURL: directory.appendingPathComponent("scenes.json"))
        let history = ListeningHistory(fileURL: directory.appendingPathComponent("history.json"), calendar: utc, now: now)
        store.upsert(scene("Local")); history.setEnabled(true)
        let oldScenes = store.scenes
        let sceneBytes = try Data(contentsOf: store.storageLocation)
        let historyBytes = try Data(contentsOf: history.storageLocation)
        let file = directory.appendingPathComponent("backup.json")
        try AppDataBackup(createdAt: now, scenes: [scene("Imported")], history: []).encoded().write(to: file)
        let workflow = AppDataBackupWorkflow(controller: controller, scenes: store, history: history)
        workflow.load(file); workflow.review(now: now)
        var writes = 0
        workflow.restore { data, url in
            writes += 1
            try data.write(to: url, options: .atomic)
            if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
        }
        #expect(writes == 2 && workflow.error != nil)
        #expect(store.scenes == oldScenes && history.days.isEmpty && history.enabled)
        #expect(try Data(contentsOf: store.storageLocation) == sceneBytes)
        #expect(try Data(contentsOf: history.storageLocation) == historyBytes)
    }

    @Test func changesAfterReviewAndReplayCannotRestore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = HeadphoneController()
        let store = SceneStore(controller: controller, fileURL: directory.appendingPathComponent("scenes.json"))
        let history = ListeningHistory(fileURL: directory.appendingPathComponent("history.json"), calendar: utc, now: now)
        store.upsert(scene("Local"))
        let file = directory.appendingPathComponent("backup.json")
        try AppDataBackup(createdAt: now, scenes: [scene("Imported")]).encoded().write(to: file)
        let workflow = AppDataBackupWorkflow(controller: controller, scenes: store, history: history)
        workflow.load(file); workflow.review(now: now)
        store.upsert(scene("Changed after review"))
        workflow.restore()
        #expect(workflow.error?.contains("changed after review") == true && store.scenes.count == 2)
        workflow.review(now: now)
        let external = Data("external modification".utf8)
        try external.write(to: store.storageLocation)
        workflow.restore()
        #expect(try Data(contentsOf: store.storageLocation) == external)
        #expect(workflow.error?.contains("changed after review") == true)
        try store.encodedRestoration(store.scenes).write(to: store.storageLocation)
        workflow.review(now: now)
        controller.startReplay(from: directory.appendingPathComponent("missing-replay.txt"))
        #expect(!workflow.canRestore)
        workflow.restore()
        #expect(store.scenes.count == 2)
    }

    @Test func corruptHistoryIsPreservedAndBoundedReaderRejectsSymlinks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("corrupt.json")
        let original = Data("unreadable".utf8)
        try original.write(to: file)
        let history = ListeningHistory(fileURL: file, calendar: utc, now: now)
        #expect(throws: (any Error).self) { try history.checkedBackupFile() }
        #expect(try Data(contentsOf: file) == original)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try AppDataFileChange.read(link) }
        #expect(throws: (any Error).self) { try AppDataFileChange.read(directory) }
    }

    @Test func selectiveRestoreLeavesUnselectedScenesAndEnabledRecordingIntact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = HeadphoneController()
        let store = SceneStore(controller: controller, fileURL: directory.appendingPathComponent("scenes.json"))
        let history = ListeningHistory(fileURL: directory.appendingPathComponent("history.json"), calendar: utc, now: now)
        store.upsert(scene("Local")); history.setEnabled(true)
        let original = try Data(contentsOf: store.storageLocation)
        let file = directory.appendingPathComponent("backup.json")
        try AppDataBackup(createdAt: now, scenes: [scene("Imported")], history: [.init(date: "2026-10-28", model: "WH-1000XM3", seconds: 30)]).encoded().write(to: file)
        let workflow = AppDataBackupWorkflow(controller: controller, scenes: store, history: history)
        workflow.load(file); workflow.review(now: now)
        workflow.restoreScenes = false
        #expect(!workflow.canRestore)
        workflow.review(now: now); workflow.restore()
        #expect(workflow.error == nil && history.enabled && history.days.count == 1)
        #expect(try Data(contentsOf: store.storageLocation) == original)
        #expect(store.scenes.count == 1 && store.scenes[0].triggerEnabled)
    }

    @Test func failureRemovesNewFilesAndKeepsAbsentStateInRecoveryManifest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.json")
        let second = directory.appendingPathComponent("second.json")
        let recovery = directory.appendingPathComponent("recovery")
        var writes = 0
        let writer: (Data, URL) throws -> Void = { data, url in
            writes += 1
            try data.write(to: url, options: .atomic)
            if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
        }
        #expect(throws: (any Error).self) {
            try AppDataFileRestore.apply([.init(url: first, replacement: Data("first".utf8)),
                                          .init(url: second, replacement: Data("second".utf8))],
                                         recoveryDirectory: recovery, write: writer)
        }
        #expect(!FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: second.path))
        #expect(try String(contentsOf: recovery.appendingPathComponent("recovery.txt"), encoding: .utf8).contains("originally absent"))
    }

    @Test func sessionSnapshotsMergeWithoutDoubleCountingOrEnablingRecording() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = HeadphoneController()
        let scenes = SceneStore(controller: controller, fileURL: directory.appendingPathComponent("scenes.json"))
        let history = ListeningHistory(fileURL: directory.appendingPathComponent("history.json"), calendar: utc, now: now)
        history.setEnabled(true); history.setSessionsEnabled(true)
        history.sample(device: "private-address", model: "WH-1000XM3", playing: true, at: now)
        history.sample(device: "private-address", model: "WH-1000XM3", playing: true, at: now.addingTimeInterval(15))
        history.setEnabled(false); history.setSessionsEnabled(false)
        let workflow = AppDataBackupWorkflow(controller: controller, scenes: scenes, history: history)
        var backup = try workflow.capture(now: now)
        var extended = try #require(backup.historySessions?.first)
        extended.endedAt = now.addingTimeInterval(30)
        let overlap = ListeningSession(model: extended.model, startedAt: now.addingTimeInterval(20),
                                       endedAt: now.addingTimeInterval(40), calendar: utc)
        backup.historySessions = [extended, overlap]
        let file = directory.appendingPathComponent("backup.json")
        let bytes = try backup.encoded()
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("private-address") && !text.contains("sessionsEnabled"))
        try bytes.write(to: file)
        workflow.load(file); workflow.review(now: now); workflow.restore()
        #expect(workflow.error == nil && history.sessions.count == 2 && history.total(on: now) == 40)
        #expect(!history.enabled && !history.sessionsEnabled && history.activeSessionID == nil)
        workflow.review(now: now); workflow.restore()
        #expect(workflow.error == nil && history.sessions.count == 2 && history.total(on: now) == 40)
        // A legacy daily-only restore preserves existing session details.
        backup.version = 1; backup.historySessions = nil
        try backup.encoded().write(to: file)
        workflow.load(file); workflow.review(now: now); workflow.restore()
        #expect(workflow.error == nil && history.sessions.count == 2 && history.total(on: now) == 40)
        let loaded = ListeningHistory(fileURL: history.storageLocation, calendar: utc, now: now)
        #expect(loaded.sessions == history.sessions && !loaded.sessionsEnabled)
        workflow.exportHistory = false
        #expect(try workflow.capture(now: now).historySessions == nil)
    }

    @Test func changedSessionDetailsInvalidateReviewEvenWhenDailyTotalsMatch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = HeadphoneController()
        let scenes = SceneStore(controller: controller, fileURL: directory.appendingPathComponent("scenes.json"))
        let history = ListeningHistory(fileURL: directory.appendingPathComponent("history.json"), calendar: utc, now: now)
        history.setEnabled(true); history.setSessionsEnabled(true)
        history.sample(device: "first", model: "WH-1000XM3", playing: true, at: now)
        history.sample(device: "first", model: "WH-1000XM3", playing: true, at: now.addingTimeInterval(15))
        let workflow = AppDataBackupWorkflow(controller: controller, scenes: scenes, history: history)
        let file = directory.appendingPathComponent("backup.json")
        try workflow.capture(now: now).encoded().write(to: file)
        workflow.load(file); workflow.review(now: now)
        history.clearSessions()
        workflow.restore()
        #expect(workflow.error?.contains("changed after review") == true)
        #expect(history.sessions.isEmpty && history.total(on: now) == 15)
        workflow.review(now: now)
        history.setSessionsEnabled(false)
        workflow.restore()
        #expect(workflow.error?.contains("changed after review") == true && !history.sessionsEnabled)
    }

    @Test func failedSessionRestoreRollsBackTheCompleteHistoryDocument() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = HeadphoneController()
        let scenes = SceneStore(controller: controller, fileURL: directory.appendingPathComponent("scenes.json"))
        let history = ListeningHistory(fileURL: directory.appendingPathComponent("history.json"), calendar: utc, now: now)
        history.setEnabled(true); history.setSessionsEnabled(true)
        history.sample(device: "first", model: "WH-1000XM3", playing: true, at: now)
        history.sample(device: "first", model: "WH-1000XM3", playing: true, at: now.addingTimeInterval(15))
        let original = try Data(contentsOf: history.storageLocation), originalSessions = history.sessions
        let imported = ListeningSession(model: "WH-1000XM3", startedAt: now.addingTimeInterval(30),
                                        endedAt: now.addingTimeInterval(45), calendar: utc)
        let workflow = AppDataBackupWorkflow(controller: controller, scenes: scenes, history: history)
        let file = directory.appendingPathComponent("backup.json")
        try AppDataBackup(createdAt: now, history: [], historySessions: [imported]).encoded().write(to: file)
        workflow.load(file); workflow.review(now: now)
        workflow.restore { data, url in
            try data.write(to: url, options: .atomic)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        #expect(workflow.error != nil && history.sessions == originalSessions && history.total(on: now) == 15)
        #expect(try Data(contentsOf: history.storageLocation) == original)
    }
}
