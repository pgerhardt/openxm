import Foundation
import CoreAudio

/// Reads process routing only. No audio tap, capture, default-device change or playback command.
enum PlayerAudioRoute {
    static func matches(processIdentifier: Int32?, bundleIdentifier: String, headphoneAddress: String) -> Bool {
        guard let pid = processIdentifier, pid > 0,
              let processes = integers(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) else { return false }
        let matched = processes.filter {
            integers($0, kAudioProcessPropertyPID) == [UInt32(pid)] && string($0, kAudioProcessPropertyBundleID) == bundleIdentifier
        }
        guard matched.count == 1, let process = matched.first,
              integers(process, kAudioProcessPropertyIsRunningOutput) == [1],
              let devices = integers(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
              devices.count == 1, let device = devices.first,
              let uid = string(device, kAudioDevicePropertyDeviceUID),
              let transport = integers(device, kAudioDevicePropertyTransportType)?.first,
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return false }
        return matchesUID(uid, headphoneAddress: headphoneAddress)
    }

    static func matchesUID(_ uid: String, headphoneAddress: String) -> Bool {
        func normalized(_ address: String) -> String? {
            let value = address.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").uppercased()
            return value.utf8.count == 12 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) } ? value : nil
        }
        guard uid.hasSuffix(":output"), let expected = normalized(headphoneAddress),
              let actual = normalized(String(uid.dropLast(7))) else { return false }
        return actual == expected
    }

    private static func integers(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size % 4 == 0, size <= 65_536 else { return nil }
        if size == 0 { return [] }
        var values = [UInt32](repeating: 0, count: Int(size) / 4)
        let capacity = size
        let result = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr, size <= capacity, size % 4 == 0 else { return nil }
        return Array(values.prefix(Int(size) / 4))
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard result == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
