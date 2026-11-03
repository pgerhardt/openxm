import AppKit
import SwiftUI

struct EqualizerGuideCard: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        let guide = controller.equalizerGuide
        Card(guide.reserved ? "Equalizer Recovery" : "Find Your Equalizer", symbol: "ear.badge.waveform") {
            VStack(alignment: .leading, spacing: 12) {
                Text(guide.reserved
                     ? "A listening comparison has an unfinished EQ recovery. Restore it before making other headphone changes."
                     : "Compare sounds while listening to your music, refine your favorite, and save it to Custom 2.")
                    .font(.body15).foregroundStyle(Theme.secondary)
                Button(guide.reserved ? "Review EQ Recovery…" : "Find Your Equalizer…") { guide.open() }
                    .disabled(controller.isReplay || (!guide.reserved && !guide.canStart))
            }
        }
    }
}

struct EqualizerGuideView: View {
    @Environment(HeadphoneController.self) private var controller
    @State private var confirmKeepCurrent = false

    var body: some View {
        let guide = controller.equalizerGuide
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Find Your Equalizer").font(.title2.bold())
                Spacer()
                if guide.busy { ProgressView().controlSize(.small) }
                Button("Done") { guide.isPresented = false }.disabled(guide.busy || guide.active)
            }
            if guide.active {
                comparison
            } else if guide.reserved {
                recovery
            } else {
                Text("Find a sound you like in three listening comparisons: balance, bass and detail.")
                Text("Start a familiar song in your music app at a comfortable volume. OpenXM temporarily changes EQ as you compare. Cancel restores your original presets; Save replaces Custom 2.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Start Comparisons") { guide.start() }
                    .buttonStyle(.borderedProminent).disabled(!guide.canStart)
            }
            if let message = guide.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            if let error = guide.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(24).frame(width: 650)
        .interactiveDismissDisabled(guide.busy || guide.active)
        .confirmationDialog("Keep the current EQ without restoring your original presets?", isPresented: $confirmKeepCurrent) {
            Button("Keep Current EQ") { guide.keepCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The headphones may still contain a comparison curve or an unfinished Custom 2 save. OpenXM will archive the recovery file and allow other settings changes again.")
        }
    }

    private var comparison: some View {
        let guide = controller.equalizerGuide
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(guide.round.title).font(.headline)
                Spacer()
                Text(guide.round == .review ? "Review" : "Step \(guide.round.rawValue + 1) of 3")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let result = guide.result {
                Text("Compare your result with the original EQ setting before saving.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    ForEach(Array(zip(["400 Hz", "1 kHz", "2.5 kHz", "6.3 kHz", "16 kHz"], result.bands)), id: \.0) { name, value in
                        VStack(spacing: 6) {
                            Text(name).font(.caption).foregroundStyle(.secondary)
                            Text(value.formatted(.number.sign(strategy: .always()))).monospacedDigit()
                        }.frame(maxWidth: .infinity)
                    }
                    VStack(spacing: 6) {
                        Text("Clear Bass").font(.caption).foregroundStyle(.secondary)
                        Text(result.bass.formatted(.number.sign(strategy: .always()))).monospacedDigit()
                    }.frame(maxWidth: .infinity)
                }.padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                Button(guide.listeningToOriginal ? "Listen to Your Result" : "Listening to Your Result") { guide.compareResult() }
                    .disabled(guide.busy || !controller.isConnected)
            } else {
                Text("Select a sound to hear it. Compare as often as you like, then keep your favorite.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(guide.choices.indices, id: \.self) { index in
                        Button { guide.audition(index) } label: {
                            VStack(spacing: 10) {
                                Image(systemName: guide.selected == index ? "checkmark.circle.fill" : "waveform")
                                    .font(.title2)
                                Text("Sound \(index + 1)").fontWeight(.medium)
                            }.frame(maxWidth: .infinity).padding(.vertical, 16)
                        }
                        .buttonStyle(.bordered)
                        .tint(guide.selected == index ? Theme.accent : .gray)
                        .accessibilityLabel("Listen to Sound \(index + 1)")
                        .accessibilityValue(guide.selected == index ? "Selected favorite" : "Not selected")
                        .disabled(guide.busy || !controller.isConnected)
                    }
                }
            }
            Button(guide.listeningToOriginal ? "Listening to Original" : "Compare Original Sound") { guide.compareOriginal() }
                .disabled(guide.busy || !controller.isConnected)
            Divider()
            HStack {
                Button("Cancel & Restore") { guide.cancelAndRestore() }.disabled(!guide.canRecover)
                if !controller.isConnected {
                    Button("Reconnect") { reconnect() }.disabled(controller.phase.isBusy || guide.busy)
                }
                if !guide.canRecover {
                    Button("Restore Later") { guide.restoreLater() }.disabled(guide.busy)
                }
                Spacer()
                if guide.round != .balance { Button("Back") { guide.back() }.disabled(guide.busy) }
                if guide.round == .review {
                    Button("Save to Custom 2") { guide.save() }
                        .buttonStyle(.borderedProminent).disabled(guide.busy || !controller.isConnected)
                } else {
                    Button("Keep Favorite") { guide.next() }
                        .buttonStyle(.borderedProminent).disabled(guide.busy || guide.selected == nil || !controller.isConnected)
                }
            }
        }
    }

    private var recovery: some View {
        let guide = controller.equalizerGuide
        return VStack(alignment: .leading, spacing: 14) {
            Text("Restore your original equalizer").font(.headline)
            if let record = guide.record {
                Text("Saved for \(record.model) on firmware \(record.firmware). Restore with these headphones connected and EQ available.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restore Original EQ") { guide.cancelAndRestore() }.buttonStyle(.borderedProminent).disabled(!guide.canRecover)
                if !controller.isConnected || controller.selectedAddress != guide.record?.address {
                    Button("Reconnect") { reconnect() }.disabled(guide.record == nil || guide.busy || controller.phase.isBusy)
                }
                Button("Show Recovery File") { NSWorkspace.shared.activateFileViewerSelecting([guide.recoveryURL]) }
                    .disabled(guide.busy)
            }
            Button("Keep Current EQ…") { confirmKeepCurrent = true }.disabled(guide.busy)
        }
    }

    private func reconnect() {
        guard let address = controller.equalizerGuide.record?.address else { return }
        controller.connect(address: address, initiate: true)
    }
}
