import Foundation
import Testing
@testable import SoundConnect

struct FramingTests {
    // Literal V1 battery packet, independently derived from the documented wire format.
    @Test func legacyBatteryGoldenPacket() throws {
        let wire: [UInt8] = [0x3e,0x0c,0x00,0,0,0,2,0x10,0x00,0x1e,0x3c]
        let frame = MDRFrame(type: .dataMdr, sequence: 0, payload: [0x10, 0x00])
        #expect(frame.encoded() == wire)
        #expect(try MDRFrame.decode(body: wire[1..<10]) == frame)
        // 0x22 is POWER OFF on V1, never the battery inquiry.
        #expect(frame.payload.first != 0x22)
    }
    @Test func escapedMarkersRoundTripAcrossEverySplit() throws {
        let frame = MDRFrame(type: .dataMdr, sequence: 1, payload: [0x3c,0x3d,0x3e,0,255])
        let wire = frame.encoded()
        for split in 0...wire.count {
            var assembler = MDRFrameAssembler()
            let outputs = assembler.append(Array(wire[..<split])) + assembler.append(Array(wire[split...]))
            #expect(outputs.count == 1)
            if case .frame(let decoded, _) = outputs.first { #expect(decoded == frame) }
            else { Issue.record("Fragmented packet was not decoded") }
        }
    }
    @Test func corruptedPrefixDoesNotEatNextValidFrame() {
        var assembler = MDRFrameAssembler()
        let frame = MDRFrame(type: .dataMdr, sequence: 0, payload: [0x11,0,84,0])
        let results = assembler.append([0x42,0x3e,0x0c,0,0] + frame.encoded())
        #expect(results.count == 1)
        if case .frame(let actual, _) = results.first { #expect(actual == frame) }
        else { Issue.record("Did not recover at the next start marker") }
    }
    @Test func badChecksumAndTruncatedEscapeAreRejected() {
        #expect(throws: (any Error).self) { try MDRFrame.decode(body: [0x0c,0,0,0,0,2,0x10,0,0xff][...]) }
        #expect(throws: (any Error).self) { try MDRFrame.decode(body: [0x3d][...]) }
        #expect(throws: (any Error).self) { try MDRFrame.decode(body: [0x3d,0x01][...]) }
        #expect(throws: (any Error).self) { try MDRFrame.decode(body: [0x0c,0,0,0,0,4,0x10,0,0x20][...]) }
    }
    @Test func byteReaderRejectsInvalidBoundsWithoutTrapping() {
        var negative = ByteReader([1], offset: -1)
        #expect(throws: (any Error).self) { try negative.u8() }
        #expect(throws: (any Error).self) { try negative.take(1) }
        var huge = ByteReader([1], offset: 1)
        #expect(throws: (any Error).self) { try huge.take(Int.max) }
    }
}

@MainActor struct LegacyHeadphoneTests {
    @Test func xm3AndXm4ReadbackPreservesAmbientLevel() {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        func receive(_ payload: [UInt8]) { driver.handle(MDRFrame(type: .dataMdr, sequence: 0, payload: payload)) }
        // Layout agrees with SonyBridge and sony-device-center V1 getNoiseControl.
        receive([0x67,0x02,0x11,0x01,0x00,0x01,0x01,12])
        #expect(state.noise?.mode == .ambient)
        #expect(state.noise?.ambientLevel == 12)
        #expect(state.noise?.focusOnVoice == true)
        receive([0x67,0x02,0x11,0x01,0x02,0x01,0,0])
        #expect(state.noise?.mode == .noiseCancelling)
        #expect(state.noise?.ambientLevel == 12)
        receive([0x67,0x02,0,0x01,0x02,0x01,0,0])
        #expect(state.noise?.mode == .off)
        #expect(state.noise?.ambientLevel == 12)
    }
    @Test func v1BatteryAndSixValueEqualizerDecode() {
        let state = DeviceState()
        let driver = V1Driver(link: MDRLink(transport: nil), state: state)
        driver.handle(MDRFrame(type:.dataMdr, sequence:0, payload:[0x11,0,84,0]))
        #expect(state.battery.headlineLevel == 84)
        driver.handle(MDRFrame(type:.dataMdr, sequence:0, payload:[0x57,1,0xa0,6,12,10,12,13,11,9]))
        #expect(state.equalizer?.clearBass == 2)
        #expect(state.equalizer?.bands == [0,2,3,1,-1])
        driver.handle(MDRFrame(type:.dataMdr, sequence:0, payload:[0x57,1,0xa0,6,12]))
        #expect(state.equalizer?.bands == [0,2,3,1,-1])
    }
    @Test func previewCannotWriteOrApplyScenes() async {
        let controller = HeadphoneController()
        controller.startDemo()
        #expect(controller.isDemo)
        #expect(!controller.canWrite)
        let before = controller.state.noise
        controller.requestNoise { $0.mode = .off }
        controller.apply(.upscaling(false))
        #expect(controller.state.noise == before)
        #expect(controller.state.upscaling?.enabled == true)
        let store = SceneStore(controller: controller, fileURL: URL(fileURLWithPath: "/tmp/soundconnect-test-unused.json"))
        #expect(!store.canApply(SceneStore.starterScenes[0]))
    }
}
