import Foundation
import Observation

/// Owns one helper session, keeping saved preferences separate from live codec
/// evidence. A saved choice is restored once after its headphones connect.
@MainActor @Observable
final class CodecTransportController {
    enum Phase: String { case automatic, connecting, streaming, idle, stopping, failed }
    private(set) var requested: CodecSelection = .automatic
    private(set) var phase: Phase = .automatic
    private(set) var activeCodec: AudioCodec?
    private(set) var sampleRate: Double?
    private(set) var recentKbps: Double?
    private(set) var targetKbps: Double?
    private(set) var volumeSynced = false
    private(set) var confirmedVolume: Int?
    private(set) var advancedSettings: CodecAdvancedSettings
    private var preferredCodecs: [String: CodecSelection]
    private(set) var activeLDACQuality: LDACQuality?
    private(set) var activeFastRecovery: Bool?
    private(set) var reportedDelayMs: Double?
    private(set) var estimatedDelayMs: Double?
    private(set) var routed = false
    private(set) var playbackBlocked = false
    private(set) var recoveringOutput = false
    private(set) var driverInstalled = false
    private(set) var helperAvailable = false
    private(set) var installingDriver = false
    private(set) var supported: [CodecSelection] = []
    private(set) var message: String?
    private(set) var diagnostics = ""
    private(set) var sessionAddress: String?
    var onReady: (() -> Void)?
    var onStopped: (() -> Void)?
    var onRouteNotice: ((String) -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var output: FileHandle?
    @ObservationIgnored private var errors: FileHandle?
    @ObservationIgnored private var outputBuffer = Data()
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var inspectTask: Task<Void, Never>?
    @ObservationIgnored private var completions: [() -> Void] = []
    @ObservationIgnored private var receivedStop = false
    @ObservationIgnored private var lastStatusAt: Date?
    @ObservationIgnored private var wasReady = false
    private(set) var switchingCodec = false
    private let executable: URL?
    private let journal: URL
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private var settingsRevision = 0
    @ObservationIgnored private var pendingLaunchRestorations: Set<String>

    init(executable: URL? = Bundle.main.url(forAuxiliaryExecutable: "OpenXMCodecTransport"), journal: URL? = nil, preferences: UserDefaults? = .standard) {
        self.executable = executable
        self.preferences = preferences
        let saved = (preferences?.dictionary(forKey: "preferredCodecs") ?? [:]).compactMapValues {
            ($0 as? String).flatMap(CodecSelection.init(rawValue:))
        }
        preferredCodecs = saved
        pendingLaunchRestorations = Set(saved.filter { $0.value != .automatic }.keys)
        advancedSettings = preferences?.data(forKey: "codecAdvancedSettings").flatMap { try? JSONDecoder().decode(CodecAdvancedSettings.self, from: $0) } ?? CodecAdvancedSettings()
        self.journal = journal ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenXM/CodecTransport/route.plist")
        helperAvailable = executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
    }

    var isEngaged: Bool { phase == .connecting || phase == .streaming || phase == .idle || phase == .stopping }
    var isTransitioning: Bool { phase == .connecting || phase == .stopping }
    var hasConfirmedSession: Bool { (phase == .streaming || phase == .idle) && activeCodec != nil }
    var volumePercent: Int? { confirmedVolume.map { Int((Double($0) * 100 / 127).rounded()) } }
    var canSetVolume: Bool { hasConfirmedSession && routed && volumeSynced && confirmedVolume != nil }
    var canChangeAdvancedSettings: Bool { !isTransitioning && (!isEngaged || hasConfirmedSession) }
    var canStartSession: Bool {
        !isEngaged && !recoveringOutput && !playbackBlocked && helperAvailable && driverInstalled
            && !FileManager.default.fileExists(atPath: journal.path)
    }

    private static func preferenceKey(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    func preferredCodec(for address: String?) -> CodecSelection {
        guard let address else { return .automatic }
        return preferredCodecs[Self.preferenceKey(address)] ?? .automatic
    }

    private func remember(_ selection: CodecSelection, address: String) {
        let key = Self.preferenceKey(address)
        preferredCodecs[key] = selection
        pendingLaunchRestorations.remove(key)
        preferences?.set(preferredCodecs.mapValues(\.rawValue), forKey: "preferredCodecs")
    }

    /// The caller must first establish a live, supported headphone connection.
    /// Consuming this before starting avoids retries after a failure or handback.
    func takeLaunchSelection(address: String) -> CodecSelection? {
        let key = Self.preferenceKey(address)
        guard canStartSession, phase == .automatic,
              pendingLaunchRestorations.remove(key) != nil else { return nil }
        let selection = preferredCodec(for: address)
        return selection == .automatic ? nil : selection
    }

    func setAdvancedSettings(_ settings: CodecAdvancedSettings) {
        guard canChangeAdvancedSettings, settings != advancedSettings else { return }
        advancedSettings = settings
        if let data = try? JSONEncoder().encode(settings) { preferences?.set(data, forKey: "codecAdvancedSettings") }
        if process != nil { configureSession() }
    }

    private func configureSession() {
        settingsRevision += 1
        switchingCodec = true
        phase = .connecting; clearEvidence(); wasReady = false; message = nil
        send(["command": "select", "codec": requested.rawValue, "settings": advancedSettings.wire(revision: settingsRevision)])
        armDeadline(seconds: 35)
    }

    func setVolumePercent(_ percent: Int) {
        guard canSetVolume, (0...100).contains(percent) else { return }
        let volume = Int((Double(percent) * 127 / 100).rounded())
        send(["command": "volume", "volume": volume])
        // Keep the last accepted value until the helper reports an AVRCP reply.
    }
    var headline: String {
        switch phase {
        case .automatic: "Managed by macOS"
        case .connecting: switchingCodec ? "Switching to \(requested.title)…" : "Connecting with \(requested.title)…"
        case .streaming: routed ? "Custom Bluetooth audio" : "Codec connected · output not selected"
        case .idle: "Custom Bluetooth audio · idle"
        case .stopping: "Returning audio to macOS…"
        case .failed: "Custom audio stopped"
        }
    }

    func refreshAvailability() {
        guard inspectTask == nil, !isEngaged, let executable else { return }
        helperAvailable = FileManager.default.isExecutableFile(atPath: executable.path)
        guard helperAvailable else { return }
        inspectTask = Task { [weak self] in
            let result = await Task.detached { Self.runUtility(executable, arguments: ["--inspect"]) }.value
            guard let self else { return }
            if let event = result { self.driverInstalled = event.driverInstalled == true }
            self.inspectTask = nil
        }
    }

    func installDriver() {
        guard !isEngaged, !installingDriver else { return }
        installingDriver = true; message = nil
        Task { [weak self] in
            let result = await Task.detached { CodecDriverInstaller.install() }.value
            guard let self else { return }
            self.message = result
            self.installingDriver = false
            self.refreshAvailability()
        }
    }

    /// Recovery only changes the output when a saved journal says we own the
    /// currently selected virtual route. It never selects a codec or opens Bluetooth.
    func recoverIfNeeded(allowPlaying: Bool = false) {
        guard !isEngaged, !recoveringOutput, let executable, FileManager.default.fileExists(atPath: journal.path) else { return }
        // Recovery owns this launch; don't immediately take audio back after a
        // crash or after the user explicitly restores a protected output.
        pendingLaunchRestorations.removeAll()
        recoveringOutput = true
        let path = journal.path, recoverySession = session
        Task { [weak self] in
            let arguments = ["--recover", path] + (allowPlaying ? ["--allow-playing"] : [])
            let result = await Task.detached { Self.runUtility(executable, arguments: arguments) }.value
            guard let self else { return }
            self.recoveringOutput = false
            guard self.session == recoverySession, !self.isEngaged else { return }
            let wasBlocked = self.playbackBlocked
            if let blocked = result?.playbackBlocked { self.playbackBlocked = blocked }
            else if result?.routeRestored == true { self.playbackBlocked = false }
            if result?.routeRestored != true {
                self.message = result?.message ?? "Audio could not be restored. Choose an available output in Sound settings."
            } else if let message = result?.message {
                self.message = message
                self.onRouteNotice?(message)
            } else if wasBlocked {
                self.message = "Audio output restored."
                self.onRouteNotice?("Audio output restored.")
            }
        }
    }

    func select(_ selection: CodecSelection, address: String) {
        if selection == .automatic { remember(selection, address: address); stop(); return }
        guard phase != .stopping, !recoveringOutput else { return }
        if process != nil {
            guard sessionAddress == address, hasConfirmedSession else { return }
            guard selection != requested else { return }
            remember(selection, address: address)
            requested = selection
            configureSession()
            return
        }
        guard helperAvailable, driverInstalled, let executable else {
            message = "Install the OpenXM audio driver before selecting a custom codec."; return
        }
        do {
            try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: journal.path) else {
                message = "An earlier audio session needs recovery before another can start."; recoverIfNeeded(); return
            }
            remember(selection, address: address)
            let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            let id = UUID(); session = id
            child.executableURL = executable
            settingsRevision = 0
            let settingsData = try JSONSerialization.data(withJSONObject: advancedSettings.wire(revision: settingsRevision))
            child.arguments = ["--stream", address, selection.rawValue, journal.path, String(decoding: settingsData, as: UTF8.self)]
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
            outputBuffer.removeAll(); receivedStop = false; diagnostics = ""; wasReady = false
            input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
            requested = selection; phase = .connecting; message = nil; supported = []
            playbackBlocked = false
            switchingCodec = false
            activeCodec = nil; sampleRate = nil; reportedDelayMs = nil; estimatedDelayMs = nil; routed = false
            recentKbps = nil; targetKbps = nil
            volumeSynced = false; confirmedVolume = nil
            activeLDACQuality = nil; activeFastRecovery = nil
            sessionAddress = address; process = child; lastStatusAt = Date()
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                Task { @MainActor in
                    guard let self, self.session == id, !data.isEmpty else { return }
                    self.diagnostics = String((self.diagnostics + String(decoding: data, as: UTF8.self)).suffix(32_768))
                }
            }
            try child.run()
            // The parent must not keep the child's pipe ends open, or EOF never
            // arrives on parent exit and output drains can hang after termination.
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            // One reader delivers all stdout and then exit in FIFO order. A
            // separate termination callback can otherwise overtake an already
            // read final "stopped" message, losing pause/recovery evidence.
            let handle = stdout.fileHandleForReading
            DispatchQueue(label: "OpenXM.CodecOutput").async { [weak self] in
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    DispatchQueue.main.async { self?.receive(data, session: id) }
                }
                child.waitUntilExit()
                let code = child.terminationStatus
                DispatchQueue.main.async { self?.ended(session: id, code: code) }
            }
            armDeadline(seconds: 45)
        } catch {
            message = "Could not start codec transport: \(error.localizedDescription)"
            closeHandles(); process = nil; phase = .failed; requested = .automatic; sessionAddress = nil
        }
    }

    private func receive(_ data: Data, session id: UUID) {
        guard id == session, !data.isEmpty else { return }
        outputBuffer.append(data)
        guard outputBuffer.count <= 262_144 else { stop(reason: "The codec helper returned an invalid response.", unexpectedLoss: true); return }
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: newline); outputBuffer.removeSubrange(...newline)
            guard let event = try? JSONDecoder().decode(CodecTransportEvent.self, from: line) else {
                stop(reason: "The codec helper returned an invalid response.", unexpectedLoss: true); return
            }
            apply(event)
        }
    }

    private func apply(_ event: CodecTransportEvent) {
        if event.event == "capabilities" {
            supported = (event.codecs ?? []).compactMap(CodecSelection.init(rawValue:)).filter { $0 != .automatic }; return
        }
        if event.event == "error" || event.event == "warning" { message = event.message; return }
        if event.event == "stopped" {
            receivedStop = true; clearEvidence()
            playbackBlocked = event.playbackBlocked == true
            if let text = event.message { message = text }
            if event.routeRestored != true { message = event.message ?? "The previous audio output could not be restored." }
            if let message { onRouteNotice?(message) }
            return
        }
        guard event.event == "status" else { return }
        lastStatusAt = Date()
        if event.phase == "stopping" {
            // Terminal transport loss is distinct from a codec reconfiguration.
            // Clear streaming evidence now, while the helper restores the route.
            stop(reason: event.message, unexpectedLoss: event.message != nil)
            return
        }
        guard phase != .stopping, event.requested == requested, (event.settingsRevision ?? 0) == settingsRevision else { return }
        activeCodec = event.confirmedCodec
        routed = event.routed == true
        sampleRate = event.confirmedCodec == nil ? nil : event.sampleRate
        recentKbps = event.measuredBitrateKbps
        targetKbps = event.encoderTargetKbps
        volumeSynced = event.confirmedCodec != nil && event.volumeSynced == true
        confirmedVolume = event.confirmedVolume
        activeLDACQuality = event.confirmedCodec == .ldac ? event.ldacQuality : nil
        activeFastRecovery = activeLDACQuality == .adaptive ? event.fastRecovery : nil
        reportedDelayMs = positive(event.headsetReportedDelayMs)
        estimatedDelayMs = positive(event.estimatedOutputDelayMs)
        if let actual = event.confirmedCodec {
            switchingCodec = false
            phase = event.phase == "idle" ? .idle : .streaming
            if actual != requested.audioCodec { message = "Requested \(requested.title), but the headphones negotiated \(actual.title)." }
            deadline?.cancel(); deadline = nil
            if !wasReady { wasReady = true; onReady?() }
        } else {
            phase = .connecting
            // Sample-rate renegotiation can start without a dropdown action.
            if wasReady { wasReady = false; switchingCodec = true; armDeadline(seconds: 35) }
        }
    }

    private func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }; return value
    }

    func checkHealth() {
        guard process != nil, phase != .stopping, let lastStatusAt else { return }
        if Date().timeIntervalSince(lastStatusAt) > 8 { stop(reason: "The codec helper stopped responding. Returning to macOS audio.", unexpectedLoss: true) }
    }

    func stop(reason: String? = nil, unexpectedLoss: Bool = false, completion: (() -> Void)? = nil) {
        pendingLaunchRestorations.removeAll()
        if let completion { completions.append(completion) }
        if let reason { message = reason }
        requested = .automatic; clearEvidence()
        switchingCodec = false
        guard let child = process else { phase = message == nil ? .automatic : .failed; finishCompletions(); return }
        guard phase != .stopping else { return }
        phase = .stopping; deadline?.cancel()
        send(["command": "stop", "unexpected": unexpectedLoss])
        // Closing stdin is also the crash/parent-exit contract, independent of JSON.
        try? input?.close(); input = nil
        let id = session
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(22))
            guard !Task.isCancelled, let self, self.session == id, self.process === child else { return }
            child.terminate()
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self.session == id, self.process === child, child.isRunning else { return }
            self.message = "The codec helper did not finish cleanup. Reconnect the headphones and check Sound settings."
            kill(child.processIdentifier, SIGKILL)
        }
    }

    private func armDeadline(seconds: Double) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.phase == .connecting else { return }
            self.stop(reason: "The selected codec could not connect in time. Returning to macOS audio.", unexpectedLoss: true)
        }
    }

    private func send(_ command: [String: Any]) {
        guard let input else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: command); data.append(10)
            try input.write(contentsOf: data)
        } catch { message = "The codec helper connection closed."; process?.terminate() }
    }

    private func ended(session id: UUID, code: Int32) {
        guard id == session else { return }
        // The stdout reader has delivered every final event before exit.
        deadline?.cancel(); deadline = nil
        closeHandles(); process = nil; clearEvidence(); sessionAddress = nil; requested = .automatic
        switchingCodec = false
        session = UUID() // Discard queued output callbacks from the terminated process.
        if !receivedStop && message == nil { message = "The codec helper exited unexpectedly (\(code)). Check the headphones' connection." }
        phase = message == nil ? .automatic : .failed
        recoverIfNeeded(); onStopped?(); finishCompletions()
    }

    private func clearEvidence() {
        activeCodec = nil; sampleRate = nil; routed = false; reportedDelayMs = nil; estimatedDelayMs = nil
        recentKbps = nil; targetKbps = nil
        volumeSynced = false; confirmedVolume = nil
        activeLDACQuality = nil; activeFastRecovery = nil
    }
    private func closeHandles() {
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil
    }
    private func finishCompletions() {
        let callbacks = completions; completions = []; callbacks.forEach { $0() }
    }

    nonisolated private static func runUtility(_ executable: URL, arguments: [String]) -> CodecTransportEvent? {
        let child = Process(), pipe = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.standardInput = FileHandle.nullDevice; child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        do {
            try child.run(); try? pipe.fileHandleForWriting.close()
            let end = Date().addingTimeInterval(5)
            while child.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
            if child.isRunning { child.terminate(); return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return try? JSONDecoder().decode(CodecTransportEvent.self, from: data)
        } catch { return nil }
    }
}
