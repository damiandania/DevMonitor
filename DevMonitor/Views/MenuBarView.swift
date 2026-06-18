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

    /// Lists every online server: each supervised session (with Stop/Restart) and each dev server
    /// running OUTSIDE the app (purple, display-only). Falls back to a Launch button for the
    /// selected project when nothing is running for it.
    @ViewBuilder private var serversSection: some View {
        let managed = app.sessions.values
            .filter { $0.state.isActive }
            .sorted { $0.project.name < $1.project.name }
        let external = app.systemSampler.processes.filter { $0.isExternalDev }
        let builds = app.builds.values
            .filter { $0.isRunning || $0.result != nil }
            .sorted { $0.project.name < $1.project.name }

        TimelineView(.periodic(from: Date(), by: 1)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                if managed.isEmpty && external.isEmpty && builds.isEmpty {
                    Text("No servers running").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(managed, id: \.project.id) { managedRow($0) }
                    ForEach(builds, id: \.project.id) { buildRow($0) }
                    ForEach(external) { externalRow($0) }
                }
                if let p = app.selectedProject, app.sessions[p.id]?.state.isActive != true {
                    Button { app.launch(p) } label: {
                        Label("Launch \(p.name)", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
    }

    private func managedRow(_ s: DevSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Label(s.state.label, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(s.state.tint)
                if let started = s.startedAt, s.state.isActive {
                    Text("up \(Self.uptime(since: started))"
                        + (s.recycleCount > 0 ? " · \(s.recycleCount) recycles" : ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Button { app.stop(s.project) } label: { Image(systemName: "stop.fill") }.help("Stop")
                Button { s.recycle() } label: { Image(systemName: "arrow.clockwise") }.help("Restart")
            }
            .buttonStyle(.borderless).controlSize(.small)
        }
    }

    private func buildRow(_ b: BuildRunner) -> some View {
        let label = b.isRunning ? "Building…" : (b.result == 0 ? "Built" : "Build failed")
        let tint: Color = b.isRunning ? .orange : (b.result == 0 ? .green : .red)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "hammer.fill").font(.caption2).foregroundStyle(.secondary)
                    Text(b.project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Label(label, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(tint)
            }
            Spacer()
            if b.isRunning {
                Button { b.stop() } label: { Image(systemName: "stop.fill") }.help("Stop build")
                    .buttonStyle(.borderless).controlSize(.small)
            }
        }
    }

    private func externalRow(_ row: ProcessRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack").font(.caption).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.subheadline.weight(.semibold)).foregroundStyle(.purple).lineLimit(1)
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
