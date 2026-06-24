import SwiftUI
import AppKit

/// Compact panel shown from the menu-bar icon: one collapsible section per added project (expand to
/// start/stop its dev / worker / build / preview controls), any external dev servers, and a live
/// system snapshot — without opening the main window.
struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    /// Per-project expand override; absent → defaults to expanded when the project has something live.
    @State private var expandedOverride: [Project.ID: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Dev Monitor", systemImage: "waveform.path.ecg")
                .font(.headline)

            Divider()
            serversSection

            Divider()
            systemSection

            Divider()
            HStack {
                Button("Open Window") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
    }

    /// One collapsible section per project (every added project, not just the running ones): the
    /// header shows the project's aggregate status; expanding reveals its run-controls (dev / worker /
    /// build / preview — straight from `AppState.runControls`) to start/stop. Dev servers running
    /// OUTSIDE the app are listed below, unsupervised.
    @ViewBuilder private var serversSection: some View {
        let external = app.systemSampler.processes.filter { $0.isExternalDev }

        TimelineView(.periodic(from: Date(), by: 1)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                if app.projects.isEmpty {
                    Text("No projects yet — add one in the window.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(app.projects.sorted { $0.name < $1.name }) { projectDisclosure($0) }
                }
                if !external.isEmpty {
                    Divider()
                    ForEach(external) { externalRow($0) }
                }
            }
        }
    }

    /// A collapsible project: header (chevron · status dot · name · aggregate state) and, when
    /// expanded, an indented run-control row per startable/running process.
    @ViewBuilder private func projectDisclosure(_ project: Project) -> some View {
        let controls = app.runControls(for: project)
        let live = controls.contains { $0.isLive }
        let isOpen = expandedOverride[project.id] ?? live
        let agg = aggregate(controls)

        VStack(alignment: .leading, spacing: 6) {
            Button {
                expandedOverride[project.id] = !isOpen
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                    StatusDot(color: agg.color, accessibilityLabel: agg.label)
                    Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(LocalizedStringKey(agg.label)).font(.caption.weight(.medium)).foregroundStyle(agg.color).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(controls) { controlRow($0) }
                }
                .padding(.leading, 17)   // align under the name, past the chevron
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isOpen)
    }

    /// Aggregate status across a project's controls: failed (red) ▸ starting (orange) ▸ running
    /// (green) ▸ idle (gray) — drives the collapsed header's dot + label.
    private func aggregate(_ controls: [RunControl]) -> (color: Color, label: String) {
        if controls.contains(where: { $0.status.error != nil }) { return (.red, "Failed") }
        if controls.contains(where: { $0.status.isInProgress }) { return (.orange, "Starting") }
        if controls.contains(where: { $0.status.showsStop })    { return (.green, "Running") }
        return (.secondary, "Idle")
    }

    /// One run-control inside an expanded project: icon · title · status · uptime · play/stop.
    private func controlRow(_ c: RunControl) -> some View {
        HStack(spacing: 6) {
            Image(systemName: c.icon).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
            Text(c.title).font(.subheadline).lineLimit(1)
            Text(LocalizedStringKey(c.status.label.isEmpty ? "Idle" : c.status.label))
                .font(.caption.weight(.medium)).foregroundStyle(c.status.color).lineLimit(1)
            if let started = c.startedAt, c.status.showsStop {
                Text("· \(Self.uptime(since: started))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            // Play to (re)launch, stop to halt — same icon style either way.
            Button(action: c.onToggle) {
                Image(systemName: c.status.showsStop ? "stop.fill" : "play.fill")
            }
            .help((c.status.showsStop ? "Stop " : "Start ") + c.title.lowercased())
            .buttonStyle(.borderless).controlSize(.small)
        }
    }

    private func externalRow(_ row: ProcessRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack").font(.caption).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.subheadline.weight(.semibold)).foregroundStyle(.indigo).lineLimit(1)
                Text("external · not supervised").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var systemSection: some View {
        let s = app.systemSampler
        return VStack(alignment: .leading, spacing: 6) {
            meter("CPU", value: s.systemCPU, text: String(format: "%.0f%%", s.systemCPU))
            meter("Memory", value: s.systemMemPercent, text: String(format: "%.0f%%", s.systemMemPercent))
        }
    }

    private func meter(_ title: String, value: Double, text: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 56, alignment: .leading)
            ProgressView(value: min(max(value, 0), 100), total: 100)
            Text(text).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }

    private static func uptime(since date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
