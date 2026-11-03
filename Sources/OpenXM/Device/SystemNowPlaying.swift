import AppKit
import Observation

/// Reads local macOS media metadata. The helper is bundled and never downloads artwork or sends data.
@MainActor
@Observable
final class SystemNowPlaying {
    struct Item: Decodable, Equatable {
        let bundleIdentifier: String
        let title: String
        let artist: String?
        let album: String?
        let playing: Bool
        let artworkData: String?
        var processIdentifier: Int32? = nil
        var durationMicros: Double? = nil
        var elapsedTimeMicros: Double? = nil
        var timestampEpochMicros: Double? = nil
        var playbackRate: Double? = nil

        func progress(at date: Date) -> PlaybackProgress? {
            PlaybackProgress(elapsedTime: elapsedTimeMicros.map { $0 / 1_000_000 },
                             duration: durationMicros.map { $0 / 1_000_000 },
                             timestamp: timestampEpochMicros.map { Date(timeIntervalSince1970: $0 / 1_000_000) },
                             playbackRate: playbackRate, playing: playing, at: date)
        }

        func sameContentAndPlayer(as other: Item) -> Bool {
            bundleIdentifier == other.bundleIdentifier && processIdentifier == other.processIdentifier &&
            title == other.title && artist == other.artist && album == other.album && playing == other.playing
        }
    }

    private(set) var item: Item?
    private(set) var artwork: NSImage?
    private(set) var commandPending = false

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var commandProcess: Process?
    @ObservationIgnored private var historyProcess: Process?
    @ObservationIgnored private let historyProcessFactory: (() -> Process?)?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var generation = 0

    init(historyProcessFactory: (() -> Process?)? = nil) {
        self.historyProcessFactory = historyProcessFactory
    }

    enum HistoryRead {
        case ready(Item), unavailable(HistoryReadFailure), changed
    }

    enum HistoryReadFailure: Equatable {
        case busy, noPlayer, missingProcess, missingHelper, launchFailed, helperFailed(Int32), oversized, invalidResponse

        var message: String {
            switch self {
            case .busy: "The previous track check is still finishing."
            case .noPlayer: "The Mac player is not reporting active playback."
            case .missingProcess: "The Mac player has not provided its audio process identity."
            case .missingHelper: "The bundled media reader is unavailable."
            case .launchFailed: "The media reader could not start."
            case .helperFailed(let code): "The media reader stopped before returning track details (\(code))."
            case .oversized: "The media reader returned more track data than expected."
            case .invalidResponse: "The media reader did not return complete track details."
            }
        }
    }

    func start() {
        enabled = true
        guard process == nil else { return }
        guard let child = makeProcess(["stream", "--no-diff", "--debounce=100", "--micros"]) else { return }
        generation += 1
        let current = generation
        let pipe = Pipe()
        child.standardOutput = pipe
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.process = nil
                self.clear()
                self.retryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.enabled else { return }
                    self.start()
                }
            }
        }
        do {
            try child.run()
            process = child
            // A dedicated queue keeps pipe reads off the UI thread and preserves event order.
            DispatchQueue(label: "OpenXM.NowPlaying").async { [weak self] in
                let handle = pipe.fileHandleForReading
                defer { try? handle.close() }
                while true {
                    // read(upToCount:) can wait to fill its buffer; media events must arrive immediately.
                    let data = handle.availableData
                    guard !data.isEmpty else { break }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == current, self.process != nil else { return }
                        self.receive(data)
                    }
                }
            }
        } catch {
            clear()
        }
    }

    func stop() {
        enabled = false
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        if let commandProcess, commandProcess.isRunning { commandProcess.terminate() }
        if let historyProcess, historyProcess.isRunning { historyProcess.terminate() }
        clear()
    }

    /// A bounded, fresh read for opt-in history; never refreshes an old title from unrelated events.
    /// Require agreement with the displayed full stream snapshot before and after the asynchronous read.
    func readHistorySnapshot() async -> HistoryRead {
        guard historyProcess == nil else { return .unavailable(.busy) }
        guard let expected = item, expected.playing else { return .unavailable(.noPlayer) }
        guard expected.processIdentifier != nil else { return .unavailable(.missingProcess) }
        guard let child = historyProcessFactory.map({ $0() }) ?? makeProcess(["get", "--no-artwork"]) else {
            return .unavailable(.missingHelper)
        }
        let current = generation
        historyProcess = child
        defer { historyProcess = nil }
        let pipe = Pipe(); child.standardOutput = pipe
        let read: Result<Data, HistoryProcessError> = await withCheckedContinuation { continuation in
            do {
                try child.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if child.isRunning { child.terminate() } }
                DispatchQueue.global(qos: .utility).async {
                    let handle = pipe.fileHandleForReading
                    defer { try? handle.close() }
                    var bytes = Data()
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        bytes.append(chunk)
                        if bytes.count > 16_384 { if child.isRunning { child.terminate() }; continuation.resume(returning: .failure(.init(reason: .oversized))); return }
                    }
                    child.waitUntilExit()
                    continuation.resume(returning: child.terminationStatus == 0 ? .success(bytes) : .failure(.init(reason: .helperFailed(child.terminationStatus))))
                }
            } catch { continuation.resume(returning: .failure(.init(reason: .launchFailed))) }
        }
        guard !Task.isCancelled, current == generation else { return .changed }
        let bytes: Data
        switch read {
        case .success(let value): bytes = value
        case .failure(let error): return .unavailable(error.reason)
        }
        guard let fresh = try? JSONDecoder().decode(Item.self, from: bytes) else { return .unavailable(.invalidResponse) }
        guard expected.sameContentAndPlayer(as: fresh), item?.sameContentAndPlayer(as: fresh) == true else { return .changed }
        return .ready(fresh)
    }

    private struct HistoryProcessError: Error { let reason: HistoryReadFailure }

    /// Playback buttons follow the same player whose metadata is displayed.
    func send(_ command: PlaybackCommand) async -> Bool {
        guard item != nil, !commandPending else { return false }
        let code: String
        switch command {
        case .play: code = "0"
        case .pause: code = "1"
        case .next: code = "4"
        case .previous: code = "5"
        }
        guard let child = makeProcess(["send", code]) else { return false }
        commandPending = true
        commandProcess = child
        defer { commandPending = false; commandProcess = nil }
        return await withCheckedContinuation { continuation in
            child.terminationHandler = { child in
                continuation.resume(returning: child.terminationStatus == 0)
            }
            do {
                try child.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if child.isRunning { child.terminate() }
                }
            } catch {
                child.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    private func makeProcess(_ arguments: [String]) -> Process? {
        guard let resources = Bundle.main.resourceURL,
              let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl")
        let framework = frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else { return nil }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [script.path, framework.path] + arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        return child
    }

    private func clear() {
        item = nil
        artwork = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        // Bound buffering if a broken helper emits an incomplete or oversized artwork record.
        guard buffer.count <= 16 * 1024 * 1024 else {
            clear()
            process?.terminate()
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            consume(line)
        }
    }

    /// Full snapshots deliberately replace metadata so a track change cannot retain old artwork.
    func consume(_ line: Data) {
        struct Event: Decodable {
            let type: String
            let diff: Bool?
            let payload: Item?
        }
        // An empty payload means playback disappeared. Unknown events leave the current track alone.
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data" else { return }
        guard let event = try? JSONDecoder().decode(Event.self, from: line), event.diff != true,
              let value = event.payload, !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            item = nil
            artwork = nil
            return
        }
        if item?.artworkData != value.artworkData {
            artwork = value.artworkData.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
        }
        item = value
    }
}
