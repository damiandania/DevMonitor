import SwiftUI

/// A persisted timeline of supervision / pressure events (crashes, recycles, builds, OOM retries,
/// pressure) that survives app restarts — read from `EventStore`'s JSONL. Grouped by day, newest
/// first. Complements the sidebar "Recent" feed, which only keeps the last few in memory.
struct HistoryView: View {
    @Environment(AppState.self) private var app
    @State private var events: [PersistedEvent] = []
    /// Count + size of the on-disk server log files, for the "Clear logs" button label/confirm.
    @State private var logs: (count: Int, bytes: Int) = (0, 0)
    @State private var confirmingClear = false
    @State private var confirmingClearHistory = false
    /// Set after a clear so the freed amount is reported back to the user.
    @State private var clearedNote: String?

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView("No history yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Crashes, recycles, builds and pressure events will appear here."))
            } else {
                List {
                    ForEach(grouped, id: \.day) { group in
                        Section(group.title) {
                            ForEach(group.events) { row($0) }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 440)
        .navigationTitle("History")
        .toolbar {
            Button(action: reload) { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Reload the event history")
            // Clear the server LOG FILES (dev-server output on disk) — separate from the history.
            Button { confirmingClear = true } label: {
                Label("Clear logs", systemImage: "doc.badge.xmark")
            }
            .help(logs.count > 0 ? "Delete the \(logs.count) server log file(s) — \(byteText(logs.bytes))"
                                 : "No server logs to delete")
            .disabled(logs.count == 0)
            // Clear the event HISTORY shown here (what the trash button now does).
            Button(role: .destructive) { confirmingClearHistory = true } label: {
                Label("Clear history", systemImage: "trash")
            }
            .help(events.isEmpty ? "No history to clear" : "Delete all \(events.count) history event(s)")
            .disabled(events.isEmpty)
        }
        .confirmationDialog("Delete \(logs.count) server log file(s)?",
                            isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Delete \(byteText(logs.bytes)) of logs", role: .destructive, action: clearLogs)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the dev-server output logs under Application Support. Running servers keep "
                 + "logging to a fresh file. This does not touch the event history above.")
        }
        .confirmationDialog("Clear all history?",
                            isPresented: $confirmingClearHistory, titleVisibility: .visible) {
            Button("Clear \(events.count) event(s)", role: .destructive, action: clearHistory)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deletes the recorded crashes, recycles, builds and pressure events. "
                 + "This does not touch the server log files.")
        }
        .alert("Logs cleared", isPresented: .constant(clearedNote != nil)) {
            Button("OK") { clearedNote = nil }
        } message: {
            Text(clearedNote ?? "")
        }
        .onAppear { reload(); refreshLogs() }
    }

    /// Human byte size (e.g. "4.1 MB") for the button/confirm text.
    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func refreshLogs() { logs = Project.logsSummary() }

    private func clearLogs() {
        let result = Project.clearLogs()
        clearedNote = "Freed \(byteText(result.bytes)) across \(result.removed) file(s)."
        refreshLogs()
    }

    private func row(_ e: PersistedEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.icon).foregroundStyle(e.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.title).fontWeight(.medium)
                    if let p = e.projectName { Text(p).foregroundStyle(.secondary).font(.caption) }
                }
                if !e.body.isEmpty {
                    Text(e.body).foregroundStyle(.secondary).font(.caption).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(e.date, format: .dateTime.hour().minute()).foregroundStyle(.secondary).font(.caption)
        }
        .padding(.vertical, 2)
    }

    private func reload() { events = app.eventStore.load() }

    /// Wipe the persisted history and empty the list immediately (so the rows disappear without a
    /// manual Refresh), plus the sidebar "Recent" feed so the two stay consistent.
    private func clearHistory() {
        app.eventStore.clear()
        app.recentNotifications = []
        events = []
    }

    /// Events grouped into day buckets, newest day first; within a day the newest-first order is kept.
    private var grouped: [(day: Date, title: String, events: [PersistedEvent])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: events) { cal.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            (day, day.formatted(date: .abbreviated, time: .omitted), byDay[day] ?? [])
        }
    }
}

/// Icon/tint for a persisted event — mirrors `NotificationItem`'s feed mapping so history and the
/// live feed read the same.
extension PersistedEvent {
    var icon: String {
        switch category {
        case .failures: return urgent ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        case .recovery: return "arrow.clockwise.circle.fill"
        case .builds:   return "hammer.fill"
        case .pressure: return "gauge.with.dots.needle.67percent"
        }
    }

    var tint: Color {
        if urgent { return category == .pressure ? .orange : .red }
        switch category {
        case .recovery: return .green
        case .builds:   return .green
        case .pressure: return .yellow
        case .failures: return .orange
        }
    }
}
