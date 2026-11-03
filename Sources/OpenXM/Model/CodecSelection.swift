import Foundation

enum LDACQuality: Int, CaseIterable, Codable, Identifiable, Sendable {
    case adaptive = -1, high = 0, medium = 1, low = 2
    var id: Int { rawValue }
    var title: String {
        switch self { case .adaptive: "Auto"; case .high: "High"; case .medium: "Medium"; case .low: "Low" }
    }
    func targetKbps(at rate: Double) -> Int? {
        let family44 = rate == 44_100 || rate == 88_200
        switch self {
        case .adaptive: return nil
        case .high: return family44 ? 909 : 990
        case .medium: return family44 ? 606 : 660
        case .low: return family44 ? 303 : 330
        }
    }
    func title(at rate: Double) -> String { targetKbps(at: rate).map { "\(title) · \($0) kbps" } ?? title }
}

enum CodecSampleRate: Int, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = 0, hz44100 = 44100, hz48000 = 48000
    var id: Int { rawValue }
    var title: String {
        switch self { case .automatic: "Auto (Mac output)"; case .hz44100: "44.1 kHz"; case .hz48000: "48 kHz" }
    }
}

struct CodecAdvancedSettings: Codable, Equatable, Sendable {
    var ldacQuality: LDACQuality = .adaptive
    var sampleRate: CodecSampleRate = .automatic
    var fastRecovery = false
    func wire(revision: Int) -> [String: Any] {
        ["revision": revision, "ldacQuality": ldacQuality.rawValue, "sampleRate": sampleRate.rawValue, "fastRecovery": fastRecovery]
    }
}

enum CodecSelection: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, sbc, aac, aptX = "aptx", aptXHD = "aptx-hd", ldac
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic (macOS)"
        case .sbc: "SBC"
        case .aac: "AAC"
        case .aptX: "aptX"
        case .aptXHD: "aptX HD"
        case .ldac: "LDAC"
        }
    }
    var audioCodec: AudioCodec? {
        switch self {
        case .automatic: nil
        case .sbc: .sbc
        case .aac: .aac
        case .aptX: .aptX
        case .aptXHD: .aptXHD
        case .ldac: .ldac
        }
    }
}

/// Wire evidence comes from a fresh helper session, not from the user's preference
/// or a cached Sony reply. The parent rejects events from superseded processes.
struct CodecTransportEvent: Decodable, Sendable {
    let event: String
    var requested: CodecSelection?
    var phase: String?
    var activeCodec: CodecSelection?
    var sampleRate: Double?
    var recentKbps: Double?
    var targetKbps: Double?
    var headsetReportedDelayMs: Double?
    var estimatedOutputDelayMs: Double?
    var routed: Bool?
    var routeRestored: Bool?
    var playbackBlocked: Bool?
    var driverInstalled: Bool?
    var volumeSynced: Bool?
    var volume: Int?
    var settingsRevision: Int?
    var ldacQuality: LDACQuality?
    var fastRecovery: Bool?
    var message: String?
    var codecs: [String]?

    enum CodingKeys: String, CodingKey {
        case event, requested, phase, activeCodec, sampleRate, recentKbps, targetKbps, headsetReportedDelayMs
        case estimatedOutputDelayMs, routed, routeRestored, driverInstalled, volumeSynced, volume, message, codecs
        case settingsRevision, ldacQuality, fastRecovery, playbackBlocked
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        event = try values.decode(String.self, forKey: .event)
        requested = try values.decodeIfPresent(CodecSelection.self, forKey: .requested)
        phase = try values.decodeIfPresent(String.self, forKey: .phase)
        activeCodec = try values.decodeIfPresent(CodecSelection.self, forKey: .activeCodec)
        sampleRate = try values.decodeIfPresent(Double.self, forKey: .sampleRate)
        recentKbps = try values.decodeIfPresent(Double.self, forKey: .recentKbps)
        targetKbps = try values.decodeIfPresent(Double.self, forKey: .targetKbps)
        headsetReportedDelayMs = try values.decodeIfPresent(Double.self, forKey: .headsetReportedDelayMs)
        estimatedOutputDelayMs = try values.decodeIfPresent(Double.self, forKey: .estimatedOutputDelayMs)
        // Objective-C's boxed C comparisons encode as 0/1; accept only those values.
        func boolean(_ key: CodingKeys) throws -> Bool? {
            guard values.contains(key), try !values.decodeNil(forKey: key) else { return nil }
            if let value = try? values.decode(Bool.self, forKey: key) { return value }
            let value = try values.decode(Int.self, forKey: key)
            guard value == 0 || value == 1 else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Expected boolean or 0/1")
            }
            return value == 1
        }
        routed = try boolean(.routed); routeRestored = try boolean(.routeRestored)
        playbackBlocked = try boolean(.playbackBlocked)
        driverInstalled = try boolean(.driverInstalled)
        volumeSynced = try boolean(.volumeSynced)
        volume = try values.decodeIfPresent(Int.self, forKey: .volume)
        settingsRevision = try values.decodeIfPresent(Int.self, forKey: .settingsRevision)
        ldacQuality = try values.decodeIfPresent(LDACQuality.self, forKey: .ldacQuality)
        fastRecovery = try boolean(.fastRecovery)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        codecs = try values.decodeIfPresent([String].self, forKey: .codecs)
    }

    var confirmedCodec: AudioCodec? {
        guard event == "status", phase == "streaming" || phase == "idle",
              let sampleRate, sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { return nil }
        return activeCodec?.audioCodec
    }

    var measuredBitrateKbps: Double? {
        guard confirmedCodec != nil else { return nil }
        // Suspension is fresh evidence of no media transfer, even if an old counter remains.
        if phase == "idle" { return 0 }
        guard let recentKbps, recentKbps.isFinite, recentKbps >= 0 else { return nil }
        return recentKbps
    }

    var confirmedVolume: Int? {
        guard confirmedCodec != nil, volumeSynced == true, let volume, (0...127).contains(volume) else { return nil }
        return volume
    }

    var encoderTargetKbps: Double? {
        guard confirmedCodec != nil, let targetKbps, targetKbps.isFinite, targetKbps > 0 else { return nil }
        return targetKbps
    }
}
