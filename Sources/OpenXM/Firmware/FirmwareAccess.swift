import Foundation
import IOBluetooth
import Darwin

enum FirmwareJournalStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SoundConnect/firmware-session.json")
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func read(from url: URL = url) throws -> FirmwareJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 16_384 else {
            throw FirmwareError.invalid("The saved firmware session is invalid. It has been preserved for diagnosis.")
        }
        let journal = try JSONDecoder().decode(FirmwareJournal.self, from: Data(contentsOf: url))
        guard let release = journal.targetRelease else {
            throw FirmwareError.invalid("The saved firmware target is unsupported. The session has been preserved.")
        }
        _ = try journal.transition(for: release)
        return journal
    }

    static func save(_ journal: FirmwareJournal, to url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Process-wide and interprocess exclusion. The kernel releases the lock if a runner exits unexpectedly.
/// The journal separately records unfinished work; the lock file's existence never means a process is live.
final class FirmwareAccessLock {
    static let url = FirmwareJournalStore.url.deletingLastPathComponent().appendingPathComponent("firmware-access.lock")
    private let descriptor: Int32

    init(url: URL = FirmwareAccessLock.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw FirmwareError.invalid("Cannot open the firmware access lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw FirmwareError.invalid("Another firmware operation is running. Wait for that operation to finish.")
        }
        descriptor = fd
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }

    static var isHeld: Bool {
        do { let lock = try FirmwareAccessLock(); withExtendedLifetime(lock) {}; return false }
        catch { return true } // Unavailable exclusion fails closed.
    }
}

@MainActor
enum FirmwareDeviceAccess {
    nonisolated static func normalizedAddress(_ value: String) -> String { value.uppercased().replacingOccurrences(of: "-", with: ":") }

    static func connectedDevice(address: String) throws -> IOBluetoothDevice {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter {
            $0.isConnected() && normalizedAddress($0.addressString ?? "") == normalizedAddress(address)
        }
        guard devices.count == 1, let device = devices.first else {
            throw FirmwareError.invalid("Connect the selected headphones to this Mac, then try again.")
        }
        return device
    }

    static func readIdentity(_ device: IOBluetoothDevice) async throws -> FirmwareIdentity {
        let transport = try await RFCOMMTransport.open(device: device, allowBasebandConnect: false)
        guard transport.family == .v1 else { transport.close(); throw FirmwareError.invalid("XM3 requires the V1 control service.") }
        let link = MDRLink(transport: transport)
        defer { link.close() }
        try await Task.sleep(for: .milliseconds(350))
        return try await readIdentity { payload, matcher in
            try await link.request(payload, expect: matcher)
        }
    }

    /// Always request fresh identity, whether the caller owns a new connection or an existing exclusive one.
    static func readIdentity(request: ([UInt8], MDRLink.Matcher) async throws -> [UInt8]) async throws -> FirmwareIdentity {
        let protocolInfo = try await request([0, 0], .init(.dataMdr, 1))
        guard protocolInfo.count == 4, protocolInfo[0] == 1, protocolInfo[1] == 0 else {
            throw FirmwareError.invalid("XM3 requires a V1 protocol identity reply.")
        }
        func text(_ command: UInt8, _ selector: UInt8) async throws -> String {
            let response = try await request([command, selector], .init(.dataMdr, command + 1, selector))
            var reader = ByteReader(response, offset: 2)
            let value = try reader.string()
            guard reader.isAtEnd, !value.isEmpty else { throw FirmwareError.invalid("Malformed firmware identity response.") }
            return value
        }
        let model = try await text(0x04, 1)
        guard model == "WH-1000XM3" else { throw FirmwareError.invalid("The connected device is not a WH-1000XM3.") }
        let version = try await text(0x04, 2)
        let category = try await text(0x36, 2)
        let service = try await text(0x36, 3)
        let battery = try await request([0x10, 0], .init(.dataMdr, 0x11, 0))
        guard battery.count == 4, battery[2] <= 100 else { throw FirmwareError.invalid("Battery state is unavailable.") }
        return FirmwareIdentity(model: model, version: version, category: category, service: service,
                                battery: Int(battery[2]), charging: battery[3] != 0)
    }
}

enum FirmwareRunOutcome: Equatable {
    case inspected, probed, cancelled, verified(String), failed(String)
}

/// Pure preflight used by the GUI and tests. Installation repeats these checks using live identity.
enum FirmwareInstallPlan: Equatable {
    case install(FirmwareTransition), resume(FirmwareTransition), verifyCompleted(FirmwareTransition)

    var transition: FirmwareTransition {
        switch self { case .install(let t), .resume(let t), .verifyCompleted(let t): t }
    }
    var command: FirmwareCommand {
        switch self {
        case .install: .install
        case .resume, .verifyCompleted: .resume
        }
    }
    var buttonTitle: String {
        switch self {
        case .install(let t): "\(t.title) to \(t.target.label)…"
        case .resume: "Resume Installation…"
        case .verifyCompleted: "Verify Completed Installation"
        }
    }

    static func make(identity: FirmwareIdentity, address: String, release: FirmwareRelease, journal: FirmwareJournal?) throws -> Self {
        if let journal {
            guard FirmwareDeviceAccess.normalizedAddress(journal.address) == FirmwareDeviceAccess.normalizedAddress(address) else {
                throw FirmwareError.invalid("This session belongs to different headphones. Select the original headset to resume.")
            }
            let transition = try journal.transition(for: release)
            try transition.checkIdentity(identity, resuming: true)
            if journal.phase == .complete {
                try transition.verifyInstalled(identity)
                return .verifyCompleted(transition)
            }
            try identity.checkPower()
            return .resume(transition)
        }
        let transition = try FirmwareTransition.make(identity: identity, target: release)
        try transition.checkIdentity(identity)
        try identity.checkPower()
        return .install(transition)
    }
}
