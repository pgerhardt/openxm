import Foundation

/// Advances a player's reported position locally between metadata events, without polling the player.
struct PlaybackProgress: Equatable {
    let elapsed: TimeInterval
    let duration: TimeInterval

    var fraction: Double { elapsed / duration }
    var percentComplete: Int { Int((fraction * 100).rounded(.down)) }
    var elapsedText: String { Self.timeText(elapsed) }
    var durationText: String { Self.timeText(duration) }

    init?(elapsedTime: TimeInterval?, duration: TimeInterval?, timestamp: Date?,
          playbackRate: Double?, playing: Bool, at date: Date) {
        guard let elapsedTime, elapsedTime.isFinite,
              let duration, duration.isFinite, duration > 0 else { return nil }
        var position = max(0, elapsedTime)
        let rate = playbackRate ?? 1
        if playing, rate.isFinite, rate > 0, let timestamp {
            let interval = date.timeIntervalSince(timestamp)
            if interval.isFinite { position += max(0, interval) * rate }
        }
        self.elapsed = min(duration, position)
        self.duration = duration
    }

    private static func timeText(_ time: TimeInterval) -> String {
        guard let seconds = Int(exactly: time.rounded(.down)) else { return "—:—" }
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
