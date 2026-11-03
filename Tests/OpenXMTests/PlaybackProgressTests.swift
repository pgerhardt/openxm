import Foundation
import Testing
@testable import OpenXM

@MainActor
struct PlaybackProgressTests {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000.25)

    private func progress(elapsed: Double? = 40.25, duration: Double? = 228.527,
                          rate: Double? = nil, playing: Bool = true, after: Double = 4.75) -> PlaybackProgress? {
        PlaybackProgress(elapsedTime: elapsed, duration: duration, timestamp: timestamp,
                         playbackRate: rate, playing: playing, at: timestamp.addingTimeInterval(after))
    }

    @Test func positionAdvancesFromThePlayersTimestampAtItsPlaybackRate() throws {
        let normal = try #require(progress())
        #expect(normal.elapsed == 45)
        #expect(normal.elapsedText == "0:45")
        #expect(normal.durationText == "3:48")
        #expect(abs(normal.fraction - 45 / 228.527) < 0.000_001)
        #expect(normal.percentComplete == 19)
        #expect(progress(rate: 2)?.elapsed == 49.75)
        #expect(progress(rate: 0.5)?.elapsed == 42.625)
    }

    @Test func pausedAndStoppedClocksDoNotAdvance() {
        #expect(progress(playing: false, after: 100)?.elapsed == 40.25)
        for rate in [0.0, -1, .nan, .infinity] {
            #expect(progress(rate: rate, after: 100)?.elapsed == 40.25)
        }
        let noTimestamp = PlaybackProgress(elapsedTime: 45, duration: 228, timestamp: nil,
                                           playbackRate: 1, playing: true, at: timestamp)
        #expect(noTimestamp?.elapsed == 45)
    }

    @Test func missingAndInvalidTimingNeverInventsProgress() {
        #expect(progress(elapsed: nil) == nil)
        #expect(progress(duration: nil) == nil)
        for invalid in [0.0, -1, .nan, .infinity] {
            #expect(progress(duration: invalid) == nil)
        }
        #expect(progress(elapsed: .nan) == nil)
        #expect(progress(elapsed: .infinity) == nil)
    }

    @Test func positionStaysWithinTheTrackAndHandlesClockChanges() {
        #expect(progress(elapsed: -10, playing: false)?.elapsed == 0)
        #expect(progress(after: -100)?.elapsed == 40.25)
        #expect(progress(after: 1_000)?.elapsed == 228.527)
        #expect(progress(after: 1_000)?.percentComplete == 100)
        #expect(progress(elapsed: 300, playing: false)?.fraction == 1)
        #expect(progress(elapsed: 228, after: 0)?.percentComplete == 99)
    }

    @Test func elapsedAndTotalTimesSupportLongMedia() {
        let long = progress(elapsed: 3_661, duration: 7_200, playing: false)
        #expect(long?.elapsedText == "1:01:01")
        #expect(long?.durationText == "2:00:00")
        #expect(progress(elapsed: 0, playing: false)?.elapsedText == "0:00")
        #expect(progress(elapsed: 59.999, playing: false)?.elapsedText == "0:59")
    }

    @Test func streamTimingDecodesAndSeeksPauseResumeAndTrackChangesReplaceIt() throws {
        let reader = SystemNowPlaying()
        func receive(elapsed: Double?, playing: Bool, title: String = "Track") throws {
            var payload: [String: Any] = ["bundleIdentifier": "test.player", "title": title, "playing": playing]
            if let elapsed {
                payload["elapsedTimeMicros"] = elapsed * 1_000_000
                payload["durationMicros"] = 228_527_000
                payload["timestampEpochMicros"] = timestamp.timeIntervalSince1970 * 1_000_000
                payload["playbackRate"] = 1
            }
            reader.consume(try JSONSerialization.data(withJSONObject: ["type": "data", "diff": false, "payload": payload]))
        }
        let now = timestamp.addingTimeInterval(4.75)
        try receive(elapsed: 40.25, playing: true)
        #expect(reader.item?.progress(at: now)?.elapsed == 45)
        let original = try #require(reader.item)
        try receive(elapsed: 120, playing: true)
        #expect(reader.item?.progress(at: now)?.elapsed == 124.75)
        #expect(reader.item?.sameContentAndPlayer(as: original) == true)
        try receive(elapsed: 30, playing: false)
        #expect(reader.item?.progress(at: now)?.elapsed == 30)
        try receive(elapsed: 30, playing: true)
        #expect(reader.item?.progress(at: now)?.elapsed == 34.75)
        try receive(elapsed: nil, playing: true, title: "Live stream")
        #expect(reader.item?.title == "Live stream")
        #expect(reader.item?.progress(at: now) == nil)
        reader.consume(Data(#"{"type":"data","diff":false,"payload":{}}"#.utf8))
        #expect(reader.item == nil)
    }
}
