import Foundation
import Observation

struct ListeningDay: Codable, Equatable, Identifiable {
    var day: Date
    var model: String
    var seconds: TimeInterval
    var id: String { "\(day.timeIntervalSince1970)-\(model)" }
}

/// Local, opt-in estimates from headset playback status. No song names, addresses or cloud requests.
@MainActor @Observable
final class ListeningHistory {
    private(set) var enabled = false
    private(set) var days: [ListeningDay] = []
    private(set) var sessionsEnabled = false
    private(set) var sessions: [ListeningSession] = []
    private(set) var activeSessionID: UUID?
    private(set) var saveError: String?

    static let maximumBytes = 8_000_000

    private struct Document: Codable {
        var version = 2
        var enabled: Bool
        var days: [ListeningDay]
        var sessionsEnabled: Bool?
        var sessions: [ListeningSession]?

        func validate() throws {
            guard (1...2).contains(version), version != 1 || (sessionsEnabled == nil && sessions == nil),
                  days.count <= 6_000, Set(days.map(\.id)).count == days.count,
                  days.allSatisfy({ $0.day.timeIntervalSinceReferenceDate.isFinite &&
                      $0.seconds.isFinite && (0...172_800).contains($0.seconds) &&
                      !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.model.count <= 128 }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try ListeningSession.validate(sessions ?? [])
        }
    }
    private struct Sample {
        var date: Date
        var device: String
        var model: String
        var playing: Bool
    }
    private let fileURL: URL
    private let calendar: Calendar
    private var previous: Sample?
    private var unreadable = false

    init(fileURL: URL? = nil, calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundConnect/listening-history.json")
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        do {
            guard let data = try AppDataFileChange.read(self.fileURL, maximumBytes: Self.maximumBytes) else { return }
            let document = try JSONDecoder().decode(Document.self, from: data)
            try document.validate()
            enabled = document.enabled
            days = document.days
            sessionsEnabled = document.sessionsEnabled ?? false
            sessions = (document.sessions ?? []).sorted(by: ListeningSession.newestFirst)
            if prune(before: now) { persist() }
        } catch {
            unreadable = true
            saveError = "Could not read listening history. The original file has been preserved."
        }
    }

    func setEnabled(_ value: Bool) {
        guard !unreadable else { return }
        enabled = value
        stopSample()
        persist()
    }

    func setSessionsEnabled(_ value: Bool) {
        guard !unreadable else { return }
        sessionsEnabled = value
        stopSample()
        persist()
    }

    /// Called every 15 seconds and on observed playback/connection changes. Long gaps, including sleep,
    /// contribute nothing. A disconnect or device switch never attributes time to a different headset.
    func sample(device: String?, model: String?, playback: NowPlaying, at date: Date = Date()) {
        let fresh = playback.hasFreshListeningStatus(at: date)
        sample(device: fresh ? device : nil, model: fresh ? model : nil,
               playing: playback.status == .playing, at: date)
    }

    func sample(device: String?, model: String?, playing: Bool, at date: Date = Date()) {
        guard enabled, !unreadable, let device, let model,
              date.timeIntervalSinceReferenceDate.isFinite else { stopSample(); return }
        defer {
            previous = Sample(date: date, device: device, model: model, playing: playing)
            if !playing { activeSessionID = nil }
        }
        guard let old = previous, old.device == device, old.model == model, old.playing else {
            activeSessionID = nil; return
        }
        let interval = date.timeIntervalSince(old.date)
        if interval == 0 { return }
        guard interval > 0, interval <= 30 else { activeSessionID = nil; return }
        var cursor = old.date
        while cursor < date {
            let day = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > cursor else { break }
            let end = min(nextDay, date)
            if let index = days.firstIndex(where: { $0.day == day && $0.model == old.model }) {
                days[index].seconds += end.timeIntervalSince(cursor)
            } else {
                days.append(ListeningDay(day: day, model: old.model, seconds: end.timeIntervalSince(cursor)))
            }
            if sessionsEnabled {
                let segment = ListeningSession(model: old.model, startedAt: cursor, endedAt: end, calendar: calendar)
                if let index = sessions.firstIndex(where: { $0.id == activeSessionID }),
                   sessions[index].endedAt == cursor, sessions[index].day == segment.day,
                   sessions[index].timeZoneIdentifier == segment.timeZoneIdentifier {
                    sessions[index].endedAt = end
                } else {
                    sessions.insert(segment, at: 0)
                    activeSessionID = segment.id
                }
            }
            cursor = end
        }
        _ = prune(before: date)
        days.sort { $0.day == $1.day ? $0.model < $1.model : $0.day > $1.day }
        persist()
    }

    func stopSample() { previous = nil; activeSessionID = nil }

    var storageLocation: URL { fileURL }
    var storageCalendar: Calendar { calendar }

    func checkedBackupFile() throws -> Data? {
        guard !unreadable, saveError == nil else { throw AppDataBackupError.invalid("Resolve the listening-history storage error before backing up or restoring history.") }
        let data = try AppDataFileChange.read(fileURL, maximumBytes: Self.maximumBytes)
        let stored = try data.map { try JSONDecoder().decode(Document.self, from: $0) }
        try stored?.validate()
        guard stored.map({ $0.enabled == enabled && $0.days == days && ($0.sessionsEnabled ?? false) == sessionsEnabled &&
            ($0.sessions ?? []).sorted(by: ListeningSession.newestFirst) == sessions }) ??
                (!enabled && days.isEmpty && !sessionsEnabled && sessions.isEmpty) else {
            throw AppDataBackupError.invalid("Saved history changed outside the app. Reopen OpenXM before continuing.")
        }
        return data
    }

    func encodedRestoration(_ value: [ListeningDay], sessions restoredSessions: [ListeningSession]? = nil) throws -> Data {
        let document = Document(enabled: enabled, days: value, sessionsEnabled: sessionsEnabled,
                                sessions: restoredSessions ?? sessions)
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumBytes else { throw AppDataBackupError.invalid("The merged listening history exceeds the storage limit.") }
        return data
    }

    /// The recording preference remains local and is never imported from a backup.
    func acceptRestoration(_ value: [ListeningDay], sessions restoredSessions: [ListeningSession]? = nil) {
        days = value
        if let restoredSessions { sessions = restoredSessions }
        stopSample()
        saveError = nil
    }

    private func prune(before date: Date) -> Bool {
        let count = days.count
        let sessionCount = sessions.count
        if let cutoff = calendar.date(byAdding: .day, value: -365, to: calendar.startOfDay(for: date)) {
            days.removeAll { $0.day <= cutoff }
        }
        sessions = ListeningSession.retained(sessions, calendar: calendar, now: date)
        if !sessions.contains(where: { $0.id == activeSessionID }) { activeSessionID = nil }
        return days.count != count || sessions.count != sessionCount
    }

    func total(on date: Date) -> TimeInterval {
        let day = calendar.startOfDay(for: date)
        return days.filter { $0.day == day }.reduce(0) { $0 + $1.seconds }
    }

    /// Explicit UI action; corrupt originals are kept aside before starting a clean history.
    func clear() {
        if unreadable {
            do {
                try FileManager.default.copyItem(at: fileURL, to: fileURL.appendingPathExtension("unreadable-\(UUID().uuidString).json"))
            } catch { saveError = "Could not preserve the unreadable history file."; return }
        }
        unreadable = false
        stopSample()
        days = []
        sessions = []
        persist()
    }

    func clearSessions() {
        guard !unreadable else { return }
        stopSample()
        sessions = []
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(enabled: enabled, days: days,
                                                   sessionsEnabled: sessionsEnabled, sessions: sessions))
            guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: fileURL, options: .atomic)
            saveError = nil
        } catch { saveError = "Could not save listening history: \(error.localizedDescription)" }
    }
}
