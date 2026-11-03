import Foundation
import Testing
@testable import OpenXM

struct AudioConnectionTests {
    @Test func uidMustMatchExactHeadphoneAndDirection() {
        #expect(MacAudioConnection.matchesUID("AA:BB:CC:DD:EE:FF:input", address: "aa-bb-cc-dd-ee-ff", direction: "input"))
        #expect(MacAudioConnection.matchesUID("AA-BB-CC-DD-EE-FF:output", address: "AA:BB:CC:DD:EE:FF", direction: "output"))
        for uid in ["AA:BB:CC:DD:EE:FF:input", "00:BB:CC:DD:EE:FF:output", "WH-1000XM3", "AA:BB:CC:DD:EE:FF:output-extra"] {
            #expect(!MacAudioConnection.matchesUID(uid, address: "AA:BB:CC:DD:EE:FF", direction: "output"))
        }
        #expect(!MacAudioConnection.matchesUID("bogus:output", address: "bogus", direction: "output"))
    }

    @Test func activityRequiresRunningProcessOnExactDeviceAndPreservesUnknown() {
        #expect(AudioProcessActivity.uses([7], processes: [.init(running: 0, devices: [7])]) == false)
        #expect(AudioProcessActivity.uses([7], processes: [.init(running: 1, devices: [8])]) == false)
        #expect(AudioProcessActivity.uses([7], processes: [.init(running: 1, devices: [8, 7])]) == true)
        #expect(AudioProcessActivity.uses([7], processes: [.init(running: 1, devices: nil)]) == nil)
        #expect(AudioProcessActivity.uses([7], processes: [.init(running: nil, devices: [7])]) == nil)
        #expect(AudioProcessActivity.uses([7], processes: nil) == nil)
        #expect(AudioProcessActivity.uses([7], processes: [.init(running: nil, devices: nil), .init(running: 1, devices: [7])]) == true)
    }

    @Test func handsFreeInferenceRequiresBothMicAndLowRateMono() {
        var route = MacAudioConnection(outputFound: true, isDefaultOutput: true, outputInUse: true,
                                       headphoneMicInUse: false, sampleRate: 44_100, channels: 2)
        #expect(!route.likelyHandsFree)
        #expect(AudioConnectionPresentation(codec: .aac, route: route).badge == "AAC")
        route.headphoneMicInUse = true
        #expect(!route.likelyHandsFree) // Mic activity alone does not prove the profile or speech codec.
        #expect(AudioConnectionPresentation(codec: .aac, route: route).badge == "Mic in use")
        route.sampleRate = 16_000; route.channels = 1
        #expect(route.likelyHandsFree)
        let call = AudioConnectionPresentation(codec: .aac, route: route)
        #expect(call.badge == "Call audio" && call.codecLabel == "AAC")
        route.headphoneMicInUse = nil
        #expect(!route.likelyHandsFree)
        route.headphoneMicInUse = false
        #expect(!route.likelyHandsFree)
        route.sampleRate = .nan
        #expect(route.formatDescription == "Unavailable")
    }

    @Test func unknownCodecAndRouteDoNotClaimHighResolution() {
        #expect(AudioConnectionPresentation(codec: nil, route: nil).codecLabel == "Not reported")
        #expect(AudioConnectionPresentation(codec: .unsettled, route: nil).codecLabel == "Not reported")
        #expect(AudioConnectionPresentation(codec: .other, route: nil).codecLabel == "Other")
        let route = MacAudioConnection(outputFound: true, isDefaultOutput: false, outputInUse: true)
        #expect(route.routeDescription == "Headphones in use") // A per-app route can differ from the default.
        #expect(route.micDescription == "Unable to verify")
    }

    @MainActor @Test func codecRepliesCoverFamiliesUnknownValuesAndMalformedUpdates() {
        for family in [ProtocolFamily.v1, .v2] {
            let state = DeviceState()
            let link = MDRLink(transport: nil)
            let driver: HeadphoneDriver = family == .v1 ? V1Driver(link: link, state: state) : V2Driver(link: link, state: state)
            let command: UInt8 = family == .v1 ? 0x19 : 0x13
            let selector: UInt8 = family == .v1 ? 0x00 : 0x02
            for raw: UInt8 in [0x00, 0x01, 0x02, 0x10, 0x20, 0x21, 0x30, 0xFE] {
                driver.handle(MDRFrame(type: .dataMdr, sequence: 0, payload: [command, selector, raw]))
                #expect(state.codec == AudioCodec(rawValue: raw) ?? .other)
            }
            driver.handle(MDRFrame(type: .dataMdr, sequence: 0, payload: [command, selector, 0x02]))
            driver.handle(MDRFrame(type: .dataMdrNo2, sequence: 0, payload: [command, selector, 0x10]))
            #expect(state.codec == .aac)
            driver.handle(MDRFrame(type: .dataMdr, sequence: 0, payload: [command, selector]))
            #expect(state.codec == nil)
        }
    }
}
