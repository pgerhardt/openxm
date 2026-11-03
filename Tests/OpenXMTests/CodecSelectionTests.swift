import Foundation
import Testing
@testable import OpenXM

struct CodecSelectionTests {
    private func event(_ json: String) throws -> CodecTransportEvent {
        try JSONDecoder().decode(CodecTransportEvent.self, from: Data(json.utf8))
    }

    @Test func requestedCodecAloneIsNeverConfirmation() throws {
        let pending = try event(#"{"event":"status","requested":"ldac","phase":"connecting","activeCodec":"ldac","sampleRate":48000}"#)
        #expect(pending.confirmedCodec == nil)
        let omitted = try event(#"{"event":"status","requested":"ldac","phase":"streaming","sampleRate":48000}"#)
        #expect(omitted.confirmedCodec == nil)
        let rejected = try event(#"{"event":"stopped","requested":"ldac","activeCodec":"ldac","sampleRate":48000}"#)
        #expect(rejected.confirmedCodec == nil)
    }

    @Test func activeCodecCanDifferFromPreferenceAndRoute() throws {
        let fallback = try event(#"{"event":"status","requested":"ldac","phase":"streaming","activeCodec":"sbc","sampleRate":44100,"routed":false}"#)
        #expect(fallback.requested == .ldac)
        #expect(fallback.confirmedCodec == .sbc)
        #expect(fallback.routed == false) // Negotiation and output selection are separate evidence.
        let idle = try event(#"{"event":"status","phase":"idle","activeCodec":"aptx-hd","sampleRate":48000}"#)
        #expect(idle.confirmedCodec == .aptXHD)
    }

    @Test func malformedEvidenceIsRejected() throws {
        for rate in [0, -1, 999_999] {
            let bad = try event("{\"event\":\"status\",\"phase\":\"streaming\",\"activeCodec\":\"aac\",\"sampleRate\":\(rate)}")
            #expect(bad.confirmedCodec == nil)
        }
        #expect(throws: (any Error).self) { try event(#"{"event":"status","routed":2}"#) }
        #expect(throws: (any Error).self) { try event(#"{"event":"status","activeCodec":"aptx-adaptive"}"#) }
        #expect(try event(#"{"event":"inspection","driverInstalled":1}"#).driverInstalled == true)
        #expect(try event(#"{"event":"stopped","routeRestored":false}"#).routeRestored == false)
    }

    @Test func automaticDoesNotInventANegotiatedCodec() {
        #expect(CodecSelection.automatic.audioCodec == nil)
        #expect(CodecSelection.allCases.compactMap(\.audioCodec) == [.sbc, .aac, .aptX, .aptXHD, .ldac])
    }

    @Test func bitrateDistinguishesMeasuredThroughputFromEncoderTarget() throws {
        let live = try event(#"{"event":"status","phase":"streaming","activeCodec":"ldac","sampleRate":44100,"recentKbps":618.4,"targetKbps":606}"#)
        #expect(live.measuredBitrateKbps == 618.4)
        #expect(live.encoderTargetKbps == 606)
        let pending = try event(#"{"event":"status","phase":"connecting","activeCodec":"ldac","sampleRate":44100,"recentKbps":918,"targetKbps":909}"#)
        #expect(pending.measuredBitrateKbps == nil && pending.encoderTargetKbps == nil)
        let idle = try event(#"{"event":"status","phase":"idle","activeCodec":"ldac","sampleRate":44100,"recentKbps":918,"targetKbps":606}"#)
        #expect(idle.measuredBitrateKbps == 0)
        #expect(idle.encoderTargetKbps == 606)
    }

    @Test func missingInvalidAndZeroBitratesAreDistinct() throws {
        for fields in ["", #", "recentKbps":-1,"targetKbps":-1"#] {
            let unavailable = try event(#"{"event":"status","phase":"streaming","activeCodec":"aac","sampleRate":44100"# + fields + "}")
            #expect(unavailable.measuredBitrateKbps == nil && unavailable.encoderTargetKbps == nil)
        }
        let zero = try event(#"{"event":"status","phase":"streaming","activeCodec":"aac","sampleRate":44100,"recentKbps":0,"targetKbps":0}"#)
        #expect(zero.measuredBitrateKbps == 0)
        #expect(zero.encoderTargetKbps == nil)
    }

    @Test func volumeRequiresCurrentValidHeadphoneEvidence() throws {
        for volume in [0, 33, 127] {
            let live = try event("{\"event\":\"status\",\"phase\":\"streaming\",\"activeCodec\":\"ldac\",\"sampleRate\":44100,\"volumeSynced\":true,\"volume\":\(volume)}")
            #expect(live.confirmedVolume == volume)
        }
        for fields in [#""volume":-1,"volumeSynced":true"#, #""volume":128,"volumeSynced":true"#,
                       #""volume":33,"volumeSynced":false"#, #""volumeSynced":true"#] {
            let bad = try event(#"{"event":"status","phase":"streaming","activeCodec":"ldac","sampleRate":44100,"# + fields + "}")
            #expect(bad.confirmedVolume == nil)
        }
        let connecting = try event(#"{"event":"status","phase":"connecting","activeCodec":"ldac","sampleRate":44100,"volumeSynced":true,"volume":33}"#)
        #expect(connecting.confirmedVolume == nil)
    }

    @Test func ldacQualityLabelsFollowTheSampleRateFamily() throws {
        #expect(LDACQuality.allCases.map { $0.targetKbps(at: 44100) } == [nil, 909, 606, 303])
        #expect(LDACQuality.allCases.map { $0.targetKbps(at: 48000) } == [nil, 990, 660, 330])
        #expect(LDACQuality.medium.title(at: 44100) == "Medium · 606 kbps")
        #expect(throws: (any Error).self) { try event(#"{"event":"status","ldacQuality":3}"#) }
    }
}
