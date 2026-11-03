import Foundation

/// Persisted provenance describes where text came from, not a claim about a streaming service.
struct ListeningContent: Codable, Equatable {
    enum Source: String, Codable, CaseIterable { case headphones, macApp }
    var metadata: PlaybackMetadata
    var source: Source
    var appBundleIdentifier: String?

    func validate() throws {
        guard let title = metadata.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [metadata.title, metadata.artist, metadata.album].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 512 }),
              source == .macApp ? (appBundleIdentifier.map { !$0.isEmpty && $0.utf8.count <= 256 } ?? false)
                                : appBundleIdentifier == nil else {
            throw AppDataBackupError.invalid("A song-history record has invalid text or source information.")
        }
    }
}

struct ListeningContentRecord: Codable, Equatable, Identifiable {
    var interval: ListeningSession
    var content: ListeningContent
    var id: UUID { interval.id }
    static let maximumCount = 5_000

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        ListeningSession.newestFirst(lhs.interval, rhs.interval)
    }

    static func validate(_ records: [Self]) throws {
        guard records.count <= maximumCount else { throw AppDataBackupError.invalid("Song history exceeds 5,000 records.") }
        try ListeningSession.validate(records.map(\.interval))
        for record in records { try record.content.validate() }
    }

    static func retained(_ records: [Self], calendar: Calendar, now: Date) -> [Self] {
        let intervals = ListeningSession.retained(records.map(\.interval), calendar: calendar, now: now)
        let ids = Set(intervals.prefix(maximumCount).map(\.id))
        return records.filter { ids.contains($0.id) }.sorted(by: newestFirst)
    }

    static func merge(_ imported: [Self], into existing: [Self], calendar: Calendar, now: Date) throws -> [Self] {
        try validate(imported); try validate(existing)
        var values = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for record in imported {
            if let old = values[record.id] {
                guard old.content == record.content else {
                    throw AppDataBackupError.invalid("A song-history identifier refers to different content.")
                }
                // Reuse interval identity/conflict validation without pruning its single result.
                _ = try ListeningSession.merge([record.interval], into: [old.interval], calendar: calendar, now: now)
                if record.interval.endedAt > old.interval.endedAt { values[record.id] = record }
            } else { values[record.id] = record }
        }
        return retained(Array(values.values), calendar: calendar, now: now)
    }
}

/// Source selection is deliberately conservative. Unknown routes never inherit the default output.
enum ListeningContentAttribution {
    static func headphone(_ playback: NowPlaying, at date: Date) -> ListeningContent? {
        guard playback.hasFreshListeningStatus(at: date), playback.status == .playing,
              let metadata = playback.metadata, let reported = playback.metadataReportedAt,
              (0..<90).contains(date.timeIntervalSince(reported)) else { return nil }
        let content = ListeningContent(metadata: metadata, source: .headphones)
        return (try? content.validate()) != nil ? content : nil
    }

    static func mac(_ item: SystemNowPlaying.Item, playback: NowPlaying,
                    routeMatches: Bool, at date: Date) -> ListeningContent? {
        guard routeMatches, item.playing, playback.hasFreshListeningStatus(at: date), playback.status == .playing else { return nil }
        let content = ListeningContent(metadata: .init(title: item.title, album: item.album, artist: item.artist),
                                       source: .macApp, appBundleIdentifier: item.bundleIdentifier)
        return (try? content.validate()) != nil ? content : nil
    }
}
