import SwiftUI
import AppKit

/// Compact panel shown from the menu-bar icon: active server status, quick
/// controls, and a live system snapshot — without opening the main window.
struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    private var session: DevSession? { app.activeSession }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Dev Monitor", systemImage: "waveform.path.ecg")
                .font(.headline)

            Divider()
            sessionSection
            controls

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

    @ViewBuilder private var sessionSection: some View {
        if let session {
            TimelineView(.periodic(from: Date(), by: 1)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.project.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Label(session.state.label, systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(session.state.tint)
                    if let started = session.startedAt, session.state.isActive {
                        Text("up \(Self.uptime(since: started))"
                            + (session.recycleCount > 0 ? " · \(session.recycleCount) recycles" : ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text(app.selectedProject.map { "\($0.name) — idle" } ?? "No project selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            if let session, session.state.isActive {
                Button("Stop", systemImage: "stop.fill") { app.stopActive() }
                Button("Restart", systemImage: "arrow.clockwise") { session.recycle() }
            } else if let project = app.selectedProject {
                Button("Launch", systemImage: "play.fill") { app.launch(project) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.callout)
        .controlSize(.small)
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
