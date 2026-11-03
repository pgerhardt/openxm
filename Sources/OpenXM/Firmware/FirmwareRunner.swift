import AppKit
import Foundation
import IOBluetooth

/// Shared installation coordinator. CLI commands and the main app's explicit install/resume action use the
/// same confirmation, identity checks, journal and transfer engine. Ordinary startup never calls run().
@MainActor
final class FirmwareRunner {
    private let arguments: [String]
    private let bluetooth = BluetoothAccess()
    private var lines: [String] = []
    private var progressWindow: FirmwareProgressWindow?
    let reportURL: URL
    private let journalURL = FirmwareJournalStore.url
    private let selectedAddress: String?
    private let embedded: Bool
    private(set) var outcome: FirmwareRunOutcome?
    var onProgress: ((VMUTransfer.Phase, Int, Int) -> Void)?
    var onMessage: ((String) -> Void)?

    init(arguments: [String], selectedAddress: String? = nil, embedded: Bool = false) {
        self.arguments = arguments
        self.selectedAddress = selectedAddress
        self.embedded = embedded
        if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
            reportURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            reportURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OpenXM/firmware-\(stamp).txt")
        }
    }

    func run() async -> Int32 {
        defer { saveReport() }
        do {
            // Refuse conflicting modes even if a write flag is buried among preview arguments.
            let command = try FirmwareCommand.parse(arguments)
            let image = try command == .probe ? nil : FirmwareImage(url: fileArgument(command.rawValue))
            if command == .inspect, let image {
                describe(image)
                say("Offline inspection only. No Bluetooth connection or firmware write.")
                outcome = .inspected
                return 0
            }
            let access = try FirmwareAccessLock()
            defer { withExtendedLifetime(access) {} }
            guard !GuidanceJournalStore.exists else {
                throw FirmwareError.invalid("Finish the saved voice-language session before running firmware operations.")
            }
            let resume = command == .resume
            let journal = resume ? try FirmwareJournalStore.read() : nil
            if resume && journal == nil { throw FirmwareError.invalid("No unfinished firmware session was found.") }
            var transition: FirmwareTransition?
            if let image, let journal { transition = try journal.transition(for: image.release) }
            if image != nil && !resume && FileManager.default.fileExists(atPath: journalURL.path) {
                throw FirmwareError.invalid("An unfinished firmware session exists. Use --firmware-resume with the same image.")
            }
            guard !NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }) else { throw FirmwareError.invalid("Quit the regular OpenXM instance before running firmware commands.") }
            bluetooth.start()
            for _ in 0..<150 {
                if bluetooth.status == .ready { break }
                if bluetooth.status == .denied || bluetooth.status == .poweredOff { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard bluetooth.status == .ready else { throw TransportError.bluetoothUnavailable }
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
                .filter { $0.isConnected() }
            // Select exactly one live XM3, or the exact device in the interrupted-session journal.
            let candidates = devices.filter { device in
                let address = FirmwareDeviceAccess.normalizedAddress(device.addressString ?? "")
                if let selectedAddress, address != FirmwareDeviceAccess.normalizedAddress(selectedAddress) { return false }
                if let journal { return address == FirmwareDeviceAccess.normalizedAddress(journal.address) }
                if selectedAddress != nil { return true } // Identity below verifies the model, not the Bluetooth display name.
                return device.name == "WH-1000XM3"
            }
            guard candidates.count == 1, let device = candidates.first else {
                throw FirmwareError.invalid("Connect exactly one paired WH-1000XM3 in macOS Bluetooth settings, then retry.")
            }
            let identity = try await FirmwareDeviceAccess.readIdentity(device)
            say("\(identity.model) • \(identity.version) • \(identity.category)/\(identity.service) • battery \(identity.battery)%")
            if let image {
                let planned = try transition ?? FirmwareTransition.make(identity: identity, target: image.release)
                transition = planned
                try command.checkTransition(planned)
                try planned.checkImage(image.release)
            }
            if let image, let transition {
                describe(image)
                try transition.checkIdentity(identity, resuming: resume)
                if journal?.phase == .complete {
                    // The headset acknowledged commit in a previous run; only the independent read-back remains.
                    // Read-back does not require transfer-level battery charge.
                    try transition.verifyInstalled(identity)
                    try FileManager.default.removeItem(at: journalURL)
                    say("VERIFIED: WH-1000XM3 now reports \(image.release.label) firmware and region. Completed session cleared without starting another upgrade.")
                    outcome = .verified(image.release.label)
                    return 0
                }
                try identity.checkPower()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(resume ? "Resume" : transition.title) WH-1000XM3 \(transition.source.label) → \(image.release.label)?"
                alert.informativeText = "Experimental Mac-only updater. The \(image.release.label) package matches the recorded SHA-256 for WH-1000XM3. \(identity.regionWarning(for: image.release.region) ?? "") \(transition.hardwareEvidence) A failure can leave the headphones unusable, and recovery is not established. \(transition.durationGuidance) \(FirmwareIdentity.powerGuidance) Charge the Mac or connect it to power, and stop playback before starting."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "\(resume ? "Resume" : "Start") \(transition.title)")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertSecondButtonReturn else {
                    say("Cancelled before starting an upgrade session."); outcome = .cancelled; return 0
                }
                if !embedded {
                    progressWindow = FirmwareProgressWindow(targetVersion: image.release.label)
                    progressWindow?.show()
                }
                // Re-read live identity after the dialog; it may have been open for an arbitrary time.
                let fresh = try await FirmwareDeviceAccess.readIdentity(device)
                try transition.checkIdentity(fresh, resuming: resume)
                try fresh.checkPower()
                guard fresh.version == identity.version, fresh.service == identity.service else { throw FirmwareError.invalid("Firmware or region changed while awaiting confirmation.") }
            }
            // Finish all MDR reads before opening GAIA. Concurrent control/firmware channels disrupted
            // the first XM3 hardware attempt; identity is refreshed before switching services.
            say("Refreshing Bluetooth services before opening GAIA…")
            let transport = try await RFCOMMTransport.openGAIA(device: device)
            say("Opened GAIA RFCOMM channel \(transport.channelID) after live service discovery.")
            let link = GAIALink(transport: transport)
            link.trace = { [weak self] in self?.say($0) }
            defer { link.close() }
            let version = try await link.command(0x0304)
            say("GAIA application version response: \(version.hex)")
            guard let image, let transition else {
                say("Read-only firmware probe complete. No upgrade session was started.")
                outcome = .probed
                return 0
            }
            var saved = journal ?? FirmwareJournal(address: device.addressString, sha256: image.sha256,
                sourceVersion: transition.source.version, targetVersion: image.version, started: Date(),
                sourceService: transition.source.region.serviceID, targetService: image.serviceID)
            try saveJournal(saved)
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "XM3 firmware transfer")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let transfer = VMUTransfer(link: link, bytes: image.bytes, syncID: image.syncID) { [self] in
                say("Waiting for the headset to restart…")
                try await Task.sleep(for: .seconds(5))
                let deadline = Date().addingTimeInterval(180)
                while Date() < deadline {
                    // The RFCOMM open can reconnect this already-paired device after its expected reboot.
                    if let transport = try? await RFCOMMTransport.openGAIA(device: device, allowBasebandConnect: true) {
                        let reconnected = GAIALink(transport: transport)
                        reconnected.trace = { [weak self] in self?.say($0) }
                        return reconnected
                    }
                    try await Task.sleep(for: .seconds(3))
                }
                throw FirmwareError.invalid("Reconnect the same headset in macOS, then use --firmware-resume. The session record was kept.")
            }
            var lastProgress = ""
            transfer.checkpoint = { [self] phase in
                saved.phase = phase
                try saveJournal(saved)
            }
            transfer.report = { [self] phase, offset, total in
                let progress = "\(phase.rawValue): \(offset * 100 / total)% of image transferred"
                if progress != lastProgress { say(progress); lastProgress = progress }
                progressWindow?.update(phase: phase, offset: offset, total: total)
                onProgress?(phase, offset, total)
            }
            // The target may be running provisionally after reboot. Finish its commit, never re-upload it.
            try await transfer.run(allowResume: resume, allowDataTransfer: transition.matchesSource(identity))
            let after = try await FirmwareDeviceAccess.readIdentity(device)
            try transition.verifyInstalled(after)
            try FileManager.default.removeItem(at: journalURL)
            say("VERIFIED: WH-1000XM3 now reports \(image.release.label) firmware and region.")
            outcome = .verified(image.release.label)
            return 0
        } catch {
            outcome = .failed(error.localizedDescription)
            say("FAILED: \(error.localizedDescription)")
            if progressWindow != nil {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Firmware installation stopped"
                let retained = FileManager.default.fileExists(atPath: journalURL.path) ? "Session information was retained. " : "No upgrade session was started. "
                alert.informativeText = "\(error.localizedDescription)\n\n\(retained)Report: \(reportURL.path)"
                alert.runModal()
            }
            return 1
        }
    }

    private func fileArgument(_ flag: String) throws -> URL {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("--") else { throw FirmwareError.invalid("\(flag) requires a firmware file path.") }
        return URL(fileURLWithPath: arguments[index + 1])
    }
    private func describe(_ image: FirmwareImage) {
        say("Package: WH-1000XM3 \(image.release.label) (\(image.serviceID)), \(image.bytes.count) bytes")
        say("SHA-256: \(image.sha256)")
    }
    private func saveJournal(_ journal: FirmwareJournal) throws {
        try FirmwareJournalStore.save(journal)
    }
    private func say(_ line: String) { lines.append(line); print(line); onMessage?(line); saveReport() }
    private func saveReport() {
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").appending("\n").write(to: reportURL, atomically: true, encoding: .utf8)
        } catch { print("Could not save firmware report: \(error.localizedDescription)") }
    }
}

@MainActor
final class FirmwareAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in exit(await FirmwareRunner(arguments: CommandLine.arguments).run()) }
    }
}
