import Foundation

struct AudioProcessActivity: Sendable {
    var running: UInt32?
    var devices: [UInt32]?

    static func uses(_ targetDevices: [UInt32], processes: [Self]?) -> Bool? {
        guard let processes, !targetDevices.isEmpty else { return nil }
        var complete = true
        for process in processes {
            guard let running = process.running, running == 0 || running == 1 else { complete = false; continue }
            guard running == 1 else { continue }
            guard let devices = process.devices else { complete = false; continue }
            if !Set(devices).isDisjoint(with: targetDevices) { return true }
        }
        return complete ? false : nil
    }
}

/// macOS's PCM format is separate from the encoded Bluetooth stream and the music service's source.
struct MacAudioConnection: Equatable, Sendable {
    var outputFound = false
    var isDefaultOutput: Bool?
    var outputInUse: Bool?
    var headphoneMicInUse: Bool?
    var defaultInputName: String?
    var sampleRate: Double?
    var channels: UInt32?

    var likelyHandsFree: Bool {
        headphoneMicInUse == true && channels == 1 && sampleRate.map { $0 > 0 && $0 <= 24_000 } == true
    }

    var formatDescription: String {
        guard let sampleRate, sampleRate.isFinite, sampleRate > 0, let channels, channels > 0 else { return "Unavailable" }
        let rate = (sampleRate / 1_000).formatted(.number.precision(.fractionLength(0...1)))
        let channelText = channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) channels"
        return "\(rate) kHz · \(channelText)"
    }

    var routeDescription: String {
        guard outputFound else { return "Headphone output not found" }
        if outputInUse == true { return "Headphones in use" }
        if isDefaultOutput == true { return "Headphones selected" }
        if isDefaultOutput == false, outputInUse == false { return "Headphones not in use" }
        return "Unable to verify activity"
    }

    var micDescription: String {
        switch headphoneMicInUse {
        case true?: "In use"
        case false?: "Not in use"
        case nil: "Unable to verify"
        }
    }

    /// Match an exact Bluetooth UID, never just a device name or a partial address.
    static func matchesUID(_ uid: String, address: String, direction: String) -> Bool {
        guard direction == "input" || direction == "output", uid.hasSuffix(":" + direction) else { return false }
        func normalized(_ value: String) -> String? {
            let hex = value.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").uppercased()
            return hex.utf8.count == 12 && hex.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) } ? hex : nil
        }
        guard let expected = normalized(address), let actual = normalized(String(uid.dropLast(direction.count + 1))) else { return false }
        return expected == actual
    }
}

struct AudioConnectionPresentation {
    let codec: AudioCodec?
    let route: MacAudioConnection?

    var headline: String {
        if route?.likelyHandsFree == true { return "Hands-free audio likely" }
        if route?.headphoneMicInUse == true { return "Headphone microphone in use" }
        if route?.outputFound == false { return "Mac audio route unavailable" }
        return "Bluetooth audio"
    }

    var badge: String {
        if route?.likelyHandsFree == true { return "Call audio" }
        if route?.headphoneMicInUse == true { return "Mic in use" }
        return codecLabel
    }

    var codecLabel: String {
        guard let codec, codec != .unsettled else { return "Not reported" }
        return codec.title
    }

    var hasMicWarning: Bool { route?.headphoneMicInUse == true }
}
