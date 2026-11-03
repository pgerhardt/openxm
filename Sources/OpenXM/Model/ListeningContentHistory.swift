import Foundation
import Observation

/// Separate opt-in and file: daily/session recording never implicitly saves track text.
@MainActor @Observable
final class ListeningContentHistory {
    private(set) var enabled = false
    private(set) var records: [ListeningContentRecord] = []
    private(set) var activeRecordID: UUID?
    private(set) var saveError: String?
    var recordingStatus: RecordingStatus = .waitingForPlayback
    enum RecordingStatus: Equatable {
        case waitingForPlayback, paused, readingMetadata, metadataUnavailable, metadataChanged, unmatchedOutput, recording
        case metadataReadFailed(SystemNowPlaying.HistoryReadFailure)
        var message: String {
            switch self {
            case .waitingForPlayback: "Waiting for fresh playback information from the headphones."
            case .paused: "Playback is paused."
            case .readingMetadata: "Checking the current track and its audio output…"
            case .metadataUnavailable: "Waiting for current track details from the Mac player or headphones."
            case .metadataReadFailed(let reason): reason.message
            case .metadataChanged: "The player or track changed during the check. Waiting for a matching observation."
            case .unmatchedOutput: "The Mac player’s active audio output could not be matched to these headphones."
            case .recording: "Recording verified listening intervals."
            }
        }
    }
    static let maximumBytes = 16_000_000
    let storageLocation: URL
    let storageCalendar: Calendar
    private var unreadable = false
    private struct Sample { var device: String; var model: String; var content: ListeningContent; var date: Date }
    private var previous: Sample?
    private struct Document: Codable {
        var version = 1
        var enabled: Bool
        var records: [ListeningContentRecord]
        func validate() throws {
            guard version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            try ListeningContentRecord.validate(records)
        }
    }

    init(fileURL: URL? = nil, calendar: Calendar = .current, now: Date = Date()) {
        storageCalendar = calendar
        storageLocation = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundConnect/listening-content.json")
        do {
            guard let data = try AppDataFileChange.read(storageLocation, maximumBytes: Self.maximumBytes) else { return }
            let document = try JSONDecoder().decode(Document.self, from: data)
            try document.validate()
            enabled = document.enabled
            records = ListeningContentRecord.retained(document.records, calendar: calendar, now: now)
            if records.count != document.records.count { persist() }
        } catch {
            unreadable = true
            saveError = "Could not read song history. The original file has been preserved."
        }
    }

    func setEnabled(_ value: Bool) {
        guard !unreadable else { return }
        enabled = value; stopSample(); persist()
    }

    /// A verified observation starts/extends a track. Changes close the old interval at observation time.
    /// Missing source evidence ends continuity without attributing the intervening time.
    func sample(device: String?, model: String?, content: ListeningContent?, at date: Date = Date()) {
        guard enabled, !unreadable, let device, let model, let content,
              (try? content.validate()) != nil, date.timeIntervalSinceReferenceDate.isFinite else { stopSample(); return }
        appendInterval(device: device, model: model, at: date)
        if previous?.content != content { activeRecordID = nil }
        previous = Sample(device: device, model: model, content: content, date: date)
    }

    /// Only an explicit, fresh headphone pause may close an already verified interval this way.
    func pause(device: String?, model: String?, at date: Date = Date()) {
        if enabled, !unreadable, let device, let model { appendInterval(device: device, model: model, at: date) }
        stopSample()
    }

    func stopSample() { previous = nil; activeRecordID = nil }

    private func appendInterval(device: String, model: String, at date: Date) {
        guard let old = previous, old.device == device, old.model == model else { activeRecordID = nil; return }
        let elapsed = date.timeIntervalSince(old.date)
        if elapsed == 0 { return }
        guard elapsed > 0, elapsed <= 30 else { activeRecordID = nil; return }
        var cursor = old.date
        while cursor < date {
            let day = storageCalendar.startOfDay(for: cursor)
            guard let next = storageCalendar.date(byAdding: .day, value: 1, to: day), next > cursor else { break }
            let end = min(next, date)
            let interval = ListeningSession(model: model, startedAt: cursor, endedAt: end, calendar: storageCalendar)
            guard (try? interval.validate()) != nil else { stopSample(); return }
            if let i = records.firstIndex(where: { $0.id == activeRecordID }), records[i].interval.endedAt == cursor,
               records[i].interval.day == interval.day, records[i].content == old.content {
                records[i].interval.endedAt = end
            } else {
                let row = ListeningContentRecord(interval: interval, content: old.content)
                records.insert(row, at: 0); activeRecordID = row.id
            }
            cursor = end
        }
        records = ListeningContentRecord.retained(records, calendar: storageCalendar, now: date)
        persist()
    }

    func clear() {
        if unreadable {
            do { try FileManager.default.copyItem(at: storageLocation, to: storageLocation.appendingPathExtension("unreadable-\(UUID()).json")) }
            catch { saveError = "Could not preserve the unreadable song-history file."; return }
        }
        unreadable = false; records = []; stopSample(); persist()
    }

    func checkedBackupFile() throws -> Data? {
        guard !unreadable, saveError == nil else { throw AppDataBackupError.invalid("Resolve the song-history storage error before backing up or restoring it.") }
        let data = try AppDataFileChange.read(storageLocation, maximumBytes: Self.maximumBytes)
        let saved = try data.map { try JSONDecoder().decode(Document.self, from: $0) }
        try saved?.validate()
        guard saved.map({ $0.enabled == enabled && $0.records.sorted(by: ListeningContentRecord.newestFirst) == records }) ?? (!enabled && records.isEmpty) else {
            throw AppDataBackupError.invalid("Saved song history changed outside the app. Reopen OpenXM before continuing.")
        }
        return data
    }

    func encodedRestoration(_ records: [ListeningContentRecord]) throws -> Data {
        let document = Document(enabled: enabled, records: records)
        try document.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumBytes else { throw AppDataBackupError.invalid("Song history exceeds the 16 MB storage limit.") }
        return data
    }

    func acceptRestoration(_ records: [ListeningContentRecord]) {
        self.records = records; stopSample(); saveError = nil
    }

    private func persist() {
        do {
            let data = try encodedRestoration(records)
            try FileManager.default.createDirectory(at: storageLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storageLocation, options: .atomic)
            saveError = nil
        } catch { saveError = "Could not save song history: \(error.localizedDescription)" }
    }
}
