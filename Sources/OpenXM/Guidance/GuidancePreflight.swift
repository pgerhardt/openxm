import Foundation

/// One fresh, exclusive MDR read. This does not change update mode or open GAIA.
struct GuidanceDeviceSnapshot: Equatable {
    let address: String
    let request: GuidancePackageRequest
    let currentLanguage: GuidanceLanguage
    let updateModeEnabled: Bool
    let method: GuidanceUpdateMethod
    let battery: Int
    let charging: Bool

    @MainActor
    static func make(state: DeviceState, address: String, firmwareCategory: String,
                     firmwareService: String, language: GuidanceLanguage, batteryReply: [UInt8]) throws -> Self {
        let request = try GuidancePackageRequest.make(state: state, firmwareCategory: firmwareCategory,
                                                      firmwareService: firmwareService, language: language)
        guard !address.isEmpty, let current = state.voiceGuidanceDetails.language,
              current.isKnown, language.isKnown,
              state.capabilities.voiceGuidanceCapability?.languages.contains(current) == true,
              let mode = state.voiceGuidanceDetails.languageUpdateEnabled,
              let method = state.voiceGuidanceDetails.updateMethod else {
            throw FirmwareError.invalid("The headphones did not report a complete current language, update status and update method.")
        }
        guard batteryReply.count == 4, batteryReply[0] == 0x11, batteryReply[1] == 0,
              batteryReply[2] <= 100, batteryReply[3] <= 1 else {
            throw FirmwareError.invalid("The headphones did not report a known battery and charging state.")
        }
        return .init(address: FirmwareDeviceAccess.normalizedAddress(address), request: request,
                     currentLanguage: current, updateModeEnabled: mode, method: method,
                     battery: Int(batteryReply[2]), charging: batteryReply[3] == 1)
    }
}

/// Read-only preparation checks. Success is neither installation authorization nor hardware validation.
/// An installer must take another fresh snapshot after its final confirmation.
struct GuidancePreflight: Equatable {
    let currentLanguage: GuidanceLanguage
    let targetLanguage: GuidanceLanguage
    let battery: Int
    let minimumBattery: Int
    let supportsResume: Bool
    let checkedAt: Date

    static func check(snapshot: GuidanceDeviceSnapshot, discoveryAddress: String,
                      source: GuidanceMetadataDownload, archive: GuidancePackageArchive,
                      notice: GuidanceNoticeArchive?, now: Date = Date()) throws -> Self {
        try Task.checkCancellation()
        // Matching only model/firmware is insufficient: the exact language mapping and serial may differ.
        guard !discoveryAddress.isEmpty,
              snapshot.address == FirmwareDeviceAccess.normalizedAddress(discoveryAddress),
              snapshot.request == source.request, source.request.model == "WH-1000XM3" else {
            throw FirmwareError.invalid("The headphones or their language service changed since discovery. Check Sony again for the selected headphones.")
        }
        guard source.metadata.offer != nil else { throw FirmwareError.invalid("No eligible language package was offered.") }
        guard !snapshot.updateModeEnabled else {
            throw FirmwareError.invalid("The headphones report language-update mode is already enabled. A new installation cannot start in this state.")
        }
        guard snapshot.currentLanguage != source.request.language else {
            throw FirmwareError.invalid("The headphones already report \(source.request.language.title). No language change is needed.")
        }
        let minimum = try checkPower(snapshot)
        _ = try GuidanceInstallationAssets(source: source, archive: archive, notice: notice)
        try Task.checkCancellation()
        return .init(currentLanguage: snapshot.currentLanguage, targetLanguage: source.request.language,
                     battery: snapshot.battery, minimumBattery: minimum,
                     supportsResume: snapshot.method.code == 0x11, checkedAt: now)
    }

    static func minimumBattery(for method: GuidanceUpdateMethod) throws -> Int {
        guard [UInt8(0x10), 0x11].contains(method.code), method.parameters.count == 2 else {
            throw FirmwareError.invalid("The reported language-update method is not an over-ear CSR method supported by this preflight.")
        }
        guard let threshold = method.batteryThreshold, (0..<100).contains(threshold) else {
            throw FirmwareError.invalid("The headphones reported an unsupported language-update battery threshold.")
        }
        // Sony compares battery > threshold (not >=). OpenXM additionally keeps the firmware updater's
        // conservative 80% floor and unplugged-USB requirement; those are app policy, not Sony's threshold.
        return max(80, threshold + 1)
    }

    @discardableResult
    static func checkPower(_ snapshot: GuidanceDeviceSnapshot) throws -> Int {
        let minimum = try minimumBattery(for: snapshot.method)
        guard (minimum...100).contains(snapshot.battery), !snapshot.charging else {
            throw FirmwareError.invalid("Charge the headphones to at least \(minimum)%, then unplug USB and check again.")
        }
        return minimum
    }
}
