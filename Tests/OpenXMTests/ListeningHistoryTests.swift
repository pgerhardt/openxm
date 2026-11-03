import Foundation
import Testing
@testable import OpenXM

@MainActor struct ListeningHistoryTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("openxm-history-\(UUID().uuidString).json")
    }
    private var utc: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    @Test func defaultIsOffAndPersistenceOmitsDeviceIdentity() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ListeningHistory(fileURL: file, calendar: utc)
        let date = Date(timeIntervalSince1970: 100_000)
        store.sample(device: "unique-test-address", model: "WH-1000XM3", playing: true, at: date)
        #expect(!store.enabled && store.days.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        store.setEnabled(true)
        store.sample(device: "unique-test-address", model: "WH-1000XM3", playing: true, at: date)
        store.sample(device: "unique-test-address", model: "WH-1000XM3", playing: true, at: date.addingTimeInterval(15))
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("unique-test-address"))
        let loaded = ListeningHistory(fileURL: file, calendar: utc, now: date)
        #expect(loaded.enabled && loaded.total(on: date) == 15)
        // Restart never counts time while the process was closed.
        loaded.sample(device: "unique-test-address", model: "WH-1000XM3", playing: true, at: date.addingTimeInterval(100))
        #expect(loaded.total(on: date) == 15)
        loaded.setEnabled(false)
        loaded.sample(device: "unique-test-address", model: "WH-1000XM3", playing: true, at: date.addingTimeInterval(115))
        #expect(loaded.total(on: date) == 15)
    }

    @Test func pauseDisconnectSwitchAndSleepCannotInflateTotals() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ListeningHistory(fileURL: file, calendar: utc)
        store.setEnabled(true)
        let start = Date(timeIntervalSince1970: 100_000)
        func sample(_ second: Double, _ playing: Bool, _ device: String? = "first") {
            store.sample(device: device, model: device == nil ? nil : "WH-1000XM3", playing: playing, at: start.addingTimeInterval(second))
        }
        sample(0, true); sample(10, false); sample(25, false)
        #expect(store.total(on: start) == 10)
        sample(30, true); sample(45, true); sample(50, false, nil)
        sample(55, true); sample(60, true, "second")
        #expect(store.total(on: start) == 25)
        sample(3600, true, "second") // timer did not run during sleep
        #expect(store.total(on: start) == 25)
        store.stopSample()
        sample(3610, true, "second")
        #expect(store.total(on: start) == 25)
        sample(3625, true, "second")
        #expect(store.total(on: start) == 40)
        store.clear()
        #expect(store.days.isEmpty && store.enabled)
    }

    @Test func midnightAllocatesTimeToEachDay() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ListeningHistory(fileURL: file, calendar: utc)
        store.setEnabled(true)
        let midnight = Date(timeIntervalSince1970: 86_400)
        store.sample(device: "first", model: "WH-1000XM3", playing: true, at: midnight.addingTimeInterval(-10))
        store.sample(device: "first", model: "WH-1000XM3", playing: true, at: midnight.addingTimeInterval(5))
        #expect(store.total(on: midnight.addingTimeInterval(-1)) == 10)
        #expect(store.total(on: midnight) == 5)
    }

    @Test func unreadableHistoryIsPreservedWithoutRecording() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data("not valid history".utf8)
        try original.write(to: file)
        let store = ListeningHistory(fileURL: file, calendar: utc)
        store.setEnabled(true)
        store.sample(device: "first", model: "WH-1000XM3", playing: true)
        #expect(store.saveError != nil && !store.enabled)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func oldHistoryExpiresOnNextLaunchEvenWhenRecordingWasDisabled() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date(timeIntervalSince1970: 100_000)
        let store = ListeningHistory(fileURL: file, calendar: utc, now: start)
        store.setEnabled(true)
        store.sample(device: "first", model: "WH-1000XM3", playing: true, at: start)
        store.sample(device: "first", model: "WH-1000XM3", playing: true, at: start.addingTimeInterval(15))
        store.setEnabled(false)
        let loaded = ListeningHistory(fileURL: file, calendar: utc, now: start.addingTimeInterval(366 * 86_400))
        #expect(!loaded.enabled && loaded.days.isEmpty)
    }
}
