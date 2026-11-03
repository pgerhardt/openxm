import CoreAudio
import Foundation
import Observation

/// Read-only Core Audio property queries. Does not open a mic, capture audio, or change routes.
@MainActor @Observable
final class AudioConnectionMonitor {
    private(set) var snapshot: MacAudioConnection?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var address: String?
    @ObservationIgnored private var revision = 0

    func refresh(address: String?) {
        if self.address != address { clear(); self.address = address }
        guard let address, task == nil else { return }
        let expected = revision
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.read(address: address) }.value
            guard let self, self.revision == expected, !Task.isCancelled else { return }
            if self.snapshot != result { self.snapshot = result }
            self.task = nil
        }
    }

    func clear() {
        revision += 1
        task?.cancel(); task = nil; snapshot = nil; address = nil
    }

    nonisolated static func read(address: String) -> MacAudioConnection {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let devices = integers(system, kAudioHardwarePropertyDevices) else { return .init() }
        let bluetooth = devices.filter {
            let type = integers($0, kAudioDevicePropertyTransportType)?.first
            return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
        }
        func matching(_ direction: String) -> [AudioObjectID] {
            bluetooth.filter {
                guard let uid = string($0, kAudioDevicePropertyDeviceUID) else { return false }
                return MacAudioConnection.matchesUID(uid, address: address, direction: direction)
            }
        }
        let outputs = matching("output"), inputs = matching("input")
        var result = MacAudioConnection(outputFound: outputs.count == 1)
        if let input = integers(system, kAudioHardwarePropertyDefaultInputDevice)?.first {
            result.defaultInputName = string(input, kAudioObjectPropertyName)
        }
        let processes = integers(system, kAudioHardwarePropertyProcessObjectList)
        if let output = outputs.first, outputs.count == 1 {
            result.isDefaultOutput = integers(system, kAudioHardwarePropertyDefaultOutputDevice)?.first.map { $0 == output }
            result.outputInUse = activity(processes, devices: [output], input: false)
            if let streams = integers(output, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
               streams.count == 1, let stream = streams.first,
               let format = format(stream), format.mSampleRate.isFinite, format.mSampleRate > 0,
               format.mChannelsPerFrame > 0 {
                result.sampleRate = format.mSampleRate
                result.channels = format.mChannelsPerFrame
            }
        }
        if inputs.count == 1 { result.headphoneMicInUse = activity(processes, devices: inputs, input: true) }
        return result
    }

    /// A selected default input alone is not evidence that an app is using it.
    private nonisolated static func activity(_ processes: [AudioObjectID]?, devices: [AudioObjectID], input: Bool) -> Bool? {
        guard let processes else { return nil }
        let activities = processes.map { process in
            let running = integers(process, input ? kAudioProcessPropertyIsRunningInput : kAudioProcessPropertyIsRunningOutput)?.first
            let routes = running == 1 ? integers(process, kAudioProcessPropertyDevices,
                                                input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput) : nil
            return AudioProcessActivity(running: running, devices: routes)
        }
        return AudioProcessActivity.uses(devices, processes: activities)
    }

    private nonisolated static func integers(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt32]? {
        var property = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr,
              size % 4 == 0, size <= 65_536 else { return nil }
        if size == 0 { return [] }
        let capacity = size
        var values = [UInt32](repeating: 0, count: Int(size) / 4)
        let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, size <= capacity, size % 4 == 0 else { return nil }
        return Array(values.prefix(Int(size) / 4))
    }

    private nonisolated static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private nonisolated static func format(_ stream: AudioObjectID) -> AudioStreamBasicDescription? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(stream, &property, 0, nil, &size, &value) == noErr,
              size == MemoryLayout.size(ofValue: value) else { return nil }
        return value
    }
}
