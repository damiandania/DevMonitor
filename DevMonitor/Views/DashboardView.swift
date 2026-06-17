import SwiftUI

/// Per-project dashboard: status, launch controls and live log (P1).
/// Charts (P2), health controls (P3) and build runner (P5) extend this.
struct DashboardView: View {
    @Environment(AppState.self) private var app
    let project: Project

    private var session: DevSession? { app.session(for: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controlBar
            Divider()
            logArea
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: project.framework.symbolName)
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.title2.bold())
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            statusPill
        }
        .padding()
    }

    private var statusPill: some View {
        let state = session?.state ?? .idle
        return Label(state.label, systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }

    private var controlBar: some View {
        let running = session?.state.isActive ?? false
        return HStack(spacing: 14) {
            Button {
                if running { app.stopActive() } else { app.launch(project) }
            } label: {
                Label(running ? "Stop" : "Launch",
                      systemImage: running ? "stop.fill" : "play.fill")
            }
            .controlSize(.large)
            .keyboardShortcut(running ? "." : "r", modifiers: .command)

            Divider().frame(height: 20)

            HStack(spacing: 6) {
                Image(systemName: "memorychip").foregroundStyle(.secondary)
                Stepper("\(project.memoryGB) GB",
                        value: Binding(get: { project.memoryGB },
                                       set: { app.setMemoryGB($0, for: project.id) }),
                        in: 1...32)
                    .fixedSize()
                    .disabled(running)
            }

            Label(project.packageManager.rawValue, systemImage: "shippingbox")
                .foregroundStyle(.secondary)
            if let port = session?.effectivePort {
                Label(":\(port)", systemImage: "network").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var logArea: some View {
        if let session {
            MetricsGrid(session: session)
                .padding(10)
            Divider()
            LogPaneView(session: session)
        } else {
            ContentUnavailableView(
                "Not Running",
                systemImage: "play.circle",
                description: Text("Press Launch (⌘R) to start the dev server and stream its logs.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
