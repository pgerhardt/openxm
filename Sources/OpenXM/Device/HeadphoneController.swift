import AppKit
import SwiftUI
import Foundation
import IOBluetooth
import Observation

/// A paired headset that this Mac knows about.
struct KnownHeadphones: Identifiable, Equatable {
    let address: String
    var name: String
    var isConnected: Bool
    var publishesService: Bool
    var id: String { address }
}

enum ConnectionPhase: Equatable {
    case starting
    case permissionNeeded
    case permissionDenied
    case bluetoothOff
    case noHeadphones
    case waiting(String)
    case connecting(String)
    case initializing(String)
    case connected
    case reconnecting(String, attempt: Int)
    case failed(String, message: String)

    var isConnected: Bool { self == .connected }

    var isBusy: Bool {
        switch self {
        case .connecting, .initializing, .reconnecting, .starting: true
        default: false
        }
    }
}

/// Outcome of one write + read-back, kept for the Diagnostics "verification" list and scene reports.
struct VerificationRecord: Identifiable, Sendable {
    enum Outcome: Sendable { case confirmed, adjusted(String), mismatch, notCheckable, failed(String) }
    let id = UUID()
    let date: Date
    let label: String
    let outcome: Outcome
}

struct Toast: Identifiable, Equatable {
    enum Style { case info, warning, error }
    let id = UUID()
    let style: Style
    let message: String
}

@MainActor
@Observable
final class HeadphoneController {
    let bluetooth = BluetoothAccess()
    let state = DeviceState()
    let systemNowPlaying = SystemNowPlaying()
    let audioConnection = AudioConnectionMonitor()
    let codecTransport = CodecTransportController()
    var audioConnectionPresentation: AudioConnectionPresentation {
        AudioConnectionPresentation(codec: codecTransport.isEngaged ? codecTransport.activeCodec : ((isConnected || isReplay) ? state.codec : nil),
                                    route: isConnected && !isReplay ? audioConnection.snapshot : nil)
    }
    let listeningHistory = ListeningHistory()
    let listeningContentHistory = ListeningContentHistory()
    private var contentReadTask: Task<Void, Never>?
    private var contentReadRevision = 0
    private var lastContentRead: Date?
    private var lastContentPlayer: SystemNowPlaying.Item?
    @ObservationIgnored lazy var settingsBackup = SettingsBackupWorkflow(controller: self)
    @ObservationIgnored lazy var firmwareUpdate = FirmwareUpdateWorkflow(controller: self)
    @ObservationIgnored lazy var guidancePackages = GuidancePackageWorkflow(controller: self)
    @ObservationIgnored lazy var equalizerGuide = EqualizerGuideWorkflow(controller: self)
    private(set) var settingsOperationInProgress = false
    private(set) var optimizerCommandInProgress = false
    private(set) var firmwareOperationInProgress = false
    private(set) var firmwareControlsReserved = false

    private(set) var phase: ConnectionPhase = .starting
    private(set) var pairing: HeadphonePairing?
    var isPairing: Bool { pairing != nil }
    private(set) var knownHeadphones: [KnownHeadphones] = []
    private(set) var traffic: [TrafficEntry] = []
    private(set) var verifications: [VerificationRecord] = []
    private(set) var pendingLabels: Set<String> = []
    private(set) var lastRefresh: Date?
    var toast: Toast?

    var selectedAddress: String? {
        didSet {
            UserDefaults.standard.set(selectedAddress, forKey: "selectedAddress")
            if oldValue != selectedAddress, codecTransport.isEngaged { codecTransport.stop(reason: "The selected headphones changed.") }
        }
    }

    private var transport: RFCOMMTransport?
    private var link: MDRLink?
    private var driver: HeadphoneDriver?
    private var connectTask: Task<Void, Never>?
    private var generation = 0
    private var refreshTimer: Timer?
    private var audioConnectionTimer: Timer?
    private var codecRefreshTask: Task<Void, Never>?
    private var lastCodecPoll: Date?
    private var historyTimer: Timer?
    private var historyObservationStarted = false
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var userDisconnected = false
    private var reconnectAttempt = 0
    private var observerStarted = false
    private var dragTask: Task<Void, Never>?
    private var latestDrag: NoiseControl?

    /// Fired after a successful (re)connection; scenes use it for "when headphones connect" triggers.
    var onConnected: (() -> Void)?

    /// Non-nil while showing a recorded session (developer replay, `--replay FILE`). Never live: Bluetooth is not
    /// started, the link has no transport, and every write is refused here and again at the link.
    private(set) var replaySource: String?
    var isReplay: Bool { replaySource != nil }
    var isDemo: Bool { replaySource == "Built-in preview" }
    /// Writes are possible only on a live, initialized connection.
    var canWrite: Bool { phase.isConnected && !isReplay && !settingsOperationInProgress && !optimizerCommandInProgress && !firmwareControlsReserved && !equalizerGuide.reserved && !codecTransport.isTransitioning }
    var canSelectCodec: Bool {
        !isReplay && !settingsOperationInProgress && !optimizerCommandInProgress && !firmwareControlsReserved
            && !equalizerGuide.reserved && !hasPendingWrites && !codecTransport.installingDriver
            && (isConnected || codecTransport.hasConfirmedSession)
            && (state.modelName == "WH-1000XM3" || (codecTransport.hasConfirmedSession && codecTransport.sessionAddress == selectedAddress))
    }

    func selectCodec(_ selection: CodecSelection) {
        guard !isReplay else { return }
        if selection == .automatic {
            if let selectedAddress { codecTransport.select(.automatic, address: selectedAddress) }
            else { codecTransport.stop() }
            return
        }
        guard canSelectCodec, let selectedAddress else { return }
        if codecTransport.canStartSession {
            // Let the helper finish its one deliberate Bluetooth takeover before
            // opening Sony's RFCOMM controls on the new baseband connection.
            generation += 1; connectTask?.cancel(); connectTask = nil
            dropConnection(); phase = .waiting(selectedName)
        }
        // An old Sony report must not appear to confirm the new request.
        state.codec = nil; lastCodecPoll = nil
        codecTransport.select(selection, address: selectedAddress)
    }
    var canAdjustNoise: Bool { canWrite && state.noiseControlAvailable }

    var canStartNoiseOptimizer: Bool {
        canWrite && !hasPendingWrites && dragTask == nil && state.capabilities.ncOptimizerCapability != nil
            && state.optimizerAvailable == true && state.optimizer.canStart
    }

    var canCancelNoiseOptimizer: Bool {
        canWrite && state.optimizer.isActive
    }

    /// The latest noise-control request not yet confirmed. Quick successive edits (mode, voice focus, level) build
    /// on it, so one request never overwrites another's fields with stale state.
    private(set) var noiseIntent: NoiseControl?
    /// Set when the user accepts a headset prompt that makes it restart its Bluetooth link (multipoint,
    /// connection quality, button assignment): the following link drop is expected, not an error.
    private var reconnectExpectedUntil: Date?
    var reconnectExpected: Bool { (reconnectExpectedUntil.map { $0 > Date() }) ?? false }
    /// Set when the user declines a headset prompt: the unchanged read-back is a cancellation, not a failure.
    private var alertDeclinedAt: Date?
    var noiseBase: NoiseControl? { noiseIntent ?? state.noise }

    init() {
        selectedAddress = UserDefaults.standard.string(forKey: "selectedAddress")
        codecTransport.onRouteNotice = { [weak self] message in self?.showToast(.info, message) }
        codecTransport.onReady = { [weak self] in
            guard let self else { return }
            self.lastCodecPoll = nil
            if !self.isConnected, let address = self.selectedAddress {
                self.connect(address: address, initiate: false)
            } else { self.refreshAudioConnection() }
        }
        codecTransport.onStopped = { [weak self] in
            guard let self else { return }
            self.state.codec = nil; self.lastCodecPoll = nil
            if !self.userDisconnected, !self.isConnected, let address = self.selectedAddress,
               self.device(for: address)?.isConnected() == true {
                self.connect(address: address, initiate: false)
            }
            self.refreshAudioConnection()
        }
    }

    var selectedName: String {
        knownHeadphones.first { $0.address == selectedAddress }?.name ?? state.modelName ?? "Headphones"
    }

    var isConnected: Bool { phase.isConnected }
    /// Invalidates firmware-sheet identity reads after a control-channel reconnect.
    var firmwareIdentityGeneration: Int { generation }

    // MARK: Startup

    func start() {
        guard !isReplay else { return }
        codecTransport.refreshAvailability()
        codecTransport.recoverIfNeeded()
        firmwareControlsReserved = FirmwareJournalStore.exists || GuidanceJournalStore.exists || FirmwareAccessLock.isHeld
        bluetooth.start()
        if audioConnectionTimer == nil {
            audioConnectionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAudioConnection() }
            }
        }
        observeBluetoothStatus()
        if !historyObservationStarted {
            historyObservationStarted = true
            observeListeningStatus()
            historyTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleListeningHistory() }
            }
        }
    }

    private func observeListeningStatus() {
        withObservationTracking {
            _ = phase; _ = state.nowPlaying; _ = selectedAddress
            _ = listeningContentHistory.enabled; _ = systemNowPlaying.item
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sampleListeningHistory()
                self?.observeListeningStatus()
            }
        }
        sampleListeningHistory()
    }

    private func sampleListeningHistory() {
        state.expirePlaybackMetadata()
        let live = phase.isConnected && !isReplay
        listeningHistory.sample(device: live ? selectedAddress : nil, model: live ? state.modelName : nil,
                                playback: state.nowPlaying)
        sampleListeningContent()
    }

    func stopListeningSamples() {
        listeningHistory.stopSample()
        cancelContentRead()
        listeningContentHistory.stopSample()
        lastContentRead = nil
    }

    private func cancelContentRead() {
        contentReadRevision += 1
        contentReadTask?.cancel(); contentReadTask = nil
    }

    private func sampleListeningContent() {
        let now = Date()
        guard listeningContentHistory.enabled, phase.isConnected, !isReplay,
              let address = selectedAddress, let model = state.modelName,
              state.nowPlaying.hasFreshListeningStatus(at: now) else {
            cancelContentRead(); listeningContentHistory.stopSample(); lastContentRead = nil
            listeningContentHistory.recordingStatus = .waitingForPlayback; return
        }
        guard state.nowPlaying.status == .playing else {
            cancelContentRead()
            listeningContentHistory.pause(device: address, model: model, at: now)
            listeningContentHistory.recordingStatus = .paused
            lastContentRead = nil; return
        }
        if let content = ListeningContentAttribution.headphone(state.nowPlaying, at: now) {
            cancelContentRead()
            listeningContentHistory.sample(device: address, model: model, content: content, at: now)
            listeningContentHistory.recordingStatus = .recording
            lastContentRead = nil; return
        }
        guard let player = systemNowPlaying.item, player.playing else {
            cancelContentRead(); listeningContentHistory.stopSample(); lastContentRead = nil
            listeningContentHistory.recordingStatus = .metadataUnavailable; return
        }
        // Avoid spawning a metadata helper for every volume/battery/elapsed-time update.
        let changed = lastContentPlayer?.sameContentAndPlayer(as: player) != true
        if changed { cancelContentRead(); listeningContentHistory.stopSample() }
        guard contentReadTask == nil, changed || lastContentRead.map({ now.timeIntervalSince($0) >= 12 }) ?? true else { return }
        lastContentRead = now; lastContentPlayer = player
        listeningContentHistory.recordingStatus = .readingMetadata
        let revision = contentReadRevision
        let connection = generation
        contentReadTask = Task { [weak self] in
            guard let self else { return }
            let result = await systemNowPlaying.readHistorySnapshot()
            guard !Task.isCancelled, revision == contentReadRevision else { return }
            contentReadTask = nil
            guard listeningContentHistory.enabled, connection == generation, phase.isConnected,
                  selectedAddress == address, state.modelName == model else {
                listeningContentHistory.stopSample(); return
            }
            let item: SystemNowPlaying.Item
            switch result {
            case .ready(let value): item = value
            case .unavailable(let reason):
                listeningContentHistory.recordingStatus = .metadataReadFailed(reason)
                listeningContentHistory.stopSample(); return
            case .changed:
                listeningContentHistory.recordingStatus = .metadataChanged
                listeningContentHistory.stopSample(); return
            }
            let route = PlayerAudioRoute.matches(processIdentifier: item.processIdentifier,
                                                  bundleIdentifier: item.bundleIdentifier, headphoneAddress: address)
            let date = Date()
            let content = ListeningContentAttribution.mac(item, playback: state.nowPlaying, routeMatches: route, at: date)
            listeningContentHistory.sample(device: address, model: model, content: content, at: date)
            listeningContentHistory.recordingStatus = content != nil ? .recording : route ? .waitingForPlayback : .unmatchedOutput
        }
    }

    /// Loads a `--probe` report recorded from real hardware and runs its received frames through the normal V1
    /// parser. Read-only: nothing is persisted and nothing can be sent.
    func startReplay(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            replaySource = url.lastPathComponent
            phase = .failed("Replay", message: "Cannot read \(url.path).")
            return
        }
        replaySource = url.lastPathComponent
        let link = MDRLink(transport: nil)
        state.reset()
        state.family = .v1
        let driver = V1Driver(link: link, state: state)
        link.describe = { [weak driver] frame in driver?.describe(frame) ?? "" }
        link.onFrame = { [weak driver] frame in driver?.handle(frame) }
        link.onTraffic = { [weak self] entry in self?.appendTraffic(entry) }
        self.link = link
        self.driver = driver
        let pattern = #/← (MDR2|MDR) s([01]) \[([0-9A-F ]+)\]/#
        var count = 0
        for line in text.split(separator: "\n") {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let payload = match.3.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            let frame = MDRFrame(type: match.1 == "MDR2" ? .dataMdrNo2 : .dataMdr, sequence: UInt8(match.2) ?? 0, payload: payload)
            link.injectRecorded(frame)
            count += 1
        }
        let recorded = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        link.note("Replayed \(count) frames recorded \(recorded?.formatted() ?? "earlier") — read-only, not live")
        lastRefresh = recorded
        phase = count > 0 && state.modelName != nil ? .connected : .failed("Replay", message: "No recorded frames found in \(url.lastPathComponent).")
    }

    /// A self-contained preview. No transport, Bluetooth, player helper, or automation is started.
    /// The existing replay write gate is deliberately reused at every command entry point.
    func startDemo() {
        guard !observerStarted, transport == nil, connectTask == nil else { return }
        replaySource = "Built-in preview"
        state.reset()
        state.family = .v1
        state.modelName = "WH-1000XM4"
        state.firmware = "Sample data"
        state.colorCode = 1
        state.capabilitiesKnown = true
        state.capabilities.noise = NoiseControlCapability(modes: NoiseMode.allCases, ambientRange: 1...20,
            supportsVoiceFocus: true, supportsAutoAmbient: false)
        state.capabilities.equalizer = EqualizerCapability(
            presets: [0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0].map {
                EqualizerPreset(id: UInt8($0), name: EqualizerPreset.displayName(for: UInt8($0)))
            }, bandCount: 5, bandRange: -10...10, hasClearBass: true)
        state.capabilities.upscalingName = "DSEE Extreme"
        state.capabilities.speakToChat = true
        state.capabilities.batteryKinds = [.single]
        state.battery.main = BatteryReading(level: 84, charging: .notCharging)
        state.codec = .aac
        state.noise = NoiseControl(mode: .noiseCancelling, ambientLevel: 12, focusOnVoice: false)
        state.equalizer = EqualizerState(presetID: 0xA0, bands: [0, 2, 3, 1, -1], clearBass: 2)
        state.upscaling = UpscalingState(enabled: true, active: false)
        state.speakToChat = SpeakToChat(enabled: false)
        phase = .connected
    }

    private func observeBluetoothStatus() {
        withObservationTracking {
            _ = bluetooth.status
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.bluetoothStatusChanged()
                self?.observeBluetoothStatus()
            }
        }
        bluetoothStatusChanged()
    }

    private func bluetoothStatusChanged() {
        switch bluetooth.status {
        case .unknown:
            if !phase.isConnected { phase = .starting }
        case .notDetermined:
            phase = .permissionNeeded
        case .denied:
            dropConnection()
            phase = .permissionDenied
        case .poweredOff, .unsupported:
            dropConnection()
            phase = .bluetoothOff
        case .ready:
            if !observerStarted {
                observerStarted = true
                BluetoothObserverBridge.shared.controller = self
                connectNotification = IOBluetoothDevice.register(forConnectNotifications: BluetoothObserverBridge.shared,
                                                                 selector: #selector(BluetoothObserverBridge.deviceConnected(_:device:)))
            }
            rescan()
            autoConnectIfPossible()
            if phase == .starting {
                phase = knownHeadphones.isEmpty ? .noHeadphones : .waiting(selectedName)
            }
        }
    }

    // MARK: Discovery

    /// Explicit onboarding; discovering a device never initiates pairing until the user selects it.
    func pairNewHeadphones() {
        guard !isReplay, !firmwareControlsReserved, !settingsOperationInProgress, !phase.isBusy, !isPairing, bluetooth.status == .ready else { return }
        pairing = HeadphonePairing { [weak self] address in
            self?.dismissPairing()
            self?.rescan()
            self?.connect(address: address, initiate: true)
        }
    }

    func dismissPairing() {
        pairing?.stop()
        pairing = nil
    }

    func rescan() {
        guard bluetooth.status == .ready else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        knownHeadphones = paired.compactMap { device in
            guard let address = device.addressString?.uppercased().replacingOccurrences(of: "-", with: ":") else { return nil }
            let name = device.name ?? address
            let publishes = RFCOMMTransport.publishesSonyService(device)
            let looksSony = Self.sonyNamePrefixes.contains { name.uppercased().hasPrefix($0) }
            guard publishes || looksSony else { return nil }
            watchDisconnect(device, address: address)
            return KnownHeadphones(address: address, name: name, isConnected: device.isConnected(), publishesService: publishes)
        }
        .sorted { ($0.isConnected ? 0 : 1, $0.name) < ($1.isConnected ? 0 : 1, $1.name) }
        if selectedAddress == nil || !knownHeadphones.contains(where: { $0.address == selectedAddress }) {
            selectedAddress = knownHeadphones.first(where: \.isConnected)?.address ?? knownHeadphones.first?.address
        }
        let idle = phase == .starting || (!phase.isConnected && !phase.isBusy)
        if idle && connectTask == nil {
            if knownHeadphones.isEmpty {
                phase = .noHeadphones
            } else if let target = knownHeadphones.first(where: { $0.address == selectedAddress }), !target.isConnected {
                phase = .waiting(target.name)
            }
        }
    }

    static let sonyNamePrefixes = ["WH-", "WF-", "WI-", "LINKBUDS", "ULT WEAR", "INZONE", "MDR-"]

    private func device(for address: String) -> IOBluetoothDevice? {
        IOBluetoothDevice(addressString: address.replacingOccurrences(of: ":", with: "-"))
    }

    private func watchDisconnect(_ device: IOBluetoothDevice, address: String) {
        guard disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(forDisconnectNotification: BluetoothObserverBridge.shared,
                                                           selector: #selector(BluetoothObserverBridge.deviceDisconnected(_:device:)))
    }

    fileprivate func basebandConnected(_ device: IOBluetoothDevice) {
        rescan()
        guard !firmwareControlsReserved else { return }
        guard let address = device.addressString?.uppercased().replacingOccurrences(of: "-", with: ":") else { return }
        if address == selectedAddress {
            userDisconnected = false
            autoConnectIfPossible()
        } else if !phase.isConnected && !phase.isBusy, knownHeadphones.contains(where: { $0.address == address && $0.publishesService }) {
            // Prefer whatever Sony headset just connected when nothing is active.
            selectedAddress = address
            autoConnectIfPossible()
        }
    }

    fileprivate func basebandDisconnected(_ device: IOBluetoothDevice) {
        let address = device.addressString?.uppercased().replacingOccurrences(of: "-", with: ":")
        disconnectNotifications[address ?? ""] = nil
        if address == selectedAddress, link != nil {
            dropConnection()
            phase = .waiting(selectedName)
        }
        rescan()
    }

    // MARK: Connection

    func autoConnectIfPossible() {
        guard !codecTransport.isTransitioning, !firmwareControlsReserved, bluetooth.status == .ready, !userDisconnected, link == nil, connectTask == nil,
              let address = selectedAddress,
              let known = knownHeadphones.first(where: { $0.address == address }),
              known.isConnected || (codecTransport.hasConfirmedSession && codecTransport.sessionAddress == address) else { return }
        connect(address: address, initiate: false)
    }

    /// Opens the control channel. `initiate` also asks macOS to bring up the Bluetooth link if needed
    /// (user-requested only, as it can take the headphones from another source).
    ///
    /// Every attempt gets a generation number. After each suspension point an attempt re-checks that it is
    /// still current; a superseded attempt only closes what it opened itself and never touches shared state.
    /// IOBluetooth hands out one channel object per (device, channel ID), so a new attempt also waits for
    /// the previous one to unwind before opening.
    func connect(address: String, initiate: Bool) {
        guard bluetooth.status == .ready, !isReplay else { return }
        guard !firmwareOperationInProgress else { return }
        firmwareControlsReserved = FirmwareJournalStore.exists || GuidanceJournalStore.exists || FirmwareAccessLock.isHeld
        guard !firmwareControlsReserved else {
            showToast(.warning, "Firmware work owns this connection. Open Headphone Firmware to inspect or resume it.")
            return
        }
        let previous = connectTask
        previous?.cancel()
        generation += 1
        let myGeneration = generation
        dropConnection()
        userDisconnected = false
        selectedAddress = address
        let name = knownHeadphones.first { $0.address == address }?.name ?? "Headphones"
        phase = .connecting(name)
        connectTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if self.generation == myGeneration && !Task.isCancelled {
                await self.runConnect(address: address, name: name, initiate: initiate, generation: myGeneration)
            }
            if self.generation == myGeneration { self.connectTask = nil }
        }
    }

    /// True while a connection attempt is opening or initializing.
    var isConnecting: Bool { connectTask != nil }

    private func isCurrent(_ attempt: Int) -> Bool { generation == attempt && !Task.isCancelled }

    private func runConnect(address: String, name: String, initiate: Bool, generation attempt: Int) async {
        guard let device = device(for: address) else {
            phase = .failed(name, message: "This Mac no longer knows these headphones.")
            return
        }
        var ownedTransport: RFCOMMTransport?
        var ownedLink: MDRLink?
        do {
            // The private A2DP connection can be live while IOBluetooth's cached
            // isConnected remains false. An accepted stream on this same paired
            // device is sufficient evidence to open its Sony control channel.
            let codecConnected = codecTransport.hasConfirmedSession && codecTransport.sessionAddress == address
            let transport = try await RFCOMMTransport.open(device: device, allowBasebandConnect: initiate || codecConnected)
            ownedTransport = transport
            guard isCurrent(attempt) else { throw CancellationError() }
            guard let family = transport.family else { throw TransportError.serviceNotFound }
            let link = MDRLink(transport: transport)
            ownedLink = link
            state.reset()
            state.family = transport.family
            let driver: HeadphoneDriver = transport.family == .v1
                ? V1Driver(link: link, state: state)
                : V2Driver(link: link, state: state)
            link.describe = { [weak driver] frame in driver?.describe(frame) ?? "" }
            link.onFrame = { [weak driver] frame in driver?.handle(frame) }
            link.onTraffic = { [weak self, weak link] entry in
                guard let self, let link, self.link === link else { return }
                self.appendTraffic(entry)
            }
            link.onClose = { [weak self, weak link] error in
                guard let self, let link, self.link === link else { return }
                self.linkClosed(error)
            }
            self.transport = transport
            self.link = link
            self.driver = driver
            traffic.removeAll()
            appendNote("Opened \(family.rawValue) control channel \(transport.channelID) to \(name)")
            phase = .initializing(name)
            // WH-1000XM4 ignores a frame sent in the first instant after the channel opens (observed: the first
            // GET protocol always needed a retry). A short settle avoids a one-second stall.
            try await Task.sleep(for: .milliseconds(350))
            guard isCurrent(attempt) else { throw CancellationError() }
            try await link.exclusive { try await driver.initialize() }
            guard isCurrent(attempt) else { throw CancellationError() }
            phase = .connected
            reconnectAttempt = 0
            reconnectExpectedUntil = nil
            lastRefresh = Date()
            startRefreshTimer()
            refreshAudioConnection()
            onConnected?()
        } catch {
            // Close what this attempt opened; shared state only belongs to the current generation.
            ownedLink?.close()
            ownedTransport?.close()
            guard generation == attempt else { return }
            dropConnection()
            if error is CancellationError { return }
            // The main window shows friendly copy; the technical reason is kept for Activity.
            appendNote("Connection to \(name) failed: \(error.localizedDescription)")
            if case TransportError.notConnected = error {
                phase = .waiting(name)
            } else {
                phase = .failed(name, message: error.localizedDescription)
                scheduleReconnect(name: name)
            }
        }
    }

    func disconnect() {
        guard !isReplay else { return }
        if codecTransport.isEngaged { codecTransport.stop() }
        userDisconnected = true
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        dropConnection()
        phase = .waiting(selectedName)
    }

    private func dropConnection() {
        audioConnection.clear()
        codecRefreshTask?.cancel(); codecRefreshTask = nil; lastCodecPoll = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        dragTask?.cancel()
        dragTask = nil
        latestDrag = nil
        noiseIntent = nil
        let oldLink = link
        link = nil
        driver = nil
        transport = nil
        oldLink?.close()
        pendingLabels.removeAll()
    }

    private func linkClosed(_ error: Error) {
        let name = selectedName
        generation += 1
        dropConnection()
        state.alert = nil
        if userDisconnected { return }
        let stillConnected = selectedAddress.flatMap { device(for: $0) }?.isConnected() ?? false
        if stillConnected || reconnectExpected {
            // After an accepted multipoint/quality change the headset drops and comes back on its own.
            reconnectAttempt = 0
            scheduleReconnect(name: name)
        } else {
            phase = .waiting(name)
        }
        if case MDRLink.LinkError.ackTimeout = error {
            showToast(.warning, "Lost sync with the headphones. Reconnecting…")
        }
    }

    private func scheduleReconnect(name: String) {
        guard !userDisconnected, reconnectAttempt < 6 else { return }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let scheduledGeneration = generation
        let delay = [1.0, 2.0, 4.0, 8.0, 15.0, 30.0][min(attempt - 1, 5)]
        if case .failed = phase {} else { phase = .reconnecting(name, attempt: attempt) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                // Anything that happened meanwhile (manual connect, disconnect, success) supersedes this timer.
                guard let self, self.generation == scheduledGeneration, self.link == nil, self.connectTask == nil,
                      !self.userDisconnected, !self.codecTransport.isTransitioning else { return }
                self.rescan()
                guard let address = self.selectedAddress,
                      self.knownHeadphones.first(where: { $0.address == address })?.isConnected == true
                        || (self.codecTransport.hasConfirmedSession && self.codecTransport.sessionAddress == address) else {
                    self.phase = .waiting(name)
                    return
                }
                self.connect(address: address, initiate: false)
                self.reconnectAttempt = attempt
            }
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    func refreshStatus() {
        guard let link, let driver, canWrite else { return }
        Task { @MainActor in
            do {
                try await link.exclusive { try await driver.refreshStatus() }
                if self.link === link { lastRefresh = Date() }
            } catch {
                link.note("Refresh failed: \(error.localizedDescription)")
            }
        }
    }

    /// Restore a saved codec once ready, then refresh live audio evidence. Codec
    /// reads share the serialized headphone link; Mac route reads are independent.
    private func refreshAudioConnection() {
        codecTransport.checkHealth()
        if isConnected, !userDisconnected, connectTask == nil, canSelectCodec,
           let address = selectedAddress, let selection = codecTransport.takeLaunchSelection(address: address) {
            selectCodec(selection)
        }
        audioConnection.refresh(address: (isConnected || codecTransport.isEngaged) && !isReplay ? selectedAddress : nil)
        guard canWrite, let link, let driver, state.capabilities.codecIndicator,
              codecRefreshTask == nil, lastCodecPoll.map({ Date().timeIntervalSince($0) >= 10 }) ?? true else { return }
        lastCodecPoll = Date()
        let attempt = generation
        codecRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == attempt { self.codecRefreshTask = nil } }
            do {
                try await link.exclusive {
                    guard self.link === link, self.canWrite, !Task.isCancelled else { return }
                    try await driver.refreshCodec()
                }
            } catch {
                if self.link === link { self.state.codec = nil }
            }
        }
    }

    // MARK: Writes

    /// Writes a change, reads it back (mandatory reply) and compares — all inside one exclusive transaction —
    /// then records whether the headset kept it.
    @discardableResult
    func perform(_ change: DeviceChange, quiet: Bool = false) async -> Bool {
        guard !settingsOperationInProgress, !firmwareControlsReserved, !equalizerGuide.reserved else { return false }
        if isReplay {
            if !quiet { showToast(.warning, "This is a read-only replay. Nothing is sent to headphones.") }
            return false
        }
        guard let link, let driver, phase.isConnected else {
            if !quiet { showToast(.warning, "Connect your headphones to change settings.") }
            return false
        }
        let label = change.label
        pendingLabels.insert(label)
        defer { pendingLabels.remove(label) }
        do {
            let result: (reflected: Bool?, adjustment: String?) = try await link.exclusive {
                try await driver.apply(change)
                return (change.isReflected(in: state), change.adjustment(in: state))
            }
            switch result.reflected {
            case true?:
                record(label, .confirmed)
                return true
            case false?:
                if let adjustment = result.adjustment {
                    record(label, .adjusted(adjustment))
                    return true
                }
                if let declined = alertDeclinedAt, Date().timeIntervalSince(declined) < 60 {
                    alertDeclinedAt = nil
                    record(label, .failed("Cancelled on the headphones' prompt"))
                    if !quiet { showToast(.info, "Change cancelled. The headphones kept their current setting.") }
                    return false
                }
                record(label, .mismatch)
                if !quiet { showToast(.warning, "The headphones did not keep “\(label)”.") }
                return false
            case nil:
                record(label, .notCheckable)
                return true
            }
        } catch {
            if reconnectExpected, case MDRLink.LinkError.closed = error {
                record(label, .notCheckable)
                if !quiet { showToast(.info, "The headphones are restarting their connection to apply “\(label)”. Reconnecting…") }
                return true
            }
            record(label, .failed(error.localizedDescription))
            if !quiet && !(error is CancellationError) { showToast(.error, error.localizedDescription) }
            return false
        }
    }

    /// Applies dependent changes as ONE transaction (e.g. select an editable EQ preset, then write its bands) and
    /// stops at the first change the headset does not confirm, so a later step never lands on the wrong target and
    /// nothing else can interleave between the steps.
    @discardableResult
    func performGroup(_ changes: [DeviceChange], quiet: Bool = false) async -> (confirmed: Int, failed: String?) {
        guard !changes.isEmpty else { return (0, nil) }
        guard !settingsOperationInProgress, !firmwareControlsReserved, !equalizerGuide.reserved else { return (0, "Settings or firmware work is in progress") }
        if isReplay {
            if !quiet { showToast(.warning, "This is a read-only replay. Nothing is sent to headphones.") }
            return (0, changes[0].label)
        }
        guard let link, let driver, phase.isConnected else {
            if !quiet { showToast(.warning, "Connect your headphones to change settings.") }
            return (0, changes[0].label)
        }
        let labels = Set(changes.map(\.label))
        pendingLabels.formUnion(labels)
        defer { pendingLabels.subtract(labels) }
        var confirmed = 0
        var current = changes[0]
        do {
            let failed: String? = try await link.exclusive {
                for change in changes {
                    current = change
                    try await driver.apply(change)
                    switch change.isReflected(in: state) {
                    case false?:
                        if let adjustment = change.adjustment(in: state) {
                            record(change.label, .adjusted(adjustment))
                            break
                        }
                        record(change.label, .mismatch)
                        return change.label
                    case true?:
                        record(change.label, .confirmed)
                    case nil:
                        record(change.label, .notCheckable)
                    }
                    confirmed += 1
                }
                return nil
            }
            if let failed, !quiet { showToast(.warning, "The headphones did not keep “\(failed)”.") }
            return (confirmed, failed)
        } catch {
            record(current.label, .failed(error.localizedDescription))
            if !quiet && !(error is CancellationError) { showToast(.error, error.localizedDescription) }
            return (confirmed, current.label)
        }
    }

    /// Noise control from the UI: builds on the latest pending request (see `noiseIntent`).
    func requestNoise(_ mutate: (inout NoiseControl) -> Void) {
        guard canAdjustNoise, var value = noiseBase else { return }
        mutate(&value)
        noiseIntent = value
        latestDrag = nil
        Task {
            _ = await perform(.noise(value, dragging: false))
            if noiseIntent == value { noiseIntent = nil }
        }
    }

    /// Live ambient-level drag, based on the latest intent.
    func dragAmbientLevel(_ level: Int) {
        guard var value = noiseBase else { return }
        value.ambientLevel = level
        dragNoise(value)
    }

    func isPending(_ change: DeviceChange) -> Bool { pendingLabels.contains(change.label) }
    var hasPendingWrites: Bool { !pendingLabels.isEmpty }

    func apply(_ change: DeviceChange) {
        Task { await perform(change) }
    }

    /// Live slider drags: coalesced "in progress" writes without read-back (the release commits with one).
    /// Bound to the link that was current when the drag began; stops on cancellation or reconnection.
    func dragNoise(_ value: NoiseControl) {
        guard canAdjustNoise else { return }
        latestDrag = value
        guard dragTask == nil, let link, let driver else { return }
        dragTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.link === link, let next = self.latestDrag {
                self.latestDrag = nil
                do {
                    try await link.exclusive { try await driver.apply(.noise(next, dragging: true)) }
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    break
                }
            }
            if let self, self.link === link { self.dragTask = nil }
        }
    }

    /// Ends a drag: drops any un-sent intermediate value so it cannot land after the committing write.
    func endNoiseDrag() {
        latestDrag = nil
    }

    func answerAlert(accept: Bool) {
        guard let alert = state.alert else { return }
        state.alert = nil
        // Restore owns the normal write gate, but its device confirmations must still be answerable.
        guard alert.requiresAnswer, phase.isConnected, !isReplay, let driver else { return }
        Task { @MainActor in
            await sendAlertAnswer(alert, accept: accept) {
                try await driver.answerAlert(alert, accept: accept)
            }
        }
    }

    /// The XM3 can close the link before acknowledging an accepted restart prompt. Arm reconnection before
    /// sending the answer, not after its ACK. A link close still requires fresh settings after reconnection.
    /// Kept outside `exclusive`: the original settings transaction is waiting for this answer's read-back.
    func sendAlertAnswer(_ alert: DeviceAlert, accept: Bool, send: () async throws -> Void) async {
        let expectsRestart = accept && alert.reconnectsWhenAccepted
        let previousDeadline = reconnectExpectedUntil
        let deadline = Date().addingTimeInterval(60)
        if expectsRestart { reconnectExpectedUntil = deadline }
        do {
            try await send()
            if !accept { alertDeclinedAt = Date() }
        } catch {
            if expectsRestart, case MDRLink.LinkError.closed = error {
                showToast(.info, "The headphones are restarting their connection. Reconnecting…")
                return
            }
            if expectsRestart, reconnectExpectedUntil == deadline { reconnectExpectedUntil = previousDeadline }
            if !(error is CancellationError) { showToast(.error, error.localizedDescription) }
        }
    }

    func startNoiseOptimizer() {
        guard canStartNoiseOptimizer, let link, let driver else { return }
        optimizerCommandInProgress = true
        Task { @MainActor in
            defer { optimizerCommandInProgress = false }
            do {
                try await link.exclusive { try await driver.startNoiseOptimizer() }
            } catch {
                showToast(.error, error.localizedDescription)
            }
        }
    }

    func cancelNoiseOptimizer() {
        guard canCancelNoiseOptimizer, let link, let driver else { return }
        optimizerCommandInProgress = true
        Task { @MainActor in
            defer { optimizerCommandInProgress = false }
            do {
                try await link.exclusive { try await driver.cancelNoiseOptimizer() }
            } catch {
                showToast(.error, error.localizedDescription)
            }
        }
    }

    func powerOff() {
        guard canWrite, let link, let driver else { return }
        Task { @MainActor in
            do {
                try await link.exclusive { try await driver.powerOff() }
                showToast(.info, "Turning the headphones off.")
            } catch {
                showToast(.error, error.localizedDescription)
            }
        }
    }

    // MARK: Settings backup and restore

    /// Firmware reads and transfers own the connection until explicitly released. Wait for any cancelled
    /// connection attempt to unwind before opening another RFCOMM service to the same headset.
    func beginFirmwareAccess() async throws {
        guard !codecTransport.isEngaged else {
            throw FirmwareError.invalid("Return the codec selection to Automatic and wait for audio cleanup before firmware work.")
        }
        guard !isReplay, !firmwareOperationInProgress, !settingsOperationInProgress, !equalizerGuide.reserved, !hasPendingWrites,
              dragTask == nil, !isPairing, !optimizerCommandInProgress, !state.optimizer.isActive, bluetooth.status == .ready else {
            throw FirmwareError.invalid("Wait for other headphone operations to finish and enable Bluetooth first.")
        }
        firmwareOperationInProgress = true
        firmwareControlsReserved = true
        let previous = connectTask
        disconnect()
        state.alert = nil
        await previous?.value
    }

    func endFirmwareAccess() {
        firmwareOperationInProgress = false
        refreshFirmwareReservation()
    }

    func refreshFirmwareReservation() {
        guard !firmwareOperationInProgress, !isReplay else { return }
        let wasReserved = firmwareControlsReserved
        firmwareControlsReserved = FirmwareJournalStore.exists || GuidanceJournalStore.exists || FirmwareAccessLock.isHeld
        if wasReserved && !firmwareControlsReserved {
            userDisconnected = false
            rescan()
            autoConnectIfPossible()
        }
    }

    func beginSettingsOperation() throws {
        guard canWrite, !hasPendingWrites, dragTask == nil, !state.optimizer.isActive else {
            throw SettingsBackupError.invalid("Connect your headphones and wait for other changes to finish.")
        }
        settingsOperationInProgress = true
    }

    func endSettingsOperation() { settingsOperationInProgress = false }

    func beginEqualizerGuideOperation() throws {
        guard phase.isConnected, !isReplay, !settingsOperationInProgress, !optimizerCommandInProgress,
              !firmwareControlsReserved, !hasPendingWrites, dragTask == nil, !state.optimizer.isActive else {
            throw SettingsBackupError.invalid("Connect your headphones and wait for other changes to finish.")
        }
        settingsOperationInProgress = true
    }

    func prepareEqualizerGuide(address: String, persist: (EqualizerGuideRecord) throws -> Void) async throws -> EqualizerGuideRecord {
        try await withFreshSettingsState(address: address) { reader, _, _ in
            try await EqualizerGuideDeviceAccess.prepare(driver: reader, address: address, persist: persist)
        }
    }

    func previewEqualizerGuide(_ curve: EqualizerGuideCurve?, record: EqualizerGuideRecord) async throws {
        try await withEqualizerGuideDriver(record: record) { driver in
            try await EqualizerGuideDeviceAccess.preview(curve, record: record, address: record.address, driver: driver)
        }
    }

    func finishEqualizerGuide(saving curve: EqualizerGuideCurve?, record: EqualizerGuideRecord) async throws {
        try await withFreshSettingsState(address: record.address) { reader, _, _ in
            try await EqualizerGuideDeviceAccess.finish(saving: curve, record: record, address: record.address, driver: reader)
        }
    }

    /// The normal driver has freshly initialized this connection's identity and capabilities. Its EQ
    /// writes reread availability and the destination slot. Keep the dependent writes exclusive without
    /// repeating every unrelated capability query between listening comparisons.
    private func withEqualizerGuideDriver(record: EqualizerGuideRecord,
        body: (HeadphoneDriver) async throws -> Void) async throws {
        guard settingsOperationInProgress, !isReplay, phase.isConnected, selectedAddress == record.address,
              let link, let driver else { throw SettingsBackupError.invalid("Reconnect the original headphones to restore their EQ.") }
        let attempt = generation
        try await link.exclusive {
            guard self.link === link, self.generation == attempt, self.selectedAddress == record.address else { throw MDRLink.LinkError.closed }
            try record.validate(state: self.state, address: record.address)
            try await body(driver)
            guard self.link === link, self.generation == attempt, self.selectedAddress == record.address,
                  self.phase.isConnected else { throw MDRLink.LinkError.closed }
        }
    }

    /// A GUI identity check can share the existing control channel. Closing and immediately reopening it
    /// can time out on an otherwise connected XM3. Installation still uses its separate reserved connection.
    func readFirmwareIdentity(address: String) async throws -> FirmwareIdentity {
        guard settingsOperationInProgress, !isReplay, phase.isConnected, selectedAddress == address,
              state.family == .v1, let link else {
            throw FirmwareError.invalid("Connect the selected WH-1000XM3 before checking its firmware identity.")
        }
        let attempt = generation
        return try await link.exclusive {
            guard self.link === link, self.generation == attempt else { throw MDRLink.LinkError.closed }
            let identity = try await FirmwareDeviceAccess.readIdentity { payload, matcher in
                try await link.request(payload, expect: matcher)
            }
            guard self.link === link, self.generation == attempt, self.selectedAddress == address,
                  self.phase.isConnected else { throw MDRLink.LinkError.closed }
            return identity
        }
    }

    /// Decode into a blank state. Missing replies stay nil instead of inheriting a previous session's values.
    /// The live parser still sees notifications, including device confirmation prompts.
    func readSettingsState(address: String, includeCustomEQ: Bool = false, matching backup: SettingsBackup? = nil) async throws -> DeviceState {
        try await withFreshSettingsState(address: address) { reader, fresh, _ in
            // A restore must establish the expected device before any temporary preset selection.
            if let backup { _ = try backup.plan(for: fresh) }
            if includeCustomEQ { _ = try await reader.captureEqualizerBank() }
            return fresh
        }
    }

    /// Read the ordinary firmware region and language-service map in the same connection transaction.
    /// A displayed/cached language or a model name alone is insufficient to choose a download service.
    func readGuidancePackageRequest(address: String, language: GuidanceLanguage) async throws -> GuidancePackageRequest {
        try await withFreshGuidanceState(address: address) { fresh, category, service, _ in
            try GuidancePackageRequest.make(state: fresh, firmwareCategory: category,
                                            firmwareService: service, language: language)
        }
    }

    private func withFreshGuidanceState<Result>(address: String,
        body: (DeviceState, String, String, MDRLink) async throws -> Result) async throws -> Result {
        guard state.family == .v1 else { throw FirmwareError.invalid("Voice-package discovery requires a V1 WH-1000XM3.") }
        return try await withFreshSettingsState(address: address) { _, fresh, link in
            func text(_ selector: UInt8) async throws -> String {
                let response = try await link.request([0x36, selector], expect: .init(.dataMdr, 0x37, selector))
                var reader = ByteReader(response, offset: 2)
                let value = try reader.string()
                guard reader.isAtEnd, !value.isEmpty else { throw FirmwareError.invalid("Incomplete firmware region reply.") }
                return value
            }
            let category = try await text(2)
            let service = try await text(3)
            return try await body(fresh, category, service, link)
        }
    }

    private func withFreshSettingsState<Result>(address: String,
        body: (HeadphoneDriver, DeviceState, MDRLink) async throws -> Result) async throws -> Result {
        guard settingsOperationInProgress, !isReplay, phase.isConnected, selectedAddress == address,
              let link, let family = state.family else {
            throw SettingsBackupError.invalid("The selected headphones are no longer connected.")
        }
        let attempt = generation
        return try await link.exclusive {
            guard self.link === link, self.generation == attempt else { throw MDRLink.LinkError.closed }
            let fresh = DeviceState()
            fresh.family = family
            let reader: HeadphoneDriver = family == .v1
                ? V1Driver(link: link, state: fresh, subscribesToAlerts: false)
                : V2Driver(link: link, state: fresh, subscribesToAlerts: false)
            let liveHandler = link.onFrame
            link.onFrame = { frame in liveHandler?(frame); reader.handle(frame) }
            defer { link.onFrame = liveHandler }
            try await reader.initialize()
            let result = try await body(reader, fresh, link)
            try Task.checkCancellation()
            guard self.link === link, self.generation == attempt, self.selectedAddress == address else {
                throw MDRLink.LinkError.closed
            }
            return result
        }
    }

    /// Keep dependent writes (notably editable EQ selection + bands) in one transaction. A reconnect is not
    /// success: the workflow must obtain a fresh value from the same headset before continuing.
    func restoreSetting(_ entry: SettingsRestoreEntry, backup: SettingsBackup, address: String) async -> SettingsRestoreOutcome {
        guard settingsOperationInProgress, !isReplay, phase.isConnected, selectedAddress == address,
              state.modelName == backup.model, state.family == backup.family, let link, let driver else {
            return .failed("The selected headphones changed or disconnected.")
        }
        do {
            return try await link.exclusive {
                guard self.link === link, self.selectedAddress == address else { throw MDRLink.LinkError.closed }
                let changes = try entry.setting.changes(for: state)
                var adjustments: [String] = []
                for change in changes {
                    try Task.checkCancellation()
                    try await driver.apply(change)
                    if change.isReflected(in: state) == true { record(change.label, .confirmed) }
                    else if let adjustment = change.adjustment(in: state) {
                        record(change.label, .adjusted(adjustment)); adjustments.append(adjustment)
                    } else {
                        record(change.label, .mismatch)
                        return .failed("The headphones did not confirm \(entry.setting.title).")
                    }
                }
                return adjustments.isEmpty ? .confirmed : .adjusted(adjustments.joined(separator: " "))
            }
        } catch {
            if reconnectExpected, case MDRLink.LinkError.closed = error { return .waitingForReconnect }
            record(entry.setting.title, .failed(error.localizedDescription))
            return .failed(error.localizedDescription)
        }
    }

    func waitForSettingsReconnect(address: String) async throws {
        let deadline = Date().addingTimeInterval(90)
        repeat {
            try Task.checkCancellation()
            guard selectedAddress == address, !userDisconnected else {
                throw SettingsBackupError.invalid("Restore stopped because the selected headphones changed or were disconnected.")
            }
            if phase.isConnected { return }
            try await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        throw SettingsBackupError.invalid("The headphones have not reconnected. Reconnect them, then review the backup again.")
    }

    // MARK: Bookkeeping

    private func record(_ label: String, _ outcome: VerificationRecord.Outcome) {
        verifications.insert(VerificationRecord(date: Date(), label: label, outcome: outcome), at: 0)
        if verifications.count > 200 { verifications.removeLast(verifications.count - 200) }
    }

    /// Controller-level notes for Activity; negative ids never collide with link entries.
    private var nextNoteID = -1
    private func appendNote(_ text: String) {
        appendTraffic(TrafficEntry(id: nextNoteID, date: Date(), direction: .note, frameType: "", sequence: nil, payload: [], summary: text))
        nextNoteID -= 1
    }

    private func appendTraffic(_ entry: TrafficEntry) {
        traffic.append(entry)
        if traffic.count > 500 { traffic.removeFirst(traffic.count - 500) }
    }

    func showToast(_ style: Toast.Style, _ message: String) {
        let toast = Toast(style: style, message: message)
        self.toast = toast
        AccessibilityNotification.Announcement(message).post()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                if self?.toast?.id == toast.id { self?.toast = nil }
            }
        }
    }

    var trafficLog: String { traffic.map(\.line).joined(separator: "\n") }
}

/// Objective-C target for IOBluetooth notifications (they require an NSObject receiver).
@MainActor
final class BluetoothObserverBridge: NSObject {
    static let shared = BluetoothObserverBridge()
    weak var controller: HeadphoneController?

    @objc nonisolated func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMainActor { [self] in controller?.basebandConnected(device) }
    }

    @objc nonisolated func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMainActor { [self] in controller?.basebandDisconnected(device) }
    }
}
