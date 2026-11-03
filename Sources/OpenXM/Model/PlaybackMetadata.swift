import Foundation

/// One complete metadata observation. Optional fields are explicitly absent, never inherited.
struct PlaybackMetadata: Codable, Equatable, Sendable {
    var title: String?
    var album: String?
    var artist: String?
}

/// Sony's settled/nothing/unsettled names use a byte-length-prefixed UTF-8 string.
/// Unlike descriptive device labels, broken track text must not become replacement characters in history.
enum PlaybackName {
    case unsettled
    case nothing
    case settled(String)

    var value: String? {
        if case .settled(let text) = self, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text }
        else { nil }
    }

    var isSettled: Bool { if case .unsettled = self { false } else { true } }

    static func read(_ reader: inout ByteReader) throws -> Self {
        let status = try reader.u8()
        let length = Int(try reader.u8())
        let bytes = try reader.take(length)
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw DriverError.malformed("playback name UTF-8")
        }
        switch status {
        case 0: return .unsettled
        case 1: return .nothing
        case 2: return .settled(text)
        default: throw DriverError.malformed("playback name status")
        }
    }
}

/// V1 fetches title, album and artist separately. Publish only a complete ordered batch.
/// A notification, timeout, malformed field or out-of-order reply discards the whole batch.
struct V1PlaybackMetadataBatch {
    private var nextDetail: UInt8 = 0
    private var values: [String?] = []
    private var startedAt: Date?

    mutating func reset() { nextDetail = 0; values = []; startedAt = nil }

    mutating func receive(detail: UInt8, name: PlaybackName, at date: Date = Date()) -> PlaybackMetadata? {
        if detail == 0 { reset(); startedAt = date }
        guard let startedAt, date >= startedAt, date.timeIntervalSince(startedAt) < 15,
              detail == nextDetail, name.isSettled else { reset(); return nil }
        values.append(name.value)
        nextDetail += 1
        guard nextDetail == 3 else { return nil }
        let result = PlaybackMetadata(title: values[0], album: values[1], artist: values[2])
        reset()
        return result
    }
}

enum V2PlaybackMetadata {
    /// The reference layout contains four names. Validate the unused fourth field as well.
    static func decode(_ payload: [UInt8]) throws -> PlaybackMetadata? {
        guard payload.count >= 2, [0xA7, 0xA9].contains(payload[0]), payload[1] == 1 else {
            throw DriverError.malformed("playback metadata selector")
        }
        var reader = ByteReader(payload, offset: 2)
        var names: [PlaybackName] = []
        for _ in 0..<4 { names.append(try PlaybackName.read(&reader)) }
        guard reader.isAtEnd else { throw DriverError.malformed("playback metadata length") }
        guard names.allSatisfy(\.isSettled) else { return nil }
        return .init(title: names[0].value, album: names[1].value, artist: names[2].value)
    }
}
