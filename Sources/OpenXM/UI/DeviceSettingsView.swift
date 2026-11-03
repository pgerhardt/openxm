import SwiftUI

struct DeviceSettingsView: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        if controller.isConnected { connected } else { disconnected }
    }

    /// App preferences stay reachable without headphones; only the headset's own settings need a connection.
    private var disconnected: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                PageHeader(title: "Settings")
                AdaptiveColumns {
                    if controller.equalizerGuide.reserved { EqualizerGuideCard() }
                    SettingsBackupCard()
                    FirmwareUpdateCard()
                    AppPreferencesCard()
                    UpdatesCard()
                    Card("Headphones", symbol: "headphones") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Connect your headphones to change their settings.")
                                .font(.body15).foregroundStyle(Theme.secondary)
                            if let address = controller.selectedAddress, !controller.phase.isBusy, !controller.isReplay {
                                Button("Connect") { controller.connect(address: address, initiate: true) }
                            }
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var connected: some View {
        let state = controller.state
        let caps = state.capabilities
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                PageHeader(title: "Headphone Settings")
                AdaptiveColumns {
                    if controller.equalizerGuide.reserved { EqualizerGuideCard() }
                    if caps.speakToChat { SpeakToChatCard() }
                    if caps.autoPause || !caps.autoPowerOffOptions.isEmpty { WearingPowerCard() }
                    if !caps.assignableKeys.isEmpty || state.generalSettings.contains(where: { $0.key == "TOUCH_PANEL_SETTING" || ($0.isButtonAssignment && $0.isList) }) || caps.ncAmbButton || caps.headGesture {
                        ControlsCard()
                    }
                    if state.generalSettings.contains(where: { $0.key != "TOUCH_PANEL_SETTING" && $0.isBoolean }) || caps.pairedDevices {
                        ConnectivityCard()
                    }
                    if caps.voiceGuidance || caps.voiceGuidanceCapability?.supportsLanguage == true { VoiceGuidanceCard() }
                    if caps.ncOptimizer { OptimizerCard() }
                    DeviceInfoCard()
                    SettingsBackupCard()
                    FirmwareUpdateCard()
                    AppPreferencesCard()
                    UpdatesCard()
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OnOff: View {
    @Environment(HeadphoneController.self) private var controller
    var title = ""
    let value: Bool?
    let set: (Bool) -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { value ?? false }, set: set))
            .labelsHidden()
            .toggleStyle(AccentToggleStyle())
            .disabled(!controller.canWrite || value == nil)
    }
}

struct WearingPowerCard: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        let state = controller.state
        let caps = state.capabilities
        Card("Wearing & Power", symbol: "figure.stand") {
            VStack(spacing: 14) {
                if caps.autoPause {
                    SettingRow(symbol: "pause.circle", title: "Pause When Taken Off",
                               detail: nil) {
                        OnOff(value: state.autoPause) { controller.apply(.autoPause($0)) }
                    }
                }
                if !caps.autoPowerOffOptions.isEmpty {
                    if caps.autoPause { RowDivider() }
                    SettingRow(symbol: "power.circle", title: "Automatic Power Off") {
                        Picker("Automatic Power Off", selection: Binding(
                            get: { state.autoPowerOff ?? caps.autoPowerOffOptions[0].id },
                            set: { controller.apply(.autoPowerOff($0)) }
                        )) {
                            ForEach(caps.autoPowerOffOptions) { Text($0.title).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!controller.canWrite || state.autoPowerOff == nil)
                    }
                }
            }
        }
    }
}

struct ControlsCard: View {
    @Environment(HeadphoneController.self) private var controller
    @State private var pendingAssignment: (index: Int, preset: UInt8)?

    var body: some View {
        let state = controller.state
        let caps = state.capabilities
        Card("Controls", symbol: "hand.tap") {
            VStack(spacing: 14) {
                ForEach(state.generalSettings.filter { $0.key == "TOUCH_PANEL_SETTING" && $0.isBoolean }) { setting in
                    SettingRow(symbol: setting.symbol, title: setting.title, detail: setting.detail) {
                        OnOff(value: setting.value) { controller.apply(.generalSetting(slot: setting.slot, value: $0)) }
                    }
                }
                ForEach(caps.assignableKeys) { key in
                    if !(state.generalSettings.isEmpty) || key.index > 0 { RowDivider() }
                    let current = state.assignablePresets.flatMap { key.index < $0.count ? $0[key.index] : nil }
                    SettingRow(symbol: "button.programmable", title: key.title,
                               detail: current.flatMap { ButtonFunction(rawValue: $0)?.assignmentDetail }) {
                        Picker(key.title, selection: Binding(
                            get: { current ?? key.defaultPreset },
                            set: { pendingAssignment = (key.index, $0) }
                        )) {
                            ForEach(key.options, id: \.self) { option in
                                Text(ButtonFunction(rawValue: option)?.title ?? String(format: "Function %02X", option)).tag(option)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!controller.canWrite || current == nil)
                    }
                }
                ForEach(state.generalSettings.filter { $0.isButtonAssignment && $0.isList }) { setting in
                    GeneralSettingChoiceRow(setting: setting)
                }
                if caps.ncAmbButton {
                    RowDivider()
                    SettingRow(symbol: "circle.lefthalf.filled", title: "NC/AMB Button Cycles") {
                        Picker("NC/AMB Button Cycles", selection: Binding(
                            get: { state.ncAmbButton ?? .ncAmbientOff },
                            set: { controller.apply(.ncAmbButton($0)) }
                        )) {
                            ForEach(NcAmbButtonCycle.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .disabled(!controller.canWrite || state.ncAmbButton == nil)
                    }
                }
                if caps.headGesture {
                    RowDivider()
                    SettingRow(symbol: "person.crop.circle.badge.checkmark", title: "Head Gestures",
                               detail: nil) {
                        OnOff(value: state.headGesture) { controller.apply(.headGesture($0)) }
                    }
                }
            }
        }
        .confirmationDialog("Change the button's function?",
                            isPresented: Binding(get: { pendingAssignment != nil }, set: { if !$0 { pendingAssignment = nil } })) {
            Button("Change") {
                guard let pending = pendingAssignment, var presets = state.assignablePresets, pending.index < presets.count else { return }
                presets[pending.index] = pending.preset
                controller.apply(.assignable(presets))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The headphones may ask to reconnect to apply a new button assignment. Voice assistants need their phone app to be set up.")
        }
    }
}

/// XM3 receives its choices from the headphones; no unsupported actions are offered.
private struct GeneralSettingChoiceRow: View {
    @Environment(HeadphoneController.self) private var controller
    @State private var assistantGuide: XM3AssistantGuide?
    let setting: GeneralSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(setting.title, systemImage: "button.programmable")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            Picker(setting.title, selection: Binding<UInt8?>(
                get: { setting.selectedIndex },
                set: { if let index = $0 { controller.apply(.generalSettingChoice(slot: setting.slot, index: index)) } }
            )) {
                if setting.selectedIndex == nil { Text("Reading…").tag(nil as UInt8?) }
                ForEach(setting.options) { Text($0.title).tag(Optional($0.index)) }
            }
            .labelsHidden().fixedSize()
            .disabled(!controller.canWrite || setting.selectedIndex == nil)
            Text("The headphones may reconnect after a change. Assistant setup requires your phone.")
                .font(.caption11).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let guide = XM3AssistantGuide.selected(setting: setting, model: controller.state.modelName) {
                Button("Set Up \(guide.title)…") { assistantGuide = guide }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $assistantGuide) { AssistantSetupView(guide: $0) }
    }
}

extension ButtonFunction {
    var assignmentDetail: String {
        switch self {
        case .ambientSoundControl: "Press: Noise Canceling ↔ Ambient. Hold: NC Optimizer."
        case .googleAssistant: "Talk to Google Assistant (requires setup on an Android phone)."
        case .amazonAlexa: "Talk to Alexa (requires the Alexa app on your phone)."
        case .tencentXiaowei: "Talk to Tencent Xiaowei (requires its phone app and supported service region)."
        default: ""
        }
    }
}

struct ConnectivityCard: View {
    @Environment(HeadphoneController.self) private var controller
    @State private var pendingSetting: (slot: UInt8, value: Bool)?

    var body: some View {
        let state = controller.state
        let caps = state.capabilities
        Card("Connectivity", symbol: "point.3.connected.trianglepath.dotted") {
            VStack(spacing: 14) {
                ForEach(state.generalSettings.filter { $0.key != "TOUCH_PANEL_SETTING" && $0.isBoolean }) { setting in
                    SettingRow(symbol: setting.symbol, title: setting.title, detail: setting.detail) {
                        OnOff(value: setting.value) { value in
                            if setting.key.contains("MULTIPOINT") {
                                pendingSetting = (setting.slot, value)
                            } else {
                                controller.apply(.generalSetting(slot: setting.slot, value: value))
                            }
                        }
                    }
                }
                if caps.pairedDevices {
                    if !state.generalSettings.isEmpty { RowDivider() }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("DEVICES").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
                        if let devices = state.pairedDevices, !devices.isEmpty {
                            ForEach(devices) { device in
                                HStack(spacing: 10) {
                                    Image(systemName: device.connected ? "laptopcomputer.and.iphone" : "laptopcomputer")
                                        .foregroundStyle(device.connected ? Theme.accent : Theme.tertiary)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(device.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                                        Text(device.connected ? (device.isPlaybackSource ? "Connected · playing" : "Connected") : "Paired")
                                            .font(.caption11).foregroundStyle(Theme.secondary)
                                    }
                                    Spacer()
                                }
                                .accessibilityElement(children: .combine)
                            }
                        } else {
                            Text("No paired devices reported.").font(.caption11).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Change multipoint?", isPresented: Binding(get: { pendingSetting != nil }, set: { if !$0 { pendingSetting = nil } })) {
            Button(pendingSetting?.value == true ? "Turn On" : "Turn Off") {
                if let pending = pendingSetting { controller.apply(.generalSetting(slot: pending.slot, value: pending.value)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The headphones restart their Bluetooth connection to apply this. OpenXM reconnects automatically.")
        }
    }
}

struct VoiceGuidanceCard: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        let state = controller.state
        Card("Voice Guidance", symbol: "speaker.wave.2.bubble") {
            VStack(spacing: 14) {
                if state.capabilities.voiceGuidance {
                    SettingRow(symbol: "text.bubble", title: "Voice Guidance", detail: nil) {
                        OnOff(value: state.voiceGuidance) { controller.apply(.voiceGuidance($0)) }
                            .disabled(state.family == .v1 && state.voiceGuidanceDetails.onOffAvailable != true)
                    }
                }
                if let capability = state.capabilities.voiceGuidanceCapability, capability.supportsLanguage {
                    if state.capabilities.voiceGuidance { RowDivider() }
                    SettingRow(symbol: "globe", title: "Guidance Language",
                               detail: "Changing language requires a downloaded voice package. Open Voice Language Packages to review experimental installation.") {
                        Text(state.voiceGuidanceDetails.language?.title ?? "Not reported")
                            .foregroundStyle(.secondary)
                            .accessibilityValue(Text(state.voiceGuidanceDetails.language?.title ?? "Not reported"))
                    }
                    DisclosureGroup("Languages reported by these headphones") {
                        Text(capability.languages.map(\.title).joined(separator: ", "))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    if state.family == .v1 && state.modelName == "WH-1000XM3" {
                        Button("Voice Language Packages…") { controller.guidancePackages.open() }
                    }
                }
                if let range = state.capabilities.voiceGuidanceVolume, let volume = state.voiceGuidanceVolume {
                    RowDivider()
                    SettingRow(symbol: "speaker.wave.1", title: "Guidance Volume") {
                        Stepper("\(volume)", value: Binding(get: { volume }, set: { controller.apply(.voiceGuidanceVolume($0)) }), in: range)
                            .disabled(!controller.canWrite)
                    }
                }
            }
        }
    }
}

struct OptimizerCard: View {
    @Environment(HeadphoneController.self) private var controller
    @State private var confirming = false

    var body: some View {
        let state = controller.state
        Card("NC Optimizer", symbol: "dial.medium") {
            VStack(alignment: .leading, spacing: 12) {
                Text(instructions)
                    .font(.caption11).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    switch state.optimizer {
                    case .running, .measuringPersonal, .measuringPressure:
                        ProgressView().controlSize(.small)
                        Text(state.optimizer.title).font(.label).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Cancel") { controller.cancelNoiseOptimizer() }
                            .disabled(!controller.canCancelNoiseOptimizer)
                    case .finished, .idle, .unknown:
                        if state.optimizer == .finished {
                            Label(state.optimizer.title, systemImage: "checkmark.circle.fill").font(.label).foregroundStyle(Theme.good)
                        } else if state.optimizerAvailable != true || !state.optimizer.canStart {
                            Text("Optimizer unavailable").font(.label).foregroundStyle(Theme.secondary)
                        } else if state.optimizerPersonalMeasured == true {
                            Text("Personal fit measured").font(.label).foregroundStyle(Theme.text)
                        }
                        if let pressure = state.optimizerMeasuredPressure, (7...10).contains(pressure) {
                            Text("Air pressure \(String(format: "%.1f", Double(pressure) / 10)) atm")
                                .font(.caption11).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Button { confirming = true } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .foregroundStyle(Theme.onAccent)
                        .disabled(!controller.canStartNoiseOptimizer)
                    }
                }
            }
        }
        .confirmationDialog("Start the NC Optimizer?", isPresented: $confirming) {
            Button("Start Optimizing") { controller.startNoiseOptimizer() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Put the headphones on first. They will play test tones while measuring.")
        }
    }

    private var instructions: String {
        if let seconds = controller.state.capabilities.ncOptimizerCapability?.estimatedSeconds, seconds > 0 {
            return "Wear the headphones first. Plays test tones for about \(seconds) seconds."
        }
        return "Wear the headphones first. Plays test tones while measuring."
    }
}

struct DeviceInfoCard: View {
    @Environment(HeadphoneController.self) private var controller
    @State private var confirmPowerOff = false

    var body: some View {
        let state = controller.state
        Card("About These Headphones", symbol: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                infoRow("Model", state.modelName)
                infoRow("Firmware", state.firmware)
                infoRow("Color", state.colorName)
                infoRow("Series", state.seriesName)
                if let refresh = controller.lastRefresh {
                    infoRow("Last refreshed", refresh.formatted(date: .omitted, time: .standard))
                }
            }
            HStack(spacing: 10) {
                if controller.isConnected {
                    Button("Refresh") { controller.refreshStatus() }.disabled(!controller.canWrite)
                    Button("Disconnect Controls") { controller.disconnect() }
                        .help("Closes OpenXM's control channel only; audio stays connected.")
                        .disabled(controller.isReplay || controller.settingsOperationInProgress || controller.firmwareOperationInProgress)
                } else if let address = controller.selectedAddress, !controller.isReplay {
                    Button("Connect") { controller.connect(address: address, initiate: true) }
                }
                Spacer()
                if state.capabilities.powerOff && controller.canWrite {
                    Button(role: .destructive) { confirmPowerOff = true } label: {
                        Label("Turn Off Headphones", systemImage: "power")
                    }
                }
            }
            .controlSize(.regular)
        }
        .confirmationDialog("Turn off the headphones?", isPresented: $confirmPowerOff) {
            Button("Turn Off", role: .destructive) { controller.powerOff() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They disconnect from every device. Turn them on again with their power button.")
        }
    }

    @ViewBuilder
    private func infoRow(_ title: String, _ value: String?) -> some View {
        GridRow {
            Text(title).font(.label).foregroundStyle(Theme.secondary)
            Text(value ?? "—").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                .textSelection(.enabled)
        }
    }
}

struct AppPreferencesCard: View {
    @Environment(LoginItem.self) private var loginItem
    @AppStorage("showMenuBarExtra") private var showMenuBar = true

    var body: some View {
        Card("OpenXM", symbol: "macwindow") {
            VStack(spacing: 14) {
                SettingRow(symbol: "menubar.rectangle", title: "Show in Menu Bar",
                           detail: showMenuBar
                               ? "Closing the window keeps OpenXM running in the menu bar. Quit from there or with ⌘Q."
                               : "Closing the window quits OpenXM and stops scene automations.") {
                    Toggle("Show in Menu Bar", isOn: $showMenuBar).labelsHidden().toggleStyle(AccentToggleStyle())
                }
                RowDivider()
                SettingRow(symbol: "power", title: "Open at Login", detail: loginDetail) {
                    HStack(spacing: 10) {
                        if loginItem.status == .requiresApproval {
                            Button("Open System Settings") { loginItem.openSystemSettings() }
                                .controlSize(.small)
                        }
                        Toggle("Open at Login", isOn: Binding(
                            get: { loginItem.status == .enabled || loginItem.status == .requiresApproval },
                            set: { loginItem.setEnabled($0) }))
                            .labelsHidden().toggleStyle(AccentToggleStyle())
                            .disabled(loginItem.status == .unavailable)
                    }
                }
            }
        }
        .onAppear { loginItem.refresh() }
    }

    private var loginDetail: String? {
        if let error = loginItem.error { return error }
        return switch loginItem.status {
        case .enabled:
            showMenuBar ? "Starts quietly in the menu bar when you log in." : "Opens when you log in."
        case .requiresApproval:
            "Allow OpenXM in System Settings → General → Login Items."
        case .unavailable:
            "Not available for this copy. Move OpenXM to the Applications folder and open it from there."
        case .disabled:
            "Have your menu bar controls and scenes ready as soon as you log in."
        }
    }
}

struct UpdatesCard: View {
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        @Bindable var updates = updates
        Card("Updates", subtitle: "Version \(updates.currentVersion)", symbol: "arrow.down.circle") {
            VStack(spacing: 14) {
                SettingRow(symbol: "clock.arrow.circlepath", title: "Check Automatically") {
                    Toggle("Check Automatically", isOn: $updates.checksAutomatically)
                        .labelsHidden().toggleStyle(AccentToggleStyle())
                }
                RowDivider()
                SettingRow(symbol: statusSymbol, title: statusTitle, detail: statusDetail) {
                    HStack(spacing: 10) {
                        if let release = updates.available {
                            Button("Download") { updates.download(release) }
                                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                        } else if updates.state == .checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Check Now") { Task { await updates.check() } }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var statusSymbol: String {
        switch updates.state {
        case .available: "sparkles"
        case .failed: "exclamationmark.triangle"
        default: "checkmark.seal"
        }
    }

    private var statusTitle: String {
        switch updates.state {
        case .available(let release): "Version \(release.version) Available"
        case .upToDate: "Up to Date"
        case .checking: "Checking…"
        case .failed: "Couldn’t Check"
        case .idle: "Software Update"
        }
    }

    private var statusDetail: String? {
        if case .failed(let message) = updates.state { return message }
        if updates.available != nil { return "Download opens the release page on GitHub. Replace the app in your Applications folder with the new one." }
        return updates.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))." }
    }
}
