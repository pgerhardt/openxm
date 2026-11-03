import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class AppDataBackupWorkflow {
    var isPresented = false
    var exportScenes = true
    var exportHistory = true
    var exportContent = false
    var restoreScenes = true
    var restoreHistory = true
    var restoreContent = false
    private(set) var backup: AppDataBackup?
    private(set) var message: String?
    private(set) var error: String?
    private(set) var recoveryDirectory: URL?
    private(set) var plan: Plan?
    private unowned let controller: HeadphoneController
    private unowned let scenes: SceneStore
    private let history: ListeningHistory
    private let contentHistory: ListeningContentHistory

    struct Plan {
        var sceneSelection: Bool
        var historySelection: Bool
        var contentSelection: Bool
        var originalScenes: [SoundScene]?
        var originalHistory: [ListeningDay]?
        var originalSessions: [ListeningSession]?
        var originalContent: [ListeningContentRecord]?
        var recordingEnabled: Bool
        var sessionRecordingEnabled: Bool
        var contentRecordingEnabled: Bool
        var scenes: [SoundScene]?
        var history: [ListeningDay]?
        var sessions: [ListeningSession]?
        var content: [ListeningContentRecord]?
        var changes: [AppDataFileChange]
        var addedScenes: Int
        var replacedScenes: Int
    }

    init(controller: HeadphoneController, scenes: SceneStore, history: ListeningHistory? = nil, contentHistory: ListeningContentHistory? = nil) {
        self.controller = controller; self.scenes = scenes
        self.history = history ?? controller.listeningHistory
        self.contentHistory = contentHistory ?? controller.listeningContentHistory
    }

    var canRestore: Bool {
        guard let plan, !controller.isReplay, scenes.runningSceneID == nil else { return false }
        return plan.sceneSelection == restoreScenes && plan.historySelection == restoreHistory && plan.contentSelection == restoreContent && !plan.changes.isEmpty
    }

    func capture(now: Date = Date()) throws -> AppDataBackup {
        if exportScenes { _ = try scenes.checkedBackupFile() }
        if exportHistory { _ = try history.checkedBackupFile() }
        if exportContent { _ = try contentHistory.checkedBackupFile() }
        let value = AppDataBackup(createdAt: now,
                                  scenes: exportScenes ? AppDataBackup.portableScenes(scenes.scenes) : nil,
                                  history: exportHistory ? history.days.map { AppDataHistoryDay($0, calendar: history.storageCalendar) } : nil,
                                  historySessions: exportHistory ? history.sessions : nil,
                                  listeningContent: exportContent ? contentHistory.records : nil)
        try value.validate()
        return value
    }

    func saveBackup() {
        do {
            let value = try capture()
            let data = try value.encoded()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "OpenXM-app-data.json"
            panel.message = "This file may contain saved place coordinates, listening times, song titles, artists, albums and source apps."
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    do {
                        try data.write(to: url, options: .atomic)
                        self?.message = "Saved \(url.lastPathComponent)."; self?.error = nil
                    } catch { self?.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func openBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose an OpenXM app-data backup to review."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.load(url) }
        }
    }

    func load(_ url: URL) {
        backup = nil; plan = nil; message = nil; error = nil; recoveryDirectory = nil
        do {
            guard let data = try AppDataFileChange.read(url) else { throw CocoaError(.fileNoSuchFile) }
            let value = try AppDataBackup.decode(data)
            backup = value
            restoreScenes = value.scenes != nil; restoreHistory = value.history != nil
            restoreContent = value.listeningContent != nil
            message = "Opened \(url.lastPathComponent). Review the selected data before restoring."
        } catch { self.error = error.localizedDescription }
    }

    func review(now: Date = Date()) {
        plan = nil; error = nil; message = nil
        guard let backup else { return }
        do {
            try backup.validate()
            var value = Plan(sceneSelection: restoreScenes, historySelection: restoreHistory, contentSelection: restoreContent,
                             recordingEnabled: history.enabled, sessionRecordingEnabled: history.sessionsEnabled,
                             contentRecordingEnabled: contentHistory.enabled,
                             changes: [], addedScenes: 0, replacedScenes: 0)
            if restoreScenes, let imported = backup.scenes {
                let original = try scenes.checkedBackupFile()
                value.originalScenes = scenes.scenes
                let merged = AppDataBackup.mergedScenes(imported, into: scenes.scenes)
                try AppDataBackup(createdAt: now, scenes: merged).validate()
                value.scenes = merged
                value.replacedScenes = imported.filter { item in scenes.scenes.contains { $0.id == item.id } }.count
                value.addedScenes = imported.count - value.replacedScenes
                value.changes.append(.init(url: scenes.storageLocation, original: original, replacement: try scenes.encodedRestoration(merged)))
            }
            if restoreHistory, let imported = backup.history {
                let original = try history.checkedBackupFile()
                value.originalHistory = history.days
                value.originalSessions = history.sessions
                let sessions = try ListeningSession.merge(backup.historySessions ?? [], into: history.sessions,
                                                           calendar: history.storageCalendar, now: now)
                let merged = try AppDataHistoryDay.merge(imported + ListeningSession.dailyCoverage(sessions),
                                                        into: history.days, calendar: history.storageCalendar, now: now)
                try AppDataBackup(createdAt: now, history: merged.map { AppDataHistoryDay($0, calendar: history.storageCalendar) },
                                  historySessions: sessions).validate()
                value.history = merged
                value.sessions = sessions
                value.changes.append(.init(url: history.storageLocation, original: original,
                                          replacement: try history.encodedRestoration(merged, sessions: sessions)))
            }
            if restoreContent, let imported = backup.listeningContent {
                let original = try contentHistory.checkedBackupFile()
                value.originalContent = contentHistory.records
                let merged = try ListeningContentRecord.merge(imported, into: contentHistory.records, calendar: contentHistory.storageCalendar, now: now)
                value.content = merged
                value.changes.append(.init(url: contentHistory.storageLocation, original: original,
                                          replacement: try contentHistory.encodedRestoration(merged)))
            }
            guard !value.changes.isEmpty else { throw AppDataBackupError.invalid("Select scenes, listening history or song history to restore.") }
            plan = value
        } catch { self.error = error.localizedDescription }
    }

    func restore(write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        guard canRestore, let plan else { return }
        error = nil; message = nil
        do {
            guard plan.originalScenes.map({ $0 == scenes.scenes }) ?? true,
                  plan.originalHistory.map({ $0 == history.days && plan.recordingEnabled == history.enabled &&
                      plan.originalSessions == history.sessions && plan.sessionRecordingEnabled == history.sessionsEnabled }) ?? true,
                  plan.originalContent.map({ $0 == contentHistory.records && plan.contentRecordingEnabled == contentHistory.enabled }) ?? true else {
                throw AppDataBackupError.invalid("App data changed after review. Review the backup again.")
            }
            let directory = scenes.storageLocation.deletingLastPathComponent()
                .appendingPathComponent("App Data Recovery/\(UUID().uuidString)", isDirectory: true)
            try AppDataFileRestore.apply(plan.changes, recoveryDirectory: directory, write: write)
            if let value = plan.scenes { scenes.acceptRestoration(value) }
            if let value = plan.history { history.acceptRestoration(value, sessions: plan.sessions) }
            if let value = plan.content { contentHistory.acceptRestoration(value) }
            recoveryDirectory = directory
            self.plan = nil
            message = "Restored selected app data. Imported automatic triggers are disabled; your recording preference is unchanged. Original files are in the recovery folder."
        } catch {
            self.plan = nil
            self.error = error.localizedDescription
        }
    }
}
