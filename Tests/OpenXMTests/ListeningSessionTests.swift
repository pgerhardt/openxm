import Foundation
import Testing
@testable import OpenXM

@MainActor struct ListeningSessionTests {
    private let now = Date(timeIntervalSince1970: 1_793_340_000)
    private var utc: Calendar { AppDataHistoryDay.calendar(timeZone: .gmt) }
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("session-history-\(UUID()).json")
    }
    private func session(_ start: TimeInterval = 0, _ end: TimeInterval = 15) -> ListeningSession {
        .init(model: "WH-1000XM3", startedAt: now.addingTimeInterval(start), endedAt: now.addingTimeInterval(end), calendar: utc)
    }

    @Test func legacyTotalsMigrateWithoutOptingIntoSessionTimes() throws {
        struct Legacy: Codable { var version = 1; var enabled = true; var days: [ListeningDay] }
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try JSONEncoder().encode(Legacy(days: [.init(day: utc.startOfDay(for: now), model: "WH-1000XM3", seconds: 120)]))
        try bytes.write(to: url)
        let store = ListeningHistory(fileURL: url, calendar: utc, now: now)
        #expect(store.enabled && !store.sessionsEnabled && store.sessions.isEmpty)
        #expect(try store.checkedBackupFile() == bytes)
        store.sample(device: "private-address", model: "WH-1000XM3", playing: true, at: now)
        store.sample(device: "private-address", model: "WH-1000XM3", playing: true, at: now.addingTimeInterval(15))
        #expect(store.total(on: now) == 135 && store.sessions.isEmpty)
        store.setSessionsEnabled(true)
        store.sample(device: "private-address", model: "WH-1000XM3", playing: true, at: now.addingTimeInterval(20))
        store.sample(device: "private-address", model: "WH-1000XM3", playing: true, at: now.addingTimeInterval(35))
        #expect(store.sessions.count == 1 && store.sessions[0].seconds == 15)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("private-address"))
        let reloaded = ListeningHistory(fileURL: url, calendar: utc, now: now)
        #expect(reloaded.sessions == store.sessions && reloaded.sessionsEnabled && reloaded.activeSessionID == nil)
        reloaded.sample(device: "private-address", model: "WH-1000XM3", playing: true, at: now.addingTimeInterval(40))
        reloaded.sample(device: "private-address", model: "WH-1000XM3", playing: true, at: now.addingTimeInterval(55))
        #expect(reloaded.sessions.count == 2 && reloaded.total(on: now) == 165)
    }

    @Test func pausesDisconnectsDeviceChangesAndSleepEndSessions() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ListeningHistory(fileURL: url, calendar: utc, now: now)
        store.setEnabled(true); store.setSessionsEnabled(true)
        func sample(_ offset: TimeInterval, _ playing: Bool = true, _ device: String? = "first") {
            store.sample(device: device, model: "WH-1000XM3", playing: playing, at: now.addingTimeInterval(offset))
        }
        sample(0); sample(15); sample(20, false); sample(30, false)
        #expect(store.sessions.count == 1 && store.sessions[0].seconds == 20 && store.activeSessionID == nil)
        sample(40); sample(55); sample(60, false, nil)
        sample(65); sample(80); sample(95, true, "second"); sample(110, true, "second")
        sample(1000, true, "second"); sample(1015, true, "second")
        #expect(store.sessions.count == 5 && store.sessions.reduce(0) { $0 + $1.seconds } == 80)
        #expect(store.total(on: now) == 80)
        store.stopSample()
        sample(1020, true, "second")
        #expect(store.activeSessionID == nil && store.sessions.count == 5)
    }

    @Test func midnightSplitsSessionsAndDayTotalsConsistently() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let midnight = utc.startOfDay(for: now)
        let store = ListeningHistory(fileURL: url, calendar: utc, now: now)
        store.setEnabled(true); store.setSessionsEnabled(true)
        for second: TimeInterval in [-10, 5, 20] {
            store.sample(device: "first", model: "WH-1000XM3", playing: true, at: midnight.addingTimeInterval(second))
        }
        #expect(store.sessions.count == 2)
        #expect(store.sessions.map(\.seconds) == [20, 10])
        #expect(store.total(on: midnight) == 20 && store.total(on: midnight.addingTimeInterval(-1)) == 10)
        try ListeningSession.validate(store.sessions)
    }

    @Test func repeatedDSTHourPreservesElapsedTimeAndRecordedZone() throws {
        let calendar = AppDataHistoryDay.calendar(timeZone: try #require(TimeZone(identifier: "America/Denver")))
        let start = try #require(ISO8601DateFormatter().date(from: "2026-11-01T07:59:50Z"))
        let value = ListeningSession(model: "WH-1000XM3", startedAt: start, endedAt: start.addingTimeInterval(15), calendar: calendar)
        try value.validate()
        #expect(value.day == "2026-11-01" && value.seconds == 15)
        #expect(calendar.component(.hour, from: value.startedAt) == 1 && calendar.component(.hour, from: value.endedAt) == 1)
        #expect(calendar.component(.minute, from: value.startedAt) == 59 && calendar.component(.minute, from: value.endedAt) == 0)
        let moved = try ListeningSession.merge([value], into: [], calendar: utc, now: start)
        #expect(moved == [value])
    }

    @Test func clearingSessionTimesPreservesDailyTotalsAndPreferences() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ListeningHistory(fileURL: url, calendar: utc, now: now)
        store.setEnabled(true); store.setSessionsEnabled(true)
        for second: TimeInterval in [0, 15] {
            store.sample(device: "first", model: "WH-1000XM3", playing: true, at: now.addingTimeInterval(second))
        }
        store.clearSessions()
        #expect(store.sessions.isEmpty && store.total(on: now) == 15 && store.enabled && store.sessionsEnabled)
        #expect(store.activeSessionID == nil)
        store.setSessionsEnabled(false)
        for second: TimeInterval in [20, 35] {
            store.sample(device: "first", model: "WH-1000XM3", playing: true, at: now.addingTimeInterval(second))
        }
        #expect(store.total(on: now) == 30 && store.sessions.isEmpty)
        store.clear()
        #expect(store.days.isEmpty && store.sessions.isEmpty && store.enabled && !store.sessionsEnabled)
    }

    @Test func mergingSnapshotsIsIdempotentAndUsesUnionForOverlaps() throws {
        let first = session()
        var laterSnapshot = first; laterSnapshot.endedAt = now.addingTimeInterval(30)
        let overlap = session(20, 40), separate = session(50, 60)
        let merged = try ListeningSession.merge([laterSnapshot, overlap, separate], into: [first], calendar: utc, now: now)
        #expect(merged.count == 3)
        #expect(ListeningSession.dailyCoverage(merged).first?.seconds == 50)
        #expect(try ListeningSession.merge([first, overlap, separate], into: merged, calendar: utc, now: now) == merged)
        var conflict = first; conflict.model = "WH-1000XM4"
        #expect(throws: (any Error).self) { try ListeningSession.merge([conflict], into: merged, calendar: utc, now: now) }
    }

    @Test func invalidSessionsAndCorruptStorageArePreserved() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let valid = session()
        var invalid = valid; invalid.endedAt = invalid.startedAt
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = valid; invalid.day = "2026-02-30"
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = valid; invalid.timeZoneIdentifier = "Unknown/Place"
        #expect(throws: (any Error).self) { try invalid.validate() }
        #expect(throws: (any Error).self) { try ListeningSession.validate([valid, valid]) }
        let data = Data("{\"version\":2,\"enabled\":true,\"days\":[],\"sessions\":[{}]}".utf8)
        try data.write(to: url)
        let store = ListeningHistory(fileURL: url, calendar: utc, now: now)
        store.setEnabled(true); store.setSessionsEnabled(true); store.clearSessions()
        #expect(!store.enabled && !store.sessionsEnabled && store.saveError != nil)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func retentionBoundsSessionCountAndExpiresOldRecords() throws {
        let current = session()
        let oldDate = now.addingTimeInterval(-366 * 86_400)
        let old = ListeningSession(model: "WH-1000XM3", startedAt: oldDate, endedAt: oldDate.addingTimeInterval(15), calendar: utc)
        #expect(ListeningSession.retained([old, current], calendar: utc, now: now) == [current])
        var many = (0...ListeningSession.maximumCount).map { _ in session() }
        many[0].startedAt = now.addingTimeInterval(-10)
        let kept = ListeningSession.retained(many, calendar: utc, now: now)
        #expect(kept.count == ListeningSession.maximumCount && !kept.contains(where: { $0.id == many[0].id }))
        #expect(throws: (any Error).self) { try ListeningSession.validate(many) }
    }

    @Test func maximumRetainedLogFitsStorageAndPortableBackup() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let sessions = (0..<ListeningSession.maximumCount).map { _ in session() }
            .sorted(by: ListeningSession.newestFirst)
        let store = ListeningHistory(fileURL: url, calendar: utc, now: now)
        let days = [ListeningDay(day: utc.startOfDay(for: now), model: "WH-1000XM3", seconds: 15)]
        let data = try store.encodedRestoration(days, sessions: sessions)
        #expect(data.count < ListeningHistory.maximumBytes)
        try data.write(to: url)
        let loaded = ListeningHistory(fileURL: url, calendar: utc, now: now)
        #expect(loaded.sessions == sessions && loaded.saveError == nil && !loaded.sessionsEnabled)
        let backup = AppDataBackup(createdAt: now, history: days.map { AppDataHistoryDay($0, calendar: utc) }, historySessions: sessions)
        #expect(try AppDataBackup.decode(backup.encoded()) == backup)
        #expect(try loaded.checkedBackupFile() == data)
    }
}
