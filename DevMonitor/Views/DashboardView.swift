import SwiftUI
import AppKit

/// Per-project dashboard: status, launch controls and live log (P1).
/// Charts (P2), health controls (P3) and build runner (P5) extend this.
struct DashboardView: View {
    @Environment(AppState.self) private var app
    let project: Project
    @State private var showBuildLog = false
    @State private var percentOfMachine = false

    private var session: DevSession? { app.session(for: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controlBar
            Divider()
            logArea
        }
        .sheet(isPresented: $showBuildLog) {
            if let build = app.build(for: project) {
                BuildLogSheet(build: build)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProjectIconView(project: project, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(project.name).font(.title2.bold())
                    if let branch = GitInfo.branch(for: project.path) {
                        HStack(spacing: 4) {
                            Image("github")
                                .resizable()
                                .renderingMode(.template)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 11, height: 11)
                            Text(branch)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    }
                }
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
        return HStack(spacing: 12) {
            PillButton(title: running ? "Stop" : "Launch",
                       systemImage: running ? "stop.fill" : "play.fill") {
                if running { app.stopActive() } else { app.launch(project) }
            }
            .keyboardShortcut(running ? "." : "r", modifiers: .command)

            if running {
                PillButton(title: "Restart", systemImage: "arrow.clockwise") {
                    session?.recycle()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            if let port = session?.effectivePort {
                PillButton(title: "Open", systemImage: "globe") {
                    openInBrowser(port: port)
                }
                .help("Open http://localhost:\(port) in Chrome")
            }

            PillButton(title: "Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                openInVSCode()
            }
            .help("Open the project in VS Code")

            Spacer()
            buildControls
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func openInBrowser(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)/") else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Google Chrome", url.absoluteString]
        do { try task.run() } catch { NSWorkspace.shared.open(url) }
    }

    private func openInVSCode() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Visual Studio Code", project.path]
        do { try task.run() } catch { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
    }

    @ViewBuilder private var systemBars: some View {
        let sampler = app.systemSampler
        HStack(spacing: 22) {
            systemBar(title: "CPU", percent: sampler.systemCPU,
                      detail: "\(Int(sampler.systemCPU))%", color: .blue)
            systemBar(title: "Memory", percent: sampler.systemMemPercent,
                      detail: String(format: "%.1f / %.0f GB",
                                     sampler.systemMemUsed / 1_073_741_824,
                                     sampler.totalMem / 1_073_741_824),
                      color: .purple)
            systemBar(title: "Swap", percent: sampler.systemSwapPercent,
                      detail: sampler.systemSwapTotal > 0
                        ? String(format: "%.1f / %.0f GB",
                                 sampler.systemSwapUsed / 1_073_741_824,
                                 sampler.systemSwapTotal / 1_073_741_824)
                        : "off",
                      color: .orange)
        }
    }

    private func systemBar(title: String, percent: Double, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(detail).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(color)
            }
            ProgressView(value: min(max(percent / 100, 0), 1)).tint(color)
        }
    }

    @ViewBuilder private var buildControls: some View {
        if project.buildCommand != nil {
            if let build = app.build(for: project), build.isRunning || build.result != nil {
                Button { showBuildLog = true } label: {
                    if build.isRunning {
                        Label("Building…", systemImage: "hammer.fill").foregroundStyle(.orange)
                    } else if let r = build.result {
                        Label(r == 0 ? "Built" : "Build failed", systemImage: "hammer.fill")
                            .foregroundStyle(r == 0 ? .green : .red)
                    }
                }
                .buttonStyle(.plain)
            }
            PillButton(title: "Build", systemImage: "hammer.fill", prominent: true) {
                app.runBuild(project)
            }
            .disabled(app.build(for: project)?.isRunning ?? false)
        }
    }

    @ViewBuilder private var logArea: some View {
        if let session {
            HStack {
                Label("Activity", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                Toggle("% of machine", isOn: $percentOfMachine)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            systemBars
                .padding(.horizontal)
                .padding(.bottom, 8)

            ProcessTableView(sampler: app.systemSampler, percentOfMachine: $percentOfMachine)
                .frame(height: 220)

            Divider()

            LogPaneView(session: session)
                .frame(maxHeight: .infinity)
                .padding(8)
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
