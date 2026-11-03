import Foundation

struct FirmwareIdentity {
    static let minimumBattery = 50
    static let powerGuidance = "Do not start below \(minimumBattery)% battery. A full charge is recommended. Unplug the headphones' USB and audio cables before installing."

    let model: String
    let version: String
    let category: String
    let service: String
    let battery: Int
    let charging: Bool

    /// Firmware service, never Mac locale or the spoken guidance language.
    var region: FirmwareRegion? {
        guard model == "WH-1000XM3", category == "HP001" else { return nil }
        return FirmwareRegion(serviceID: service)
    }
    var regionName: String { region?.title ?? "Unknown" }
    var release: FirmwareRelease? { region.flatMap { FirmwareRelease(version: version, region: $0) } }

    func regionWarning(for target: FirmwareRegion) -> String? {
        guard let region else { return "The headphones' firmware region is unknown. Installation is disabled." }
        guard region != target else { return nil }
        return "Region change: \(region.title) → \(target.title). Voice guidance and assistant availability may change. Cross-region installation is experimental and has not been verified on hardware with OpenXM."
    }

    func checkModelAndRegion() throws {
        guard region != nil else {
            throw FirmwareError.invalid("Firmware installation requires WH-1000XM3 with an international, Japanese or Chinese HP001 firmware service.")
        }
    }

    func checkPower() throws {
        guard (Self.minimumBattery...100).contains(battery), !charging else {
            throw FirmwareError.invalid("Charge the headphones to at least \(Self.minimumBattery)%, then unplug USB before installing firmware.")
        }
    }
}

/// Binds both endpoints, including region, throughout confirmation, resume and final read-back.
struct FirmwareTransition: Equatable {
    let source: FirmwareRelease
    let target: FirmwareRelease
    static let downgrade = Self(source: .xm3v452, target: .xm3v200)
    static let upgrade = Self(source: .xm3v200, target: .xm3v452)

    var versionOrder: ComparisonResult { target.version.compare(source.version, options: .numeric) }
    var changesRegion: Bool { source.region != target.region }
    var title: String {
        switch versionOrder {
        case .orderedAscending: "Downgrade"
        case .orderedDescending: "Upgrade"
        case .orderedSame: "Change Region"
        }
    }
    static let durationGuidance = "Allow 2 hours or more for installation, especially a downgrade. Keep the Mac awake and the headphones nearby until verification finishes."
    var durationGuidance: String { Self.durationGuidance }
    var hardwareEvidence: String {
        self == .downgrade
            ? "The international 4.5.2 → 2.0.0 transition has been verified on one WH-1000XM3."
            : "This version and region transition has not yet been verified on hardware with OpenXM."
    }

    static func make(identity: FirmwareIdentity, target: FirmwareRelease) throws -> Self {
        try identity.checkModelAndRegion()
        guard let source = identity.release else {
            throw FirmwareError.invalid("The installed \(identity.regionName) \(identity.version) firmware is not in the supported source catalog.")
        }
        guard source != target else { throw FirmwareError.invalid("These headphones already report \(target.label). Choose a different version or region.") }
        return Self(source: source, target: target)
    }

    func checkImage(_ release: FirmwareRelease) throws {
        guard source != target, release == target else {
            throw FirmwareError.invalid("This installation requires the pinned \(target.label) package.")
        }
    }
    func matchesSource(_ identity: FirmwareIdentity) -> Bool { identity.release == source }
    func checkIdentity(_ identity: FirmwareIdentity, resuming: Bool = false) throws {
        try identity.checkModelAndRegion()
        guard source != target, matchesSource(identity) || (resuming && identity.release == target) else {
            throw FirmwareError.invalid("This installation requires \(source.label). Only its matching saved session can resume on \(target.label).")
        }
    }
    func verifyInstalled(_ identity: FirmwareIdentity) throws {
        try identity.checkModelAndRegion()
        guard identity.release == target else {
            throw FirmwareError.invalid("The expected \(target.label) firmware and region were not read back. Session retained.")
        }
    }
}

struct FirmwareJournal: Codable {
    let address: String
    let sha256: String
    let sourceVersion: String
    let targetVersion: String
    let started: Date
    var phase: VMUTransfer.Phase = .preparing
    // Missing together only in legacy international 2.0.0 ↔ 4.5.2 journals.
    var sourceService: String? = nil
    var targetService: String? = nil

    var targetRelease: FirmwareRelease? {
        FirmwareRelease.allCases.first { $0.sha256 == sha256 && $0.version == targetVersion }
    }
    func transition(for release: FirmwareRelease) throws -> FirmwareTransition {
        guard !address.isEmpty, targetRelease == release else {
            throw FirmwareError.invalid("The saved session does not match this firmware package.")
        }
        let sourceRegion: FirmwareRegion
        if let sourceService, let targetService {
            guard let region = FirmwareRegion(serviceID: sourceService), targetService == release.region.serviceID else {
                throw FirmwareError.invalid("The saved session has an unknown or mismatched firmware region.")
            }
            sourceRegion = region
        } else {
            guard sourceService == nil, targetService == nil, release.region == .international,
                  (sourceVersion == "4.5.2" && targetVersion == "2.0.0") ||
                  (sourceVersion == "2.0.0" && targetVersion == "4.5.2") else {
                throw FirmwareError.invalid("Only legacy international 2.0.0 ↔ 4.5.2 sessions may omit regional identity.")
            }
            sourceRegion = .international
        }
        guard let source = FirmwareRelease(version: sourceVersion, region: sourceRegion), source != release else {
            throw FirmwareError.invalid("The saved session has an unsupported source firmware or identical endpoints.")
        }
        return FirmwareTransition(source: source, target: release)
    }
}

enum FirmwareCommand: String, CaseIterable {
    case inspect = "--firmware-inspect"
    case probe = "--firmware-probe"
    case install = "--firmware-install"
    case downgrade = "--firmware-downgrade"
    case upgrade = "--firmware-upgrade"
    case resume = "--firmware-resume"

    func checkTransition(_ transition: FirmwareTransition) throws {
        if (self == .downgrade && transition.versionOrder != .orderedAscending) ||
            (self == .upgrade && transition.versionOrder != .orderedDescending) {
            throw FirmwareError.invalid("\(rawValue) does not match the selected source and target versions. Use --firmware-install for a same-version region change.")
        }
    }

    static func parse(_ arguments: [String]) throws -> FirmwareCommand {
        let modes = arguments.filter { $0.hasPrefix("--firmware-") }
        guard modes.count == 1, let command = modes.first.flatMap(Self.init(rawValue:)),
              !arguments.contains(where: { ["--demo", "--replay", "--probe", "--exercise"].contains($0) }) else {
            throw FirmwareError.invalid("Select exactly one firmware command; preview/replay and firmware commands cannot be combined.")
        }
        return command
    }
}
