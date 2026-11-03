import AppKit
import SwiftUI

struct HeadphonePairingView: View {
    @Environment(HeadphoneController.self) private var controller
    let pairing: HeadphonePairing
    @State private var pin = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pair Sony Headphones").font(.system(size: 22, weight: .semibold))
            Text("Put your headphones in pairing mode, then select them below. OpenXM checks compatibility after pairing.")
                .foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if let name = pairing.pairingName {
                HStack { ProgressView().controlSize(.small); Text("Pairing with \(name)…") }
            } else if pairing.scanning {
                HStack { ProgressView().controlSize(.small); Text("Searching for nearby headphones…") }
            }
            if let code = pairing.confirmationCode {
                Text("Confirm the pairing code: \(String(format: "%06u", code))").font(.headline)
                HStack {
                    Button("Reject") { pairing.confirm(false) }
                    Button("Confirm") { pairing.confirm(true) }.buttonStyle(.borderedProminent)
                }
            }
            if pairing.needsPIN {
                SecureField("Headphone PIN", text: $pin)
                Button("Submit PIN") { pairing.submitPIN(pin); pin = "" }.disabled(pin.isEmpty)
            }
            if let passkey = pairing.passkey {
                Text("Enter \(String(format: "%06u", passkey)) on the other device to complete pairing.")
            }
            if let message = pairing.message { Text(message).foregroundStyle(Theme.warning) }
            if pairing.pairingName == nil {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(pairing.candidates) { candidate in
                            HStack {
                                Image(systemName: "headphones")
                                Text(candidate.name)
                                Spacer()
                                Button(candidate.paired ? "Connect" : "Pair") { pairing.pair(candidate) }
                                    .disabled(pairing.scanning)
                            }.padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if pairing.candidates.isEmpty && !pairing.scanning {
                            Text("No headphones found. Check pairing mode, keep them nearby, and search again.")
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }.frame(minHeight: 120, maxHeight: 260)
            }
            HStack {
                Button("Bluetooth Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                }
                Spacer()
                Button("Cancel") { controller.dismissPairing() }.keyboardShortcut(.cancelAction)
                Button("Search Again") { pairing.search() }.disabled(pairing.scanning || pairing.pairingName != nil)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear { pairing.search() }
        .onDisappear { pairing.stop() }
    }
}
