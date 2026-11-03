import SwiftUI

struct ListeningContentCard: View {
    @Bindable var history: ListeningContentHistory
    var readOnly = false
    @State private var showLog = false
    @State private var confirmClear = false

    var body: some View {
        Card("Song History", symbol: "music.note.list") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Keep song history on this Mac", isOn: Binding(get: { history.enabled }, set: { history.setEnabled($0) }))
                    .toggleStyle(AccentToggleStyle()).disabled(readOnly)
                Text("Saves available titles, artists, albums, source apps and estimated listening intervals. Separate from daily totals and session times. Keeps up to one year or the latest 5,000 records on this Mac.")
                    .font(.caption11).foregroundStyle(Theme.secondary)
                Text("Uses fresh headphone metadata, or Mac player metadata when that player’s audio output matches these headphones. Missing titles or an unknown route leave gaps. Other-device playback requires headphone metadata.")
                    .font(.caption11).foregroundStyle(Theme.secondary)
                if let error = history.saveError { Text(error).font(.caption11).foregroundStyle(Theme.warning) }
                if history.enabled {
                    Text(history.recordingStatus.message).font(.caption11).foregroundStyle(Theme.secondary)
                }
                HStack {
                    Text("\(history.records.count) saved intervals").font(.label)
                    if history.activeRecordID != nil { Text("Recording").font(.caption11).foregroundStyle(Theme.accent) }
                    Spacer()
                    Button("Browse Songs…") { showLog = true }
                    Button(history.saveError != nil ? "Reset Song History…" : "Clear Song History…", role: .destructive) { confirmClear = true }
                        .disabled(readOnly || (history.records.isEmpty && history.saveError == nil))
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showLog) { ListeningContentLogView(history: history) }
        .confirmationDialog("Clear song titles and listening intervals on this Mac? Daily totals, session times and recording preferences will stay.", isPresented: $confirmClear) {
            Button("Clear Song History", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct ListeningContentLogView: View {
    @Bindable var history: ListeningContentHistory
    @Environment(\.dismiss) private var dismiss
    @State private var days = 7
    @State private var model = ""
    @State private var source = ""
    @State private var search = ""
    @State private var visibleCount = 60

    private var models: [String] { Array(Set(history.records.map { $0.interval.model })).sorted() }
    private var rows: [ListeningContentRecord] {
        let calendar = history.storageCalendar
        let start = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: Date()))!
        let first = AppDataHistoryDay(.init(day: start, model: "", seconds: 0), calendar: calendar).date
        let last = AppDataHistoryDay(.init(day: Date(), model: "", seconds: 0), calendar: calendar).date
        return history.records.filter { row in
            row.interval.day >= first && row.interval.day <= last && (model.isEmpty || row.interval.model == model) &&
            (source.isEmpty || row.content.source.rawValue == source) && (search.isEmpty ||
                [row.content.metadata.title, row.content.metadata.artist, row.content.metadata.album].compactMap { $0 }
                    .contains { $0.localizedStandardContains(search) })
        }
    }
    private var filterID: String { "\(days)|\(model)|\(source)|\(search)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Song History").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            HStack {
                Picker("Period", selection: $days) { Text("Last 7 days").tag(7); Text("Last 30 days").tag(30); Text("Last year").tag(365) }
                Picker("Model", selection: $model) { Text("All models").tag(""); ForEach(models, id: \.self) { Text($0).tag($0) } }
                Picker("Source", selection: $source) { Text("All sources").tag(""); Text("Headphones").tag("headphones"); Text("Mac apps").tag("macApp") }
            }.labelsHidden()
            TextField("Search titles, artists or albums", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search song history")
            Text("\(rows.count) listening intervals").font(.callout).foregroundStyle(.secondary)
            if rows.isEmpty {
                ContentUnavailableView("No songs in this period", systemImage: "music.note",
                    description: Text(!history.records.isEmpty ? "Try another period, model, source or search."
                        : history.enabled ? "Records appear when playback and its metadata source can be verified."
                        : "Enable song history in Activity to start recording."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(rows.prefix(visibleCount)) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top) {
                                    Text(row.content.metadata.title ?? "").font(.headline).textSelection(.enabled)
                                    Spacer()
                                    Text(listeningDuration(row.interval.seconds)).monospacedDigit()
                                }
                                if let artist = row.content.metadata.artist { Text(artist).textSelection(.enabled) }
                                if let album = row.content.metadata.album { Text(album).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                                Text("\(row.interval.day) · \(time(row.interval.startedAt, row.interval)) – \(time(row.interval.endedAt, row.interval))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(row.interval.model) · \(row.content.source == .headphones ? "Headphone metadata" : "Mac app: " + (row.content.appBundleIdentifier ?? ""))\(history.activeRecordID == row.id ? " · Recording" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                            Divider()
                        }
                        if rows.count > visibleCount { Button("Show More") { visibleCount += 60 } }
                    }.padding(.trailing, 8)
                }.id(filterID)
            }
            Text("Times use the recorded time zone. Intervals are estimates sampled while OpenXM is connected, not full track lengths or play counts. Unknown metadata and routes leave gaps. Turning recording off keeps saved songs.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 740, height: 650)
            .onChange(of: filterID) { visibleCount = 60 }
            .onChange(of: models) { if !model.isEmpty && !models.contains(model) { model = "" } }
    }

    private func time(_ date: Date, _ interval: ListeningSession) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: interval.timeZoneIdentifier)
        formatter.dateFormat = "HH:mm:ss z"
        return formatter.string(from: date)
    }
}
