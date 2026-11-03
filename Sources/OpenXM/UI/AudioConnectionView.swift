import SwiftUI

struct AudioConnectionCard: View {
    @Environment(HeadphoneController.self) private var controller
    @State private var pendingCodec: CodecSelection?
    @State private var confirmDriver = false
    @State private var advancedExpanded = false
    @State private var advancedHovered = false

    var body: some View {
        let info = controller.audioConnectionPresentation
        let route = controller.audioConnection.snapshot
        let transport = controller.codecTransport
        Card("Audio Connection", subtitle: controller.isReplay ? "Recorded headphone data · Mac route not checked" : transport.isEngaged ? transport.headline : info.headline,
             symbol: "waveform.path") {
            if !controller.isReplay && (controller.state.modelName == "WH-1000XM3" || transport.isEngaged || transport.message != nil) {
                HStack {
                    Text("Preferred codec").font(.label).foregroundStyle(Theme.secondary)
                    Spacer()
                    Picker("Preferred codec", selection: Binding(get: { transport.preferredCodec(for: controller.selectedAddress) }, set: requestCodec)) {
                        ForEach(CodecSelection.allCases) { choice in
                            Text(choice.title).tag(choice)
                                .disabled(choice != .automatic && (!controller.canSelectCodec || !transport.driverInstalled || transport.isTransitioning))
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityIdentifier("codecSelection")
                }
                if !transport.isEngaged, transport.preferredCodec(for: controller.selectedAddress) != .automatic {
                    Button("Use saved \(transport.preferredCodec(for: controller.selectedAddress).title)") {
                        requestCodec(transport.preferredCodec(for: controller.selectedAddress))
                    }
                    .disabled(!controller.canSelectCodec || !transport.canStartSession)
                }
                Text("Saved for these headphones and restored when they connect after OpenXM launches.")
                    .font(.caption11).foregroundStyle(Theme.secondary)
                if transport.isEngaged {
                    Button("Return to Automatic (macOS)") { controller.selectCodec(.automatic) }
                        .disabled(transport.phase == .stopping)
                    Text("Headphone microphone unavailable. Use Automatic for calls.")
                        .font(.caption11).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                } else if !transport.helperAvailable {
                    Text("The codec helper is missing from this build.").font(.caption11).foregroundStyle(Theme.secondary)
                } else if !transport.driverInstalled {
                    HStack {
                        Button(transport.installingDriver ? "Installing…" : "Install Audio Driver…") { confirmDriver = true }
                            .disabled(transport.installingDriver || !controller.canSelectCodec)
                        Button("Refresh") { transport.refreshAvailability() }.disabled(transport.installingDriver)
                    }
                    Text("Custom codecs require the OpenXM virtual audio driver.").font(.caption11).foregroundStyle(Theme.secondary)
                } else {
                    Text("Custom codecs use an experimental audio output. Automatic keeps normal macOS audio and microphone support.")
                        .font(.caption11).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let message = transport.message {
                    Text(message).font(.caption11).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                    if !transport.isEngaged {
                        Button(transport.recoveringOutput ? "Restoring audio…" : transport.playbackBlocked ? "Restore audio anyway" : "Recover Audio Output") {
                            transport.recoverIfNeeded(allowPlaying: transport.playbackBlocked)
                        }
                        .disabled(transport.recoveringOutput)
                        .help(transport.playbackBlocked ? "Restore the previous output or available speakers even if media is still playing." : "Restore an available audio output.")
                    }
                }
                Divider().overlay(Theme.hairline)
            }
            VStack(spacing: 10) {
                row(transport.isEngaged ? "Negotiated codec" : "Music codec", info.codecLabel)
                if !controller.isReplay {
                    if transport.isEngaged {
                        if let rate = transport.sampleRate { row("Bluetooth sample rate", "\((rate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz") }
                        row("Live bitrate (1 s)", transport.recentKbps.map { bitrate($0) + (transport.phase == .idle ? " · idle" : "") } ?? "Not reported")
                            .monospacedDigit()
                        if let target = transport.targetKbps { row("Encoder target", bitrate(target)).monospacedDigit() }
                    } else {
                        row("Mac audio format", route?.formatDescription ?? "Unavailable")
                        row("Headphone mic", route?.micDescription ?? "Checking…")
                    }
                }
            }
            if info.hasMicWarning {
                Label("For better music quality, select your Mac’s microphone or a USB mic in Zoom and keep these headphones as the speaker.", systemImage: "mic.fill")
                    .font(.label).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                if route?.likelyHandsFree == true {
                    Text("Mic activity and low-rate mono output suggest hands-free mode. Its speech codec is not reported; the music codec above does not describe call audio.")
                        .font(.caption11).foregroundStyle(Theme.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                advancedToggle
                if advancedExpanded {
                    VStack(alignment: .leading, spacing: 14) {
                        if !controller.isReplay {
                            if transport.isEngaged {
                                advancedControls(transport)
                                Divider().overlay(Theme.hairline)
                                row("Profile", transport.hasConfirmedSession ? "A2DP · stereo music" : "Negotiating…")
                                row("Mac output", transport.routed ? "OpenXM Headphones" : "Waiting for audio route…")
                                row("Volume control", transport.volumeSynced ? "Linked to headphones" : "Waiting for headphones…")
                                row("Sony controls", controller.isConnected ? "Connected" : "Reconnecting…")
                                if let quality = transport.activeLDACQuality {
                                    row("Active LDAC quality", quality.title)
                                    if let fast = transport.activeFastRecovery { row("Active Auto backoff", fast ? "Fast · 1–5 s" : "Conservative · 30–300 s") }
                                }
                                if let delay = transport.reportedDelayMs { row("Headphone-reported delay", "\(Int(delay)) ms") }
                                if let delay = transport.estimatedDelayMs { row("Output delay estimate", "\(Int(delay)) ms · not measured") }
                            } else {
                                row("Profile", route?.likelyHandsFree == true ? "Hands-free likely" : "Music / system managed")
                                row("Mac output", route?.routeDescription ?? "Checking…")
                                row("Live bitrate", "Unavailable in Automatic")
                            }
                            if let name = route?.defaultInputName { row("System input", name) }
                        }
                        aboutAudioQuality(transport)
                    }.padding(.top, 10)
                }
            }
            .font(.label).tint(Theme.secondary)
        }
        .task { if !controller.isReplay { transport.refreshAvailability() } }
        .alert("Use experimental Bluetooth audio?", isPresented: Binding(get: { pendingCodec != nil }, set: { if !$0 { pendingCodec = nil } })) {
            Button("Cancel", role: .cancel) { pendingCodec = nil }
            Button("Use \(pendingCodec?.title ?? "codec")") {
                if let selection = pendingCodec { controller.selectCodec(selection) }
                pendingCodec = nil
            }
        } message: {
            Text("The headphones will reconnect and Mac audio will use OpenXM Headphones. The headphone microphone will be unavailable. This choice is saved for these headphones and restored after OpenXM launches. Return to Automatic before calls. The codec is confirmed only after the headphones accept it.")
        }
        .alert("Install OpenXM audio driver?", isPresented: $confirmDriver) {
            Button("Cancel", role: .cancel) {}
            Button("Install") { transport.installDriver() }
        } message: {
            Text("This installs OpenXM Headphones and restarts the Mac audio service, briefly interrupting all audio. macOS will ask for administrator authorization.")
        }
    }

    private var advancedToggle: some View {
        Button { advancedExpanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text("Advanced").fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(advancedHovered ? Theme.cardRaised : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            // Include the padding and empty row space in the button's hit area.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .onHover { advancedHovered = $0 }
        .accessibilityIdentifier("audioAdvancedDisclosure")
        .accessibilityValue(advancedExpanded ? "Expanded" : "Collapsed")
        .help(advancedExpanded ? "Hide advanced audio settings" : "Show advanced audio settings")
    }

    @ViewBuilder private func advancedControls(_ transport: CodecTransportController) -> some View {
        HStack {
            Text("Sample rate").font(.label).foregroundStyle(Theme.secondary)
            Spacer()
            Picker("Sample rate", selection: Binding(get: { transport.advancedSettings.sampleRate }, set: {
                var settings = transport.advancedSettings; settings.sampleRate = $0; transport.setAdvancedSettings(settings)
            })) {
                ForEach(CodecSampleRate.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.menu).fixedSize().accessibilityIdentifier("codecSampleRate")
                .disabled(!transport.canChangeAdvancedSettings)
        }
        Text("Auto uses the Mac output's current rate. Changing it briefly interrupts audio; macOS resamples when needed.")
            .font(.caption11).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        if transport.requested == .ldac {
            let rate = transport.advancedSettings.sampleRate == .automatic ? (transport.sampleRate ?? 44100) : Double(transport.advancedSettings.sampleRate.rawValue)
            HStack {
                Text("LDAC quality").font(.label).foregroundStyle(Theme.secondary)
                Spacer()
                Picker("LDAC quality", selection: Binding(get: { transport.advancedSettings.ldacQuality }, set: {
                    var settings = transport.advancedSettings; settings.ldacQuality = $0; transport.setAdvancedSettings(settings)
                })) {
                    ForEach(LDACQuality.allCases) { Text($0.title(at: rate)).tag($0) }
                }.labelsHidden().pickerStyle(.menu).fixedSize().accessibilityIdentifier("ldacQuality")
                    .disabled(!transport.canChangeAdvancedSettings)
            }
            if transport.advancedSettings.ldacQuality == .adaptive {
                HStack {
                    Text("Auto retry backoff").font(.label).foregroundStyle(Theme.secondary)
                    Spacer()
                    Picker("Auto retry backoff", selection: Binding(get: { transport.advancedSettings.fastRecovery }, set: {
                        var settings = transport.advancedSettings; settings.fastRecovery = $0; transport.setAdvancedSettings(settings)
                    })) {
                        Text("Conservative · 30–300 s").tag(false)
                        Text("Fast · 1–5 s").tag(true)
                    }.labelsHidden().pickerStyle(.menu).fixedSize().accessibilityIdentifier("ldacRecovery")
                        .disabled(!transport.canChangeAdvancedSettings)
                }
                Text("Fast is experimental. These are extra retry delays; LDAC still waits for a clear queue before increasing quality.")
                    .font(.caption11).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Fixed quality keeps the encoder target steady. High may interrupt audio if the connection cannot keep up.")
                    .font(.caption11).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func aboutAudioQuality(_ transport: CodecTransportController) -> some View {
        DisclosureGroup("About audio quality") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automatic shows the music codec reported by the headphones. Custom mode shows the codec accepted by the headphones during Bluetooth negotiation. Choosing a preference alone does not confirm it.")
                    Text("Mac audio format describes the local output stream, not Bluetooth bitrate or the original recording’s resolution. Reported and estimated delays are not end-to-end measurements; video synchronization depends on the player.")
                    Text("For music, avoid using the headphone mic. Choose a separate microphone in your call app; its input can differ from the system input shown here.")
                    Text("A Lossless setting in Spotify does not make Bluetooth lossless. Changing the codec or sample rate cannot restore detail missing from the original recording.")
                    Text("Custom audio uses private macOS Bluetooth interfaces, which an OS update may change. Use Automatic if audio is unreliable or you need the headphone microphone.")
                    Text("Live bitrate is the media data sent over the last second, including packet headers. It updates about once a second. Encoder target is the current encoding rate (a peak for AAC VBR); it can change as the link adapts. The two values can differ because of headers, buffering and variable bitrate. Neither measures Bluetooth retransmissions or Spotify’s source quality. Bitrate is unavailable in Automatic mode.")
                    Text("In custom mode, Mac volume controls and the headphones share one volume level. Connecting adopts the headphones’ current volume. Mute still silences audio locally. If linked volume becomes unavailable, audio returns to Automatic.")
                    Text("Codec changes keep audio quiet while reconnecting. If headphone audio ends, OpenXM restores the previous output or uses an available speaker or wired output after a short recovery period. That output keeps its own volume. Choosing an output yourself takes priority.")
                    Text("On unexpected headphone loss, OpenXM pauses the current media player when it can verify that the player is using this output. It checks that playback paused before restoring speakers. If the check fails, audio stays silent until you restore it or select an output. Reconnecting never automatically starts playback.")
                    Link("Why Bluetooth audio changes during calls ↗", destination: URL(string: "https://support.apple.com/en-us/102217")!)
                    if !transport.diagnostics.isEmpty {
                        DisclosureGroup("Codec connection diagnostics") {
                            ScrollView {
                                Text(transport.diagnostics).font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 160)
                        }
                    }
                }
                .font(.caption11).foregroundStyle(Theme.secondary).padding(.top, 8)
            }
            .font(.label).tint(Theme.secondary)
        }

    private func requestCodec(_ selection: CodecSelection) {
        if selection == .automatic || controller.codecTransport.isEngaged { controller.selectCodec(selection) }
        else { pendingCodec = selection }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(Theme.text).multilineTextAlignment(.trailing)
        }
        .font(.label).accessibilityElement(children: .combine)
    }

    private func bitrate(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0)).grouping(.never))) kbps"
    }
}
