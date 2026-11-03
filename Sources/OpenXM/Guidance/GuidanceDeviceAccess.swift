import Foundation
import IOBluetooth

/// Small, explicit control transaction shared by native access and scripted protocol tests.
@MainActor enum GuidanceMDRSession {
    typealias Request = ([UInt8], MDRDataType, MDRLink.Matcher) async throws -> [UInt8]

    static func read(address: String, language: GuidanceLanguage, request: Request) async throws -> GuidanceDeviceSnapshot {
        _ = try await request([0, 0], .dataMdr, .init(.dataMdr, 1))
        func text(_ command: UInt8, _ selector: UInt8) async throws -> String {
            let reply = try await request([command, selector], .dataMdr, .init(.dataMdr, command + 1, selector))
            guard reply.count >= 3, reply[0] == command + 1, reply[1] == selector else {
                throw FirmwareError.invalid("Incomplete language-update identity reply.")
            }
            var reader = ByteReader(reply, offset: 2)
            let value = try reader.string()
            guard reader.isAtEnd, !value.isEmpty else { throw FirmwareError.invalid("Invalid language-update identity.") }
            return value
        }
        let state = DeviceState(); state.family = .v1
        state.modelName = try await text(0x04, 1)
        guard state.modelName == "WH-1000XM3" else { throw FirmwareError.invalid("Language installation requires WH-1000XM3 over-ear headphones.") }
        state.firmware = try await text(0x04, 2)
        let category = try await text(0x36, 2), service = try await text(0x36, 3)
        guard category == "HP001", service == "MDRID291600" else {
            throw FirmwareError.invalid("Language installation currently requires the international WH-1000XM3.")
        }
        let capability = try V1VoiceGuidance.capability(await request([0x40, 1], .dataMdrNo2, .init(.dataMdrNo2, 0x41, 1)))
        guard capability.supportsLanguage, capability.languages.contains(language) else {
            throw FirmwareError.invalid("The headphones do not advertise the selected language.")
        }
        state.capabilities.voiceGuidanceCapability = capability
        for query in [V1VoiceGuidance.Query(command: 0x42, detail: 2)]
            + [UInt8(2), 4, 5].map({ V1VoiceGuidance.Query(command: 0x46, detail: $0) }) {
            let bytes = try await request(query.payload, .dataMdrNo2, query.reply)
            guard query.reply.matches(.init(type: .dataMdrNo2, sequence: 0, payload: bytes)),
                  let reply = try V1VoiceGuidance.reply(bytes) else { throw FirmwareError.invalid("Incomplete voice-language reply.") }
            switch reply {
            case .language(let value): state.voiceGuidanceDetails.language = value
            case .languageUpdateEnabled(let value): state.voiceGuidanceDetails.languageUpdateEnabled = value
            case .downloadService(let value): state.voiceGuidanceDetails.downloadService = value
            case .updateMethod(let value): state.voiceGuidanceDetails.updateMethod = value
            default: throw FirmwareError.invalid("Unexpected voice-language reply.")
            }
        }
        let battery = try await request([0x10, 0], .dataMdr, .init(.dataMdr, 0x11, 0))
        return try GuidanceDeviceSnapshot.make(state: state, address: address, firmwareCategory: category,
            firmwareService: service, language: language, batteryReply: battery)
    }

    static func setUpdateMode(_ enabled: Bool, request: Request) async throws {
        let value: UInt8 = enabled ? 0 : 1
        let reply = try await request([0x44, 1, 2, value], .dataMdrNo2, .init(.dataMdrNo2, 0x45, 1, detail: 2))
        guard reply == [0x45, 1, 2, value] else {
            throw FirmwareError.invalid("The headphones did not confirm language-update mode \(enabled ? "enabled" : "disabled"). Session retained.")
        }
    }
}

@MainActor protocol GuidanceInstallationIO {
    func snapshot(address: String, language: GuidanceLanguage) async throws -> GuidanceDeviceSnapshot
    func setUpdateMode(_ enabled: Bool, journal: GuidanceJournal, expectedLanguage: GuidanceLanguage?) async throws
    func transferLink(address: String, reconnecting: Bool) async throws -> FirmwareLink
}

@MainActor final class NativeGuidanceInstallationIO: GuidanceInstallationIO {
    func snapshot(address: String, language: GuidanceLanguage) async throws -> GuidanceDeviceSnapshot {
        try await withControlLink(address: address) { link in
            try await GuidanceMDRSession.read(address: address, language: language) { payload, table, matcher in
                try await link.request(payload, table: table, expect: matcher)
            }
        }
    }

    func setUpdateMode(_ enabled: Bool, journal: GuidanceJournal, expectedLanguage: GuidanceLanguage?) async throws {
        try await withControlLink(address: journal.address) { link in
            let snapshot = try await GuidanceMDRSession.read(address: journal.address, language: journal.targetLanguage) { payload, table, matcher in
                try await link.request(payload, table: table, expect: matcher)
            }
            try journal.check(snapshot)
            if enabled {
                guard snapshot.currentLanguage == expectedLanguage else {
                    throw FirmwareError.invalid("The current language changed before transfer preparation. Session retained.")
                }
                try GuidancePreflight.checkPower(snapshot)
            }
            try await GuidanceMDRSession.setUpdateMode(enabled) { payload, table, matcher in
                try await link.request(payload, table: table, expect: matcher, timeout: 15)
            }
        }
    }

    func transferLink(address: String, reconnecting: Bool) async throws -> FirmwareLink {
        if !reconnecting {
            let device = try FirmwareDeviceAccess.connectedDevice(address: address)
            return GAIALink(transport: try await RFCOMMTransport.openGAIA(device: device))
        }
        // Only reconnect the originally paired headset after the expected installation reboot.
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter {
            FirmwareDeviceAccess.normalizedAddress($0.addressString ?? "") == FirmwareDeviceAccess.normalizedAddress(address)
        }
        guard paired.count == 1, let device = paired.first else { throw FirmwareError.invalid("The original headset is no longer paired.") }
        try await Task.sleep(for: .seconds(5))
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            if let transport = try? await RFCOMMTransport.openGAIA(device: device, allowBasebandConnect: true) {
                return GAIALink(transport: transport)
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw FirmwareError.invalid("Reconnect the original headset in macOS, then reopen its language session. The saved session was retained.")
    }

    private func withControlLink<Result>(address: String, body: (MDRLink) async throws -> Result) async throws -> Result {
        let device = try FirmwareDeviceAccess.connectedDevice(address: address)
        let transport = try await RFCOMMTransport.open(device: device, allowBasebandConnect: false)
        guard transport.family == .v1 else { transport.close(); throw FirmwareError.invalid("XM3 requires the V1 control service.") }
        let link = MDRLink(transport: transport)
        defer { link.close() }
        try await Task.sleep(for: .milliseconds(350))
        return try await body(link)
    }
}
