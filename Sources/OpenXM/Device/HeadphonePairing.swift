import Foundation
import IOBluetooth
import Observation

struct PairingCandidate: Identifiable {
    let id: String
    let name: String
    let paired: Bool
}

/// Native classic-Bluetooth discovery and explicit pairing. Inquiries finish before pairing begins.
@MainActor @Observable
final class HeadphonePairing: NSObject, IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate {
    private(set) var candidates: [PairingCandidate] = []
    private(set) var scanning = false
    private(set) var pairingName: String?
    private(set) var message: String?
    private(set) var confirmationCode: UInt32?
    private(set) var needsPIN = false
    private(set) var passkey: UInt32?
    private var inquiry: IOBluetoothDeviceInquiry?
    private var pairer: IOBluetoothDevicePair?
    private var devices: [String: IOBluetoothDevice] = [:]
    private var timeout: Task<Void, Never>?
    private let onPaired: (String) -> Void

    init(onPaired: @escaping (String) -> Void) { self.onPaired = onPaired; super.init() }

    func search() {
        guard !scanning, pairer == nil else { return }
        message = nil
        candidates = []
        devices = [:]
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else {
            message = "Bluetooth search is unavailable. Try pairing in System Settings."
            return
        }
        inquiry.inquiryLength = 12
        inquiry.updateNewDeviceNames = true
        self.inquiry = inquiry
        scanning = true
        let result = inquiry.start()
        if result != kIOReturnSuccess {
            scanning = false
            inquiry.delegate = nil
            self.inquiry = nil
            message = String(format: "Bluetooth search couldn't start (0x%08X). You can also pair in System Settings.", UInt32(bitPattern: result))
        }
    }

    func pair(_ candidate: PairingCandidate) {
        guard !scanning, pairer == nil, let device = devices[candidate.id] else { return }
        if device.isPaired() { onPaired(candidate.id); return }
        message = nil
        pairingName = candidate.name
        guard let pairer = IOBluetoothDevicePair(device: device) else {
            pairingName = nil
            message = "Couldn't start pairing. Try pairing in System Settings."
            return
        }
        pairer.delegate = self
        self.pairer = pairer
        let result = pairer.start()
        guard result == kIOReturnSuccess else { finishPairing(error: result); return }
        timeout = Task { @MainActor [weak self, weak pairer] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard let self, let pairer, self.pairer === pairer else { return }
            self.stopPairing()
            self.message = "Pairing timed out. Put the headphones in pairing mode and try again."
        }
    }

    func confirm(_ accepted: Bool) {
        guard confirmationCode != nil else { return }
        confirmationCode = nil
        pairer?.replyUserConfirmation(accepted)
    }

    func submitPIN(_ value: String) {
        guard needsPIN, let pairer else { return }
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 16, bytes.allSatisfy({ $0 < 128 }) else {
            message = "Enter the PIN specified by your headphones (1–16 characters)."
            return
        }
        var code = BluetoothPINCode()
        withUnsafeMutableBytes(of: &code) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        needsPIN = false
        pairer.replyPINCode(bytes.count, pinCode: &code)
    }

    func stop() {
        inquiry?.delegate = nil
        _ = inquiry?.stop()
        inquiry = nil
        scanning = false
        stopPairing()
    }

    private func stopPairing() {
        timeout?.cancel(); timeout = nil
        pairer?.delegate = nil
        pairer?.stop()
        pairer = nil
        pairingName = nil
        confirmationCode = nil; needsPIN = false; passkey = nil
    }

    private func found(_ device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        let name = device.name ?? "Unnamed Bluetooth audio device"
        // Restrict the audio class to headset/headphone devices, so TVs and speakers are not offered here.
        // Sony names cover models with an unexpected class; SDP compatibility is checked after pairing.
        let headphoneClasses = [BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioHeadset),
                               BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioHandsFree),
                               BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioHeadphones)]
        guard (device.deviceClassMajor == kBluetoothDeviceClassMajorAudio && headphoneClasses.contains(device.deviceClassMinor))
                || ["WH-", "WF-", "WI-", "MDR-", "LinkBuds"].contains(where: { name.localizedCaseInsensitiveContains($0) }) else { return }
        devices[address] = device
        candidates.removeAll { $0.id == address }
        candidates.append(PairingCandidate(id: address, name: name, paired: device.isPaired()))
        candidates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func finishPairing(error: IOReturn) {
        guard let pairer else { return }
        let device = pairer.device()
        timeout?.cancel(); timeout = nil
        pairer.delegate = nil
        self.pairer = nil
        pairingName = nil
        confirmationCode = nil; needsPIN = false; passkey = nil
        if error == kIOReturnSuccess, let address = device?.addressString {
            onPaired(address)
        } else {
            message = String(format: "Pairing didn't finish (0x%08X). Check pairing mode and try again.", UInt32(bitPattern: error))
        }
    }

    nonisolated func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        Task { @MainActor [weak self] in
            guard let self, self.inquiry === sender, let device else { return }
            self.found(device)
        }
    }

    nonisolated func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        deviceInquiryDeviceFound(sender, device: device)
    }

    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.inquiry === sender else { return }
            self.scanning = false
            self.inquiry?.delegate = nil
            self.inquiry = nil
            if error != kIOReturnSuccess && !aborted {
                self.message = String(format: "Bluetooth search ended with error 0x%08X.", UInt32(bitPattern: error))
            }
        }
    }

    nonisolated func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        Task { @MainActor [weak self] in
            guard let self, let sender = sender as? IOBluetoothDevicePair, self.pairer === sender else { return }
            self.confirmationCode = numericValue
        }
    }

    nonisolated func devicePairingPINCodeRequest(_ sender: Any!) {
        Task { @MainActor [weak self] in
            guard let self, let sender = sender as? IOBluetoothDevicePair, self.pairer === sender else { return }
            self.needsPIN = true
        }
    }

    nonisolated func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        Task { @MainActor [weak self] in
            guard let self, let sender = sender as? IOBluetoothDevicePair, self.pairer === sender else { return }
            self.passkey = passkey
        }
    }

    nonisolated func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        Task { @MainActor [weak self] in
            guard let self, let sender = sender as? IOBluetoothDevicePair, self.pairer === sender else { return }
            self.finishPairing(error: error)
        }
    }
}
