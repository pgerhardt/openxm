import SwiftUI
import Charts

struct ListeningHistoryCard: View {
    @Bindable var history: ListeningHistory
    var readOnly = false
    @State private var confirmClear = false
    @State private var showLog = false

    var body: some View {
        Card("Listening History", symbol: "clock") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Keep listening history on this Mac", isOn: Binding(
                    get: { history.enabled }, set: { history.setEnabled($0) }
                )).toggleStyle(AccentToggleStyle()).disabled(readOnly)
                Text("Estimates listening time from headphone playback reports while OpenXM is connected. Daily totals and model names stay on this Mac for up to one year.")
                    .font(.caption11).foregroundStyle(Theme.secondary)
                Toggle("Also keep session times", isOn: Binding(
                    get: { history.sessionsEnabled }, set: { history.setSessionsEnabled($0) }
                )).toggleStyle(AccentToggleStyle()).disabled(readOnly || !history.enabled)
                Text("Saves when each listening interval started and ended. Pauses and connection gaps end a session. Keeps up to one year or the latest 12,000 sessions; no song names, locations or cloud sync.")
                    .font(.caption11).foregroundStyle(Theme.secondary)
                if let error = history.saveError {
                    Text(error).font(.caption11).foregroundStyle(Theme.warning)
                }
                HStack {
                    Text("Today: \(listeningDuration(history.total(on: Date())))")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Browse History…") { showLog = true }
                    Button(history.saveError != nil && history.days.isEmpty ? "Reset History…" : "Clear History…",
                           role: .destructive) { confirmClear = true }
                        .disabled(readOnly || (history.days.isEmpty && history.sessions.isEmpty && history.saveError == nil))
                }
                if history.days.isEmpty && history.enabled {
                    Text("Listening time will appear after playback is reported.").font(.caption11).foregroundStyle(Theme.secondary)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showLog) { ListeningLogView(history: history, readOnly: readOnly) }
        .confirmationDialog("Clear all daily totals and session times stored on this Mac?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct ListeningLogView: View {
    @Bindable var history: ListeningHistory
    var readOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var period = HistoryPeriod.week
    @State private var model = ""
    @State private var showSessions = true
    @State private var visibleCount = 60
    @State private var confirmClearSessions = false

    private enum HistoryPeriod: String, CaseIterable, Identifiable {
        case week = "Last 7 days", month = "Last 30 days", year = "Last year"
        var id: String { rawValue }
        var days: Int { switch self { case .week: 7; case .month: 30; case .year: 365 } }
    }
    private var models: [String] { Array(Set(history.days.map(\.model) + history.sessions.map(\.model))).sorted() }
    private var start: Date {
        history.storageCalendar.date(byAdding: .day, value: 1 - period.days,
                                     to: history.storageCalendar.startOfDay(for: Date()))!
    }
    private var firstDay: String {
        AppDataHistoryDay(.init(day: start, model: "", seconds: 0), calendar: history.storageCalendar).date
    }
    private var lastDay: String {
        AppDataHistoryDay(.init(day: Date(), model: "", seconds: 0), calendar: history.storageCalendar).date
    }
    private var days: [ListeningDay] {
        history.days.filter { $0.day >= start && $0.day <= Date() && (model.isEmpty || $0.model == model) }
    }
    private var sessions: [ListeningSession] {
        history.sessions.filter { $0.day >= firstDay && $0.day <= lastDay && (model.isEmpty || $0.model == model) }
    }
    private var chartPoints: [ListeningDay] {
        let calendar = history.storageCalendar
        let unit: Calendar.Component = period == .year ? .month : .day
        let grouped = Dictionary(grouping: days) { calendar.dateInterval(of: unit, for: $0.day)!.start }
        var cursor = calendar.dateInterval(of: unit, for: start)!.start
        var result: [ListeningDay] = []
        while cursor <= Date() {
            result.append(.init(day: cursor, model: "All", seconds: grouped[cursor, default: []].reduce(0) { $0 + $1.seconds }))
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Listening History").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("Period", selection: $period) {
                    ForEach(HistoryPeriod.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 150)
                Picker("Headphone model", selection: $model) {
                    Text("All models").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 210)
                Spacer()
                Text(listeningDuration(days.reduce(0) { $0 + $1.seconds })).font(.title3.bold()).monospacedDigit()
            }
            Chart(chartPoints) { point in
                BarMark(x: .value("Date", point.day, unit: period == .year ? .month : .day),
                        y: .value("Listening minutes", point.seconds / 60))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel(point.day.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue(listeningDuration(point.seconds))
            }
            .chartYAxisLabel("Minutes")
            .frame(height: 150)
            Picker("History view", selection: $showSessions) {
                Text("Sessions (\(sessions.count))").tag(true)
                Text("Daily totals").tag(false)
            }.pickerStyle(.segmented)
            ScrollView {
                if showSessions { sessionList }
                else { dayList }
            }.id("\(period.rawValue)|\(model)|\(showSessions)")
                .frame(maxWidth: .infinity, minHeight: 170, maxHeight: .infinity, alignment: .topLeading)
            if showSessions {
                HStack(alignment: .top) {
                    Text("Times use the time zone recorded with each session. Earlier daily totals have no session details. Turning recording off keeps saved history.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Session Times…", role: .destructive) { confirmClearSessions = true }
                        .disabled(readOnly || history.sessions.isEmpty)
                }
            } else {
                Text("Daily estimates can include time recorded before session logging was enabled. Imported overlapping sessions are counted once; saved daily estimates are never added together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24).frame(width: 700, height: 650)
        .onChange(of: period) { visibleCount = 60 }
        .onChange(of: model) { visibleCount = 60 }
        .onChange(of: models) { if !model.isEmpty && !models.contains(model) { model = "" } }
        .confirmationDialog("Clear saved session times? Daily totals and recording preferences will stay.",
                            isPresented: $confirmClearSessions) {
            Button("Clear Session Times", role: .destructive) { history.clearSessions() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var sessionList: some View {
        if sessions.isEmpty {
            ContentUnavailableView("No sessions in this period", systemImage: "clock",
                description: Text(history.enabled && history.sessionsEnabled
                    ? "Sessions appear after the headphones report playback."
                    : "Enable listening history and session times in Activity to start recording."))
        } else {
            let groups = Dictionary(grouping: Array(sessions.prefix(visibleCount)), by: \.day)
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                    Text(day).font(.headline).padding(.top, 4)
                    ForEach(groups[day, default: []]) { session in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(sessionTime(session.startedAt, session)) – \(sessionTime(session.endedAt, session))")
                                    .monospacedDigit()
                                Text(session.model).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(listeningDuration(session.seconds)).monospacedDigit()
                                if history.activeSessionID == session.id {
                                    Text("Recording").font(.caption).foregroundStyle(Theme.accent)
                                }
                            }
                        }.padding(.vertical, 3).accessibilityElement(children: .combine)
                    }
                }
                if visibleCount < sessions.count { Button("Show more sessions") { visibleCount += 60 } }
            }.padding(.trailing, 8)
        }
    }

    @ViewBuilder private var dayList: some View {
        if days.isEmpty {
            ContentUnavailableView("No listening time in this period", systemImage: "chart.bar",
                                   description: Text("Only time observed while OpenXM is connected is estimated."))
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(days) { day in
                    HStack {
                        Text(day.day.formatted(date: .abbreviated, time: .omitted))
                        Text(day.model).foregroundStyle(.secondary)
                        Spacer()
                        Text(listeningDuration(day.seconds)).monospacedDigit()
                    }.accessibilityElement(children: .combine)
                }
            }.padding(.trailing, 8)
        }
    }

    private func sessionTime(_ date: Date, _ session: ListeningSession) -> String {
        let zone = TimeZone(identifier: session.timeZoneIdentifier) ?? .gmt
        var style = Date.FormatStyle(date: .omitted, time: .standard)
        style.timeZone = zone
        return date.formatted(style) + " " + (zone.abbreviation(for: date) ?? zone.identifier)
    }
}

func listeningDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes == 0 { return "\(Int(seconds)) sec" }
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr \(minutes % 60) min"
}
