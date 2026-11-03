import Foundation
import Testing
@testable import OpenXM

@MainActor struct PlaybackHistoryTests {
    private func frame(_ payload: [UInt8], table: MDRDataType = .dataMdr) -> MDRFrame {
        .init(type: table, sequence: 0, payload: payload)
    }

    @Test func capturedXM3ReplyAndUnrelatedUpdates() throws {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        // Captured WH-1000XM3 2.0.0 reply; subsequent mutations are synthetic.
        driver.handle(frame([0xA3, 1, 0, 3]))
        let received = try #require(state.nowPlaying.statusReportedAt)
        #expect(state.nowPlaying.status == .stopped)
        driver.handle(frame([0xA7, 1, 0x20, 8]))
        driver.handle(frame([0xA7, 1, 0, 2, 4] + Array("Song".utf8)))
        driver.handle(frame([0xA7, 1, 1, 1, 0]))
        driver.handle(frame([0xA7, 1, 2, 1, 0]))
        driver.handle(frame([0x11, 0, 100, 0]))
        #expect(state.nowPlaying.statusReportedAt == received)
        #expect(state.nowPlaying.title == "Song" && state.nowPlaying.volume == 8)
        #expect(!state.nowPlaying.hasFreshListeningStatus(at: received.addingTimeInterval(90)))
        driver.handle(frame([0xA5, 1, 0, 1]))
        #expect(state.nowPlaying.status == .playing)
        #expect(state.nowPlaying.hasFreshListeningStatus(at: Date()))
        state.reset()
        #expect(state.nowPlaying.statusReportedAt == nil)
    }

    @Test func malformedDisabledAndUnknownV1ReportsInvalidateOldPlayingState() {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        for invalid: [UInt8] in [[0xA3, 1], [0xA5, 1, 0], [0xA3, 1, 0, 1, 0],
                                 [0xA5, 1, 1, 1], [0xA3, 1, 0xFF, 1], [0xA5, 1, 0, 0xFF]] {
            driver.handle(frame([0xA3, 1, 0, 1]))
            driver.handle(frame(invalid))
            #expect(state.nowPlaying.status == nil)
            #expect(state.nowPlaying.statusReportedAt == nil)
        }
        driver.handle(frame([0xA5, 1, 0, 1]))
        let saved = state.nowPlaying
        driver.handle(frame([0xA3, 2, 0, 3]))
        driver.handle(frame([0xA5, 1, 0, 3], table: .dataMdrNo2))
        #expect(state.nowPlaying == saved)
    }

    @Test func v2MusicAndCallReportsRemainDistinct() {
        let state = DeviceState()
        let driver = V2Driver(link: MDRLink(transport: nil), state: state)
        // Reference-derived V2 selector 01; these are not physical captures.
        driver.handle(frame([0xA3, 1, 0, 1, 0]))
        #expect(state.nowPlaying.hasFreshListeningStatus(at: Date()))
        driver.handle(frame([0xA5, 1, 0, 1, 1]))
        #expect(state.nowPlaying.status == .playing)
        #expect(!state.nowPlaying.hasFreshListeningStatus(at: Date()))
        for invalid: [UInt8] in [[0xA3, 1], [0xA5, 1, 0, 1], [0xA3, 1, 0, 1, 0, 0],
                                 [0xA5, 1, 1, 1, 0], [0xA3, 1, 0, 1, 0xFF], [0xA5, 1, 0, 0xFF, 0]] {
            driver.handle(frame([0xA3, 1, 0, 1, 0]))
            driver.handle(frame(invalid))
            #expect(state.nowPlaying.status == nil && state.nowPlaying.statusReportedAt == nil)
        }
    }

    @Test func missingPlaybackRepliesCannotKeepHistoryRunning() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-freshness-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let history = ListeningHistory(fileURL: file)
        history.setEnabled(true)
        history.setSessionsEnabled(true)
        let start = Date(timeIntervalSince1970: 100_000)
        var playback = NowPlaying()
        playback.receivePlaybackStatus(.playing, at: start)
        for second in stride(from: 0, through: 3600, by: 15) {
            // A healthy battery/metadata refresh used to renew the controller's general lastRefresh.
            playback.receiveMetadata(.init(title: "Update \(second)"))
            playback.volume = second % 30
            history.sample(device: "headphones", model: "WH-1000XM3", playback: playback,
                           at: start.addingTimeInterval(Double(second)))
        }
        #expect(history.total(on: start) == 75)
        #expect(history.sessions.count == 1 && history.sessions[0].seconds == 75 && history.activeSessionID == nil)
        // A new report resumes estimation without backfilling the unobserved gap.
        playback.receivePlaybackStatus(.playing, at: start.addingTimeInterval(3610))
        history.sample(device: "headphones", model: "WH-1000XM3", playback: playback, at: start.addingTimeInterval(3610))
        #expect(history.total(on: start) == 75)
        playback.receivePlaybackStatus(.paused, at: start.addingTimeInterval(3620))
        history.sample(device: "headphones", model: "WH-1000XM3", playback: playback, at: start.addingTimeInterval(3620))
        #expect(history.total(on: start) == 85)
        #expect(history.sessions.count == 2 && history.sessions[0].seconds == 10 && history.activeSessionID == nil)
        history.sample(device: "headphones", model: "WH-1000XM3", playback: playback, at: start.addingTimeInterval(3630))
        #expect(history.total(on: start) == 85)
    }

    @Test func unknownStatusAndClockChangesDoNotBecomeFreshMusic() {
        let date = Date(timeIntervalSince1970: 100_000)
        var playback = NowPlaying()
        #expect(!playback.hasFreshListeningStatus(at: date))
        playback.receivePlaybackStatus(.playing, at: date)
        #expect(!playback.hasFreshListeningStatus(at: date.addingTimeInterval(-1)))
        #expect(!playback.hasFreshListeningStatus(at: date.addingTimeInterval(90)))
        #expect(playback.hasFreshListeningStatus(at: date.addingTimeInterval(89)))
        playback.receivePlaybackStatus(.unsettled, at: date)
        #expect(!playback.hasFreshListeningStatus(at: date))
        playback.receivePlaybackStatus(nil, at: date)
        #expect(!playback.hasFreshListeningStatus(at: date))
    }
}
