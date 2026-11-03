import SwiftUI

struct SettingsBackupCard: View {
    @Environment(HeadphoneController.self) private var controller
    @Environment(SceneStore.self) private var scenes

    var body: some View {
        Card("Settings Backup", symbol: "externaldrive.badge.timemachine") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save headphone settings to a file, or review a backup before restoring it.")
                    .font(.body15).foregroundStyle(Theme.secondary)
                HStack {
                    Button("Backup & Restore…") { controller.settingsBackup.isPresented = true }
                    Button("Voice Package Files…") { controller.guidancePackages.open() }
                }
                Button("App Data Backup…") { scenes.appDataBackup.isPresented = true }
                Text("Back up scenes, saved places and listening history, even while headphones are disconnected.")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }
        }
    }
}

struct SettingsBackupView: View {
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        @Bindable var workflow = controller.settingsBackup
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings Backup & Restore").font(.title2.bold())
                Spacer()
                Button("Done") { workflow.isPresented = false }.disabled(workflow.busy)
            }
            Text(SettingsBackup.scope).font(.callout).foregroundStyle(.secondary)
            Toggle("Include all custom EQ curves", isOn: $workflow.includeCustomEQ)
                .toggleStyle(.checkbox).disabled(workflow.busy)
            if workflow.includeCustomEQ {
                Text("Reading briefly selects each custom preset and restores the original selection. Sound may change during the read; stop playback first. No curve values are changed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Read Headphones") { workflow.createBackup() }.disabled(!controller.canWrite || workflow.busy)
                Button("Open Backup…") { workflow.openBackup() }.disabled(workflow.busy)
                Button("Save Backup…") { workflow.saveBackup() }.disabled(workflow.backup == nil || workflow.busy)
                Spacer()
                if workflow.busy { ProgressView().controlSize(.small) }
            }
            if let backup = workflow.backup {
                Text("\(backup.model) · firmware \(backup.firmware ?? "unreported") · \(backup.createdAt.formatted())")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(workflow.entries) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Toggle(entry.setting.title, isOn: Binding(
                                    get: { workflow.selected.contains(entry.id) },
                                    set: { if $0 { workflow.selected.insert(entry.id) } else { workflow.selected.remove(entry.id) } }
                                )).labelsHidden().toggleStyle(.checkbox)
                                    .disabled(workflow.busy || entry.unavailableReason != nil || entry.setting.languageToRestore != nil)
                                    .accessibilityLabel(entry.setting.title)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.setting.title).fontWeight(.medium)
                                    Text(entry.setting.detail).font(.callout).foregroundStyle(.secondary)
                                    if let reason = entry.unavailableReason {
                                        Text("Unavailable: \(reason)").font(.caption).foregroundStyle(.orange)
                                    } else if let result = workflow.outcomes[entry.id] {
                                        Text(result.message).font(.caption).foregroundStyle(resultColor(result))
                                    } else if workflow.activeID == entry.id {
                                        Text("Applying and reading back…").font(.caption).foregroundStyle(.secondary)
                                    } else if entry.alreadyMatches {
                                        Text("Matches the last device read").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if entry.setting.languageToRestore != nil {
                                        Text("Language packages are reviewed and installed separately from ordinary settings.")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Button("Review Language Package…") { workflow.reviewVoiceLanguage() }
                                            .disabled(!workflow.canReviewVoiceLanguage)
                                    }
                                }
                                Spacer()
                            }
                            Divider()
                        }
                        if workflow.entries.isEmpty { Text("Connect matching headphones and choose Review to see the restore preview.").foregroundStyle(.secondary) }
                        if !backup.omissions.isEmpty {
                            DisclosureGroup("Not included (\(backup.omissions.count))") {
                                ForEach(Array(backup.omissions.enumerated()), id: \.offset) { _, text in
                                    Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }.padding(.trailing, 8)
                }
                .frame(minHeight: 210, maxHeight: 400)
            }
            if let message = workflow.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            if let error = workflow.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if workflow.busy { Button("Stop") { workflow.stop() } }
                Spacer()
                Button("Review") { workflow.review() }.disabled(workflow.backup == nil || !controller.canWrite || workflow.busy)
                Button("Restore Selected") { workflow.restore() }.buttonStyle(.borderedProminent).disabled(!workflow.canRestore)
            }
        }
        .padding(24).frame(width: 660)
        .interactiveDismissDisabled(workflow.busy)
        .alert(controller.state.alert?.title ?? "", isPresented: Binding(
            get: { controller.state.alert != nil },
            set: { if !$0 { controller.answerAlert(accept: false) } }
        ), presenting: controller.state.alert) { alert in
            if alert.requiresAnswer {
                Button("Continue") { controller.answerAlert(accept: true) }
                Button("Cancel", role: .cancel) { controller.answerAlert(accept: false) }
            } else { Button("OK") { controller.answerAlert(accept: true) } }
        } message: { Text($0.message) }
    }

    private func resultColor(_ result: SettingsRestoreOutcome) -> Color {
        switch result {
        case .confirmed: .green
        case .failed: .red
        case .adjusted, .waitingForReconnect: .orange
        }
    }
}
