import SwiftUI

/// A persisted timeline of supervision / pressure events (crashes, recycles, builds, OOM retries,
/// pressure) that survives app restarts — read from `EventStore`'s JSONL. Grouped by day, newest
/// first. Complements the sidebar "Recent" feed, which only keeps the last few in memory.
struct HistoryView: View {
    @Environment(AppState.self) private var app
    @State private var events: [PersistedEvent] = []

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
        }
        .onAppear(perform: reload)
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
