import Foundation
import Testing
@testable import OpenXM

@MainActor struct AlertAnswerTests {
    @Test func restartIsArmedBeforeTheAnswerCanCloseTheLink() async {
        let controller = HeadphoneController()
        let alert = DeviceAlert(messageType: 0x02, requiresAnswer: true)
        await controller.sendAlertAnswer(alert, accept: true) {
            #expect(controller.reconnectExpected)
            // Physical XM3 2.0.0 behavior: closing can win the race with the answer's ACK.
            throw MDRLink.LinkError.closed
        }
        #expect(controller.reconnectExpected)
        #expect(controller.toast?.style == .info)
        #expect(controller.verifications.isEmpty) // reconnecting is not a confirmed setting
    }

    @Test func declinesAndOtherPromptsDoNotHideConnectionFailures() async {
        for (type, accept, requiresAnswer): (UInt8, Bool, Bool) in [
            (0x02, false, true), (0x08, true, true), (0xFE, true, true), (0x02, true, false)
        ] {
            let controller = HeadphoneController()
            await controller.sendAlertAnswer(.init(messageType: type, requiresAnswer: requiresAnswer), accept: accept) {
                #expect(!controller.reconnectExpected)
                throw MDRLink.LinkError.closed
            }
            #expect(!controller.reconnectExpected)
            #expect(controller.toast?.style == .error)
        }
    }

    @Test func sendFailuresAndCancellationReleaseTheNewRestartExpectation() async {
        for cancelled in [false, true] {
            let controller = HeadphoneController()
            await controller.sendAlertAnswer(.init(messageType: 0x02, requiresAnswer: true), accept: true) {
                #expect(controller.reconnectExpected)
                if cancelled { throw CancellationError() }
                throw NSError(domain: "AlertAnswerTests", code: 1)
            }
            #expect(!controller.reconnectExpected)
            if cancelled { #expect(controller.toast == nil) }
            else { #expect(controller.toast?.style == .error) }
        }
        for type: UInt8 in [0x01, 0x02, 0x06, 0x07] {
            let controller = HeadphoneController()
            await controller.sendAlertAnswer(.init(messageType: type, requiresAnswer: true), accept: true) {
                #expect(controller.reconnectExpected)
            }
            #expect(controller.reconnectExpected && controller.toast == nil)
        }
    }
}
