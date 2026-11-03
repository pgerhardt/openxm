import Foundation
import Darwin

enum AppDataBackupError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { text } else { nil } }
}

/// Local app configuration only. No account tokens, device addresses or recording preference.
struct AppDataBackup: Codable, Equatable {
    var format = "OpenXM app data"
    var version = 3
    var createdAt: Date
    var scenes: [SoundScene]?
    var history: [AppDataHistoryDay]?
    var historySessions: [ListeningSession]?
    var listeningContent: [ListeningContentRecord]?

    static let maximumBytes = 32_000_000
    var placeCount: Int { scenes?.filter { if case .location = $0.trigger { true } else { false } }.count ?? 0 }

    func validate() throws {
        guard format == "OpenXM app data", (1...3).contains(version),
              version != 1 || historySessions == nil, historySessions == nil || history != nil,
              version >= 3 || listeningContent == nil,
              createdAt.timeIntervalSinceReferenceDate.isFinite, scenes != nil || history != nil || listeningContent != nil else {
            throw AppDataBackupError.invalid("This app-data backup format is not supported.")
        }
        if let scenes {
            guard scenes.count <= 500, Set(scenes.map(\.id)).count == scenes.count else {
                throw AppDataBackupError.invalid("The backup has too many scenes or duplicate scene identifiers.")
            }
            for scene in scenes {
                guard !scene.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, scene.name.count <= 200,
                      !scene.symbol.isEmpty, scene.symbol.count <= 100, scene.trigger.isValid,
                      scene.generalSettings.count <= 64, scene.generalSettings.keys.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
                      scene.noise.map({ (0...255).contains($0.ambientLevel) }) ?? true else {
                    throw AppDataBackupError.invalid("A saved scene has invalid names, settings or trigger values.")
                }
                if case .custom(let bands, let bass) = scene.equalizer {
                    guard (1...32).contains(bands.count), bands.allSatisfy({ (-128...127).contains($0) }),
                          bass.map({ (-128...127).contains($0) }) ?? true else {
                        throw AppDataBackupError.invalid("A saved scene contains an invalid equalizer curve.")
                    }
                }
            }
        }
        if let history {
            guard history.count <= 6_000, Set(history.map(\.id)).count == history.count else {
                throw AppDataBackupError.invalid("The backup has too much history or duplicate daily totals.")
            }
            for day in history { try day.validate() }
        }
        if let historySessions { try ListeningSession.validate(historySessions) }
        if let listeningContent { try ListeningContentRecord.validate(listeningContent) }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw AppDataBackupError.invalid("The app-data backup exceeds 32 MB.") }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw AppDataBackupError.invalid("The app-data backup exceeds 32 MB.") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    static func portableScenes(_ scenes: [SoundScene]) -> [SoundScene] {
        scenes.map { var scene = $0; scene.lastResult = nil; return scene }
    }

    /// Match UUIDs, retain unrelated scenes, and never activate imported automation implicitly.
    static func mergedScenes(_ imported: [SoundScene], into existing: [SoundScene]) -> [SoundScene] {
        var result = existing
        for var scene in portableScenes(imported) {
            if scene.trigger.isAutomatic { scene.triggerEnabled = false }
            if let index = result.firstIndex(where: { $0.id == scene.id }) { result[index] = scene }
            else { result.append(scene) }
        }
        return result
    }
}

/// Civil dates preserve the displayed day when moving a backup to a different time zone.
struct AppDataHistoryDay: Codable, Equatable, Identifiable {
    var date: String
    var model: String
    var seconds: TimeInterval
    var id: String { date + "|" + model }

    static func calendar(timeZone: TimeZone) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = timeZone
        return result
    }

    init(_ day: ListeningDay, calendar: Calendar) {
        let calendar = Self.calendar(timeZone: calendar.timeZone)
        let parts = calendar.dateComponents([.year, .month, .day], from: day.day)
        date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        model = day.model
        seconds = day.seconds
    }

    init(date: String, model: String, seconds: TimeInterval) {
        self.date = date; self.model = model; self.seconds = seconds
    }

    func localDate(in calendar: Calendar) throws -> Date {
        let pieces = date.split(separator: "-", omittingEmptySubsequences: false)
        guard date.utf8.count == 10, pieces.count == 3, pieces[0].count == 4,
              pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), (1...9999).contains(year),
              let month = Int(pieces[1]), let day = Int(pieces[2]) else {
            throw AppDataBackupError.invalid("A listening-history date is invalid.")
        }
        let calendar = Self.calendar(timeZone: calendar.timeZone)
        let parts = DateComponents(year: year, month: month, day: day)
        guard let value = calendar.date(from: parts), calendar.dateComponents([.year, .month, .day], from: value) == parts,
              String(format: "%04d-%02d-%02d", year, month, day) == date else {
            throw AppDataBackupError.invalid("A listening-history date is invalid in this time zone.")
        }
        return value
    }

    func validate() throws {
        _ = try localDate(in: Self.calendar(timeZone: TimeZone(secondsFromGMT: 0)!))
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.count <= 128,
              seconds.isFinite, (0...172_800).contains(seconds) else {
            throw AppDataBackupError.invalid("A listening-history total is invalid.")
        }
    }

    static func merge(_ imported: [Self], into existing: [ListeningDay], calendar: Calendar, now: Date) throws -> [ListeningDay] {
        let calendar = Self.calendar(timeZone: calendar.timeZone)
        let cutoff = calendar.date(byAdding: .day, value: -365, to: calendar.startOfDay(for: now))!
        var totals: [String: ListeningDay] = [:]
        for row in existing.map({ Self($0, calendar: calendar) }) + imported {
            try row.validate()
            let day = try row.localDate(in: calendar)
            guard day > cutoff else { continue }
            // Import is idempotent: overlapping daily estimates are never added together.
            totals[row.id] = .init(day: day, model: row.model, seconds: max(totals[row.id]?.seconds ?? 0, row.seconds))
        }
        return totals.values.sorted { $0.day == $1.day ? $0.model < $1.model : $0.day > $1.day }
    }
}

struct AppDataFileChange {
    var url: URL
    var original: Data?
    var replacement: Data

    /// Bounded, non-following read also rejects directories and other special files.
    static func read(_ url: URL, maximumBytes: Int = AppDataBackup.maximumBytes) throws -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumBytes else {
            throw AppDataBackupError.invalid("Choose a regular app-data file no larger than \(maximumBytes / 1_000_000) MB.")
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw AppDataBackupError.invalid("The file exceeds the storage limit.") }
        return data
    }
}

/// Preserve exact originals before writes; rollback synchronous failures before publishing memory.
/// Each file is atomic. This is not a crash-atomic transaction across multiple files.
enum AppDataFileRestore {
    static func apply(_ changes: [AppDataFileChange], recoveryDirectory: URL,
                      write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        for change in changes {
            guard try AppDataFileChange.read(change.url) == change.original else {
                throw AppDataBackupError.invalid("App data changed after review. Review the backup again.")
            }
        }
        let manager = FileManager.default
        try manager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        for (index, change) in changes.enumerated() {
            if let original = change.original {
                try original.write(to: recoveryDirectory.appendingPathComponent("\(index)-\(change.url.lastPathComponent)"), options: .withoutOverwriting)
            }
        }
        let note = changes.enumerated().map { "\($0.offset): \($0.element.url.lastPathComponent) — \($0.element.original == nil ? "originally absent" : "original bytes preserved")" }.joined(separator: "\n")
        try Data(note.utf8).write(to: recoveryDirectory.appendingPathComponent("recovery.txt"), options: .withoutOverwriting)
        var attempted: [AppDataFileChange] = []
        do {
            for change in changes {
                try manager.createDirectory(at: change.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                attempted.append(change)
                try write(change.replacement, change.url)
            }
        } catch {
            let failure = error
            var rollbackFailed = false
            for change in attempted.reversed() {
                do {
                    if let original = change.original { try original.write(to: change.url, options: .atomic) }
                    else if manager.fileExists(atPath: change.url.path) { try manager.removeItem(at: change.url) }
                } catch { rollbackFailed = true }
            }
            throw AppDataBackupError.invalid("Restore failed: \(failure.localizedDescription) \(rollbackFailed ? "Some original files could not be restored." : "The original files were restored.") Recovery files: \(recoveryDirectory.path)")
        }
    }
}
