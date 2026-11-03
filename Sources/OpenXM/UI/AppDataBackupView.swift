import SwiftUI

struct AppDataBackupView: View {
    @Environment(SceneStore.self) private var scenes
    @Environment(HeadphoneController.self) private var controller

    var body: some View {
        @Bindable var workflow = scenes.appDataBackup
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("App Data Backup & Restore").font(.title2.bold())
                Spacer()
                Button("Done") { workflow.isPresented = false }.keyboardShortcut(.cancelAction)
            }
            Text("Portable OpenXM files for scenes, saved places, listening times and song history. Headphone settings and voice packages have separate backups. Sony account data is not included.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox("Save this Mac’s data") {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Scenes and saved places", isOn: $workflow.exportScenes)
                    Toggle("Listening history", isOn: $workflow.exportHistory)
                    Toggle("Song history (titles, artists, albums, apps and times)", isOn: $workflow.exportContent)
                    Text("Files are unencrypted and may include place coordinates, listening times and song details. Scene run results, device addresses and account credentials are excluded.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Save App Data…") { workflow.saveBackup() }
                        .disabled(!workflow.exportScenes && !workflow.exportHistory && !workflow.exportContent)
                }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            HStack {
                Button("Open App Data…") { workflow.openBackup() }
                if let backup = workflow.backup {
                    Text("Saved \(backup.createdAt.formatted())").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let backup = workflow.backup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let savedScenes = backup.scenes {
                            Toggle("Restore scenes: \(savedScenes.count) · saved places: \(backup.placeCount)", isOn: $workflow.restoreScenes)
                            if workflow.restoreScenes {
                                Text("Matching scene IDs will be replaced. Other scenes stay. Imported automatic triggers will be disabled; enable them later in Scenes. Location permission stays unchanged.")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(savedScenes) { scene in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(scene.name).fontWeight(.medium)
                                        if let existing = scenes.scene(scene.id) {
                                            Text("Replaces “\(existing.name)”").font(.caption).foregroundStyle(.orange)
                                        }
                                        Text(scene.summary.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                        Text("\(scene.trigger.title)\(scene.trigger.isAutomatic ? " · will be disabled" : "")")
                                            .font(.caption).foregroundStyle(.secondary)
                                        if case .location(let place) = scene.trigger, let center = place.center {
                                            Text("Location: \(center.latitude, specifier: "%.5f"), \(center.longitude, specifier: "%.5f") · radius \(Int(place.radius)) m")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        if let history = backup.history {
                            Toggle("Restore listening history · \(history.count) daily totals · \(backup.historySessions?.count ?? 0) sessions", isOn: $workflow.restoreHistory)
                            if workflow.restoreHistory {
                                Text("Merge sessions by their saved IDs and count overlapping intervals once. Keep the larger saved daily total or recorded session coverage. Dates and recorded time zones are preserved. Keep up to one year and the latest 12,000 sessions. Both recording preferences stay unchanged.")
                                    .font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("Saved daily totals") {
                                    LazyVStack(alignment: .leading, spacing: 4) {
                                        ForEach(history) { row in
                                            Text("\(row.date) · \(row.model) · \(Int(row.seconds / 60)) min")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if let sessions = backup.historySessions, !sessions.isEmpty {
                                    DisclosureGroup("Saved sessions") {
                                        LazyVStack(alignment: .leading, spacing: 4) {
                                            ForEach(sessions.prefix(100)) { session in
                                                Text("\(session.day) · \(session.model) · \(Int(session.seconds)) sec · \(session.timeZoneIdentifier)")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            if sessions.count > 100 { Text("\(sessions.count - 100) more sessions in this backup.").font(.caption) }
                                        }
                                    }
                                }
                            }
                        }
                        if let content = backup.listeningContent {
                            Toggle("Restore song history · \(content.count) intervals", isOn: $workflow.restoreContent)
                            if workflow.restoreContent {
                                Text("Merge matching record IDs, preserving titles, sources and recorded time zones. Keep up to one year or the latest 5,000 records. Song recording stays unchanged; this does not add to daily totals.")
                                    .font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("Saved songs") {
                                    LazyVStack(alignment: .leading, spacing: 4) {
                                        ForEach(content.prefix(100)) { record in
                                            Text("\(record.interval.day) · \(record.content.metadata.title ?? "") · \(record.content.metadata.artist ?? "") · \(Int(record.interval.seconds)) sec")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        if content.count > 100 { Text("\(content.count - 100) more intervals in this backup.").font(.caption) }
                                    }
                                }
                            }
                        }
                    }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                }.frame(minHeight: 120, maxHeight: 260)
                if let plan = workflow.plan, plan.sceneSelection == workflow.restoreScenes, plan.historySelection == workflow.restoreHistory, plan.contentSelection == workflow.restoreContent {
                    Text("Review — scenes added: \(plan.addedScenes); replaced: \(plan.replacedScenes)\(plan.history.map { "; daily totals after merging: \($0.count)" } ?? "")\(plan.sessions.map { "; sessions: \($0.count)" } ?? "")\(plan.content.map { "; song intervals: \($0.count)" } ?? ""). Original files will be kept in a recovery folder.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Review Restore") { workflow.review() }
                    Spacer()
                    Button("Restore Selected App Data") { workflow.restore() }
                        .buttonStyle(.borderedProminent).disabled(!workflow.canRestore)
                }
                if controller.isReplay {
                    Text("Restoring app data is disabled in replay mode.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = workflow.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            if let error = workflow.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let recovery = workflow.recoveryDirectory {
                Button("Show Original Files") { NSWorkspace.shared.open(recovery) }
            }
        }.padding(24).frame(width: 620)
    }
}
