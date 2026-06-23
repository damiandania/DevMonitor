import SwiftUI
import AppKit

/// Compact panel shown from the menu-bar icon: every online server (supervised + external),
/// quick controls, and a live system snapshot — without opening the main window.
struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

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

    /// Lists every live run-control across all projects (dev, worker, build, preview — straight from
    /// `AppState.runControls`, so a new process type shows up automatically) plus dev servers running
    /// OUTSIDE the app, with a Launch row for whatever the selected project can still start.
    @ViewBuilder private var serversSection: some View {
        let controls = app.projects
            .flatMap { app.runControls(for: $0) }
            .filter(\.isLive)
            .sorted { ($0.projectName, $0.rank) < ($1.projectName, $1.rank) }
        let external = app.systemSampler.processes.filter { $0.isExternalDev }

        TimelineView(.periodic(from: Date(), by: 1)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                if controls.isEmpty && external.isEmpty {
                    Text("Nothing running").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(controls) { controlRow($0) }
                    ForEach(external) { externalRow($0) }
                }
                launchButtons
            }
        }
    }

    /// Play buttons for whatever the selected project can still start (dev / worker / build / preview).
    @ViewBuilder private var launchButtons: some View {
        if let p = app.selectedProject {
            let startable = app.runControls(for: p).filter { !$0.isLive }
            if !startable.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launch \(p.name)").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(startable) { c in
                            Button(action: c.onToggle) { Label(c.title, systemImage: "play.fill") }
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
    }

    /// One live process on a single line: icon · "Project · Title" · status · uptime · stop button.
    private func controlRow(_ c: RunControl) -> some View {
        HStack(spacing: 6) {
            Image(systemName: c.icon).font(.caption2).foregroundStyle(.secondary)
            Text("\(c.projectName) · \(c.title)").font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(c.status.label.isEmpty ? "Idle" : c.status.label)
                .font(.caption.weight(.medium)).foregroundStyle(c.status.color).lineLimit(1)
            if let started = c.startedAt, c.status.showsStop {
                Text("· \(Self.uptime(since: started))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if c.status.showsStop {
                Button(action: c.onToggle) { Image(systemName: "stop.fill") }
                    .help("Stop \(c.title.lowercased())")
                    .buttonStyle(.borderless).controlSize(.small)
            }
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
