import Foundation
import Observation
import os
import Testing
@testable import OpenXM

@MainActor struct PlaybackMetadataTests {
    private func name(_ text: String, status: UInt8 = 2) -> [UInt8] {
        [status, UInt8(text.utf8.count)] + Array(text.utf8)
    }
    private func frame(_ payload: [UInt8], table: MDRDataType = .dataMdr) -> MDRFrame {
        .init(type: table, sequence: 0, payload: payload)
    }
    private func v1(_ driver: V1Driver, detail: UInt8, text: String, status: UInt8 = 2) {
        driver.handle(frame([0xA7, 1, detail] + name(text, status: status)))
    }
    private func v1Snapshot(_ driver: V1Driver) {
        v1(driver, detail: 0, text: "Old title")
        v1(driver, detail: 1, text: "Old album")
        v1(driver, detail: 2, text: "Old artist")
    }
    private func v2Payload() -> [UInt8] {
        [0xA7, 1] + name("Title 🎵") + name("Album") + name("Zoë / Böhmer") + name("Electronic")
    }

    @Test func v1PublishesOnlyCompleteSnapshotsAndPreservesUnicodeBytes() {
        let state = DeviceState(), link = MDRLink(transport: nil)
        let driver = V1Driver(link: link, state: state)
        v1Snapshot(driver)
        #expect(state.nowPlaying.artist == "Old artist")
        v1(driver, detail: 0, text: "新曲 🎵")
        #expect(state.nowPlaying.metadata == nil)
        v1(driver, detail: 1, text: "", status: 1)
        #expect(state.nowPlaying.metadata == nil)
        let decomposed = "Bo\u{308}hmer"
        v1(driver, detail: 2, text: decomposed)
        #expect(state.nowPlaying.title == "新曲 🎵")
        #expect(state.nowPlaying.album == nil)
        #expect(state.nowPlaying.artist == "Böhmer")
        #expect(Array(state.nowPlaying.artist!.utf8) == Array(decomposed.utf8))
        #expect(state.nowPlaying.metadataReportedAt != nil)
    }

    @Test func v1TrackNotificationAndOutOfOrderRepliesCannotMixTracks() {
        let state = DeviceState()
        // Each fixture below uses one shared state; no physical connection or refresh task sends data.
        let live = V1Driver(link: MDRLink(transport: nil), state: state)
        v1Snapshot(live)
        live.handle(frame([0xA9, 1, 0]))
        #expect(state.nowPlaying.metadata == nil)
        v1(live, detail: 1, text: "Late album")
        v1(live, detail: 2, text: "Late artist")
        #expect(state.nowPlaying.metadata == nil)
        v1(live, detail: 0, text: "New title")
        live.handle(frame([0xA9, 1, 2]))
        v1(live, detail: 1, text: "New album")
        v1(live, detail: 2, text: "New artist")
        #expect(state.nowPlaying.metadata == nil)
        v1(live, detail: 0, text: "Next title")
        v1(live, detail: 2, text: "Out of order")
        v1(live, detail: 1, text: "Album")
        #expect(state.nowPlaying.metadata == nil)
    }

    @Test func v1MalformedAndUnsettledTextInvalidatesAllFields() {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        for payload: [UInt8] in [[0xA7, 1], [0xA7, 1, 0], [0xA7, 1, 0, 2, 2, 0xC3],
                                [0xA7, 1, 0, 2, 1, 0xFF], [0xA7, 1, 0, 0xFF, 0],
                                [0xA7, 1, 0, 2, 0, 0], [0xA7, 1, 0, 0, 0], [0xA9, 1, 0, 0]] {
            v1Snapshot(driver)
            driver.handle(frame(payload))
            #expect(state.nowPlaying.metadata == nil && state.nowPlaying.metadataReportedAt == nil)
            v1(driver, detail: 1, text: "Late album")
            v1(driver, detail: 2, text: "Late artist")
            #expect(state.nowPlaying.metadata == nil)
        }
    }

    @Test func v1BatchCannotBridgeTimeoutsClockChangesOrAReset() {
        let time = Date(timeIntervalSince1970: 1000)
        for elapsed in [-1.0, 15.0, 100.0] {
            var batch = V1PlaybackMetadataBatch()
            #expect(batch.receive(detail: 0, name: .settled("Title"), at: time) == nil)
            #expect(batch.receive(detail: 1, name: .settled("Album"), at: time.addingTimeInterval(elapsed)) == nil)
            #expect(batch.receive(detail: 2, name: .settled("Artist"), at: time.addingTimeInterval(elapsed)) == nil)
        }
        var batch = V1PlaybackMetadataBatch()
        _ = batch.receive(detail: 0, name: .settled("Title"), at: time)
        batch.reset() // Same invalidation used when an optional request times out or transport closes.
        _ = batch.receive(detail: 1, name: .nothing, at: time)
        #expect(batch.receive(detail: 2, name: .nothing, at: time) == nil)
    }

    @Test func unrelatedSelectorsVolumeAndStatusDoNotChangeMetadataFreshness() throws {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        v1Snapshot(driver)
        let value = state.nowPlaying.metadata, time = try #require(state.nowPlaying.metadataReportedAt)
        for payload: [UInt8] in [[0xA7, 2, 0, 2, 0], [0xA9, 1, 0x20, 8], [0xA7, 1, 3, 2, 0], [0xA3, 1, 0, 1]] {
            driver.handle(frame(payload))
        }
        driver.handle(frame([0xA9, 1, 0], table: .dataMdrNo2))
        #expect(state.nowPlaying.metadata == value && state.nowPlaying.metadataReportedAt == time)
        #expect(state.nowPlaying.volume == 8)
        state.nowPlaying.expireMetadata(at: time.addingTimeInterval(89))
        #expect(state.nowPlaying.metadata == value)
        state.nowPlaying.expireMetadata(at: time.addingTimeInterval(90))
        #expect(state.nowPlaying.metadata == nil)
        #expect(state.nowPlaying.status == .playing && state.nowPlaying.volume == 8)
        state.nowPlaying.receiveMetadata(value, at: time)
        state.nowPlaying.expireMetadata(at: time.addingTimeInterval(-1))
        #expect(state.nowPlaying.metadata == nil)
    }

    @Test func expiryDoesNotTriggerAnObservationLoopWhenNoMetadataChanges() {
        let state = DeviceState(), time = Date(timeIntervalSince1970: 1000)
        state.nowPlaying.receiveMetadata(.init(title: "Title"), at: time)
        // A thread-safe counter also satisfies Observation's Sendable callback contract.
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = state.nowPlaying } onChange: { changes.withLock { $0 += 1 } }
        state.expirePlaybackMetadata(at: time.addingTimeInterval(15))
        #expect(changes.withLock { $0 } == 0)
        state.expirePlaybackMetadata(at: time.addingTimeInterval(90))
        #expect(changes.withLock { $0 } == 1 && state.nowPlaying.metadata == nil)
        changes.withLock { $0 = 0 }
        withObservationTracking { _ = state.nowPlaying } onChange: { changes.withLock { $0 += 1 } }
        state.expirePlaybackMetadata(at: time.addingTimeInterval(105))
        #expect(changes.withLock { $0 } == 0)
    }

    @Test func v2UsesAllFourFieldsAndReplacesAbsentValues() {
        let state = DeviceState()
        let driver = V2Driver(link: MDRLink(transport: nil), state: state)
        driver.handle(frame(v2Payload()))
        #expect(state.nowPlaying.title == "Title 🎵")
        #expect(state.nowPlaying.artist == "Zoë / Böhmer")
        driver.handle(frame([0xA9, 1] + name("Next") + name("", status: 1) + name("", status: 1) + name("", status: 1)))
        #expect(state.nowPlaying.title == "Next")
        #expect(state.nowPlaying.album == nil && state.nowPlaying.artist == nil)
    }

    @Test func v2TruncatedFourthNameInvalidUtf8UnsettledAndTrailingBytesClearTheSnapshot() {
        let state = DeviceState()
        let driver = V2Driver(link: MDRLink(transport: nil), state: state)
        let good = v2Payload()
        let invalid = [Array(good.dropLast()), good + [0], [0xA7, 1],
                       [0xA7, 1] + name("Title") + name("Album") + name("Artist"),
                       [0xA9, 1] + name("Title") + name("", status: 0) + name("Artist") + name("Genre"),
                       [0xA7, 1] + name("Title") + name("Album") + name("Artist") + [2, 1, 0xFF]]
        for payload in invalid {
            driver.handle(frame(good))
            driver.handle(frame(payload))
            #expect(state.nowPlaying.metadata == nil && state.nowPlaying.metadataReportedAt == nil)
        }
        driver.handle(frame(good))
        let before = state.nowPlaying
        driver.handle(frame([0xA9, 2]))
        driver.handle(frame([0xA9, 1], table: .dataMdrNo2))
        #expect(state.nowPlaying == before)
    }
}
