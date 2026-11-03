import Foundation
import Testing
@testable import OpenXM

@MainActor struct FirmwareIdentityReadTests {
    private func textReply(_ command: UInt8, _ selector: UInt8, _ value: String) -> [UInt8] {
        [command, selector, UInt8(value.utf8.count)] + Array(value.utf8)
    }

    @Test func everyIdentityReadRequestsFreshModelRegionVersionAndBattery() async throws {
        for (version, service, battery) in [("2.0.0", "MDRID291600", UInt8(100)), ("4.5.2", "MDRID291601", UInt8(70))] {
            var sent: [[UInt8]] = []
            let identity = try await FirmwareDeviceAccess.readIdentity { payload, _ in
                sent.append(payload)
                switch payload {
                case [0, 0]: return [1, 0, 0x40, 0]
                case [4, 1]: return textReply(5, 1, "WH-1000XM3")
                case [4, 2]: return textReply(5, 2, version)
                case [0x36, 2]: return textReply(0x37, 2, "HP001")
                case [0x36, 3]: return textReply(0x37, 3, service)
                case [0x10, 0]: return [0x11, 0, battery, 0]
                default: throw FirmwareError.invalid("Unexpected test query")
                }
            }
            #expect(sent == [[0, 0], [4, 1], [4, 2], [0x36, 2], [0x36, 3], [0x10, 0]])
            #expect(identity.version == version && identity.service == service && identity.battery == Int(battery))
            try identity.checkModelAndRegion()
        }
    }

    @Test func missingOrInvalidIdentityFieldsCannotFallBackToDisplayedValues() async {
        for failure in 0..<5 {
            await #expect(throws: (any Error).self) {
                _ = try await FirmwareDeviceAccess.readIdentity { payload, _ in
                    switch payload {
                    case [0, 0]: return failure == 0 ? [1, 0] : [1, 0, 0x40, 0]
                    case [4, 1]: return textReply(5, 1, failure == 1 ? "WF-1000XM3" : "WH-1000XM3")
                    case [4, 2]: return textReply(5, 2, "2.0.0")
                    case [0x36, 2]: return textReply(0x37, 2, "HP001")
                    case [0x36, 3]:
                        if failure == 2 { throw MDRLink.LinkError.closed }
                        if failure == 3 { return [0x37, 3, 20, 65] }
                        return textReply(0x37, 3, "MDRID291600")
                    case [0x10, 0]: return [0x11, 0, 101, 0]
                    default: throw FirmwareError.invalid("Unexpected test query")
                    }
                }
            }
        }
    }
}
