import Foundation

/// A contiguous interval estimated from playback reports, split at local midnight.
/// Device addresses are deliberately absent. UUIDs identify records across backup snapshots.
struct ListeningSession: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var day: String
    var model: String
    var startedAt: Date
    var endedAt: Date
    var timeZoneIdentifier: String
    var seconds: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    static let maximumCount = 12_000

    init(model: String, startedAt: Date, endedAt: Date, calendar: Calendar) {
        self.model = model; self.startedAt = startedAt; self.endedAt = endedAt
        timeZoneIdentifier = calendar.timeZone.identifier
        day = AppDataHistoryDay(.init(day: startedAt, model: model, seconds: 0), calendar: calendar).date
    }

    func validate() throws {
        guard let zone = TimeZone(identifier: timeZoneIdentifier),
              startedAt.timeIntervalSinceReferenceDate.isFinite, endedAt.timeIntervalSinceReferenceDate.isFinite,
              seconds > 0, seconds <= 90_000 else {
            throw AppDataBackupError.invalid("A listening session has invalid times or a time zone.")
        }
        let calendar = AppDataHistoryDay.calendar(timeZone: zone)
        let row = AppDataHistoryDay(date: day, model: model, seconds: seconds)
        try row.validate()
        let midnight = try row.localDate(in: calendar)
        guard let next = calendar.date(byAdding: .day, value: 1, to: midnight),
              startedAt >= midnight, startedAt < next, endedAt <= next else {
            throw AppDataBackupError.invalid("A listening session crosses its recorded calendar date.")
        }
    }

    static func validate(_ sessions: [Self]) throws {
        guard sessions.count <= maximumCount, Set(sessions.map(\.id)).count == sessions.count else {
            throw AppDataBackupError.invalid("The history has too many sessions or duplicate session identifiers.")
        }
        for session in sessions { try session.validate() }
    }

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.startedAt == rhs.startedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.startedAt > rhs.startedAt
    }

    static func retained(_ sessions: [Self], calendar: Calendar, now: Date) -> [Self] {
        let cutoff = calendar.date(byAdding: .day, value: -365, to: calendar.startOfDay(for: now))!
        let cutoffDay = AppDataHistoryDay(.init(day: cutoff, model: "", seconds: 0), calendar: calendar).date
        return Array(sessions.filter { $0.day > cutoffDay }.sorted(by: newestFirst).prefix(maximumCount))
    }

    /// A later snapshot may extend an unfinished session, but cannot rewrite its identity or start.
    static func merge(_ imported: [Self], into existing: [Self], calendar: Calendar, now: Date) throws -> [Self] {
        try validate(imported); try validate(existing)
        var records = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for session in imported {
            if let old = records[session.id] {
                guard old.day == session.day, old.model == session.model, old.startedAt == session.startedAt,
                      old.timeZoneIdentifier == session.timeZoneIdentifier else {
                    throw AppDataBackupError.invalid("A session identifier refers to conflicting history. No history was replaced.")
                }
                if session.endedAt > old.endedAt { records[session.id] = session }
            } else { records[session.id] = session }
        }
        return retained(Array(records.values), calendar: calendar, now: now)
    }

    /// Intervals from multiple exports/Macs can overlap even with different UUIDs. Count their union.
    static func dailyCoverage(_ sessions: [Self]) -> [AppDataHistoryDay] {
        let groups = Dictionary(grouping: sessions) { $0.day + "|" + $0.model }
        return groups.values.map { rows in
            let ordered = rows.sorted { $0.startedAt < $1.startedAt }
            let first = ordered[0]
            var start = first.startedAt, end = first.endedAt, total: TimeInterval = 0
            for row in ordered.dropFirst() {
                if row.startedAt <= end { end = max(end, row.endedAt) }
                else { total += end.timeIntervalSince(start); start = row.startedAt; end = row.endedAt }
            }
            total += end.timeIntervalSince(start)
            return .init(date: first.day, model: first.model, seconds: total)
        }
    }
}
