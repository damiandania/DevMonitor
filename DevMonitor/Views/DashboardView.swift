import SwiftUI
import AppKit

/// Per-project dashboard: status, launch controls and live log (P1).
/// Charts (P2), health controls (P3) and build runner (P5) extend this.
struct DashboardView: View {
    @Environment(AppState.self) private var app
    let project: Project
    @State private var percentOfMachine = false
    @State private var logTab = 0   // 0 = server, 1 = build

    private var session: DevSession? { app.session(for: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controlBar
            Divider()
            logArea
        }
        // Surface the build terminal automatically when a build starts.
        .onChange(of: app.build(for: project)?.isRunning) { _, running in
            if running == true { logTab = 1 }
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
        return Label(statusText, systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }

    /// Status text including the package manager when the server is up, e.g. "Running · npm · :3000".
    private var statusText: String {
        let state = session?.state ?? .idle
        if case .running(let port) = state {
            let pm = project.packageManager.rawValue
            return port.map { "Running · \(pm) · :\($0)" } ?? "Running · \(pm)"
        }
        return state.label
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
                .help("Open http://localhost:\(port) in \(app.settings.browser ?? "your default browser")")
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
        // Use the browser chosen in App Settings, else the system default.
        if let browser = app.settings.browser, !browser.isEmpty {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", browser, url.absoluteString]
            do { try task.run() } catch { NSWorkspace.shared.open(url) }
        } else {
            NSWorkspace.shared.open(url)
        }
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
            if let build = app.build(for: project), build.isRunning {
                // While building, the Build button becomes a red Stop that kills the build.
                PillButton(title: "Stop build", systemImage: "stop.fill", prominent: true) {
                    build.stop()
                }
                .tint(.red)
            } else {
                if let r = app.build(for: project)?.result {
                    Button { logTab = 1 } label: {
                        Label(r == 0 ? "Built" : "Build failed",
                              systemImage: r == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r == 0 ? .green : .red)
                    }
                    .buttonStyle(.plain)
                    .help("Show the build log")
                }
                PillButton(title: "Build", systemImage: "hammer.fill", prominent: true) {
                    app.runBuild(project)
                }
            }
        }
    }

    @ViewBuilder private var logArea: some View {
        let build = app.build(for: project)
        let buildShown = (build?.isRunning ?? false) || (build?.result != nil)
        if session != nil || buildShown {
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

            terminals(build: buildShown ? build : nil)
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

    /// Server and/or build terminals, with pill tabs (each closable via an ✕).
    @ViewBuilder private func terminals(build: BuildRunner?) -> some View {
        let hasServer = session != nil
        let hasBuild = build != nil
        // Selected tab, falling back to whichever terminal exists.
        let tab = (hasServer && hasBuild) ? logTab : (hasBuild ? 1 : 0)
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if hasServer {
                    terminalTab(title: "Server", tag: 0, selected: tab == 0) { app.closeServer() }
                }
                if hasBuild {
                    terminalTab(title: "Build", tag: 1, selected: tab == 1) { app.closeBuild() }
                }
                Spacer()
            }

            if tab == 1, let build {
                LogPaneView(lines: build.logLines)
            } else if let session {
                serverLog(session)
            } else if let build {
                LogPaneView(lines: build.logLines)
            }
        }
    }

    /// A pill tab (like the preset buttons) with an ✕ that closes the terminal and its tab.
    private func terminalTab(title: String, tag: Int, selected: Bool,
                             close: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .contentShape(Rectangle())
                .onTapGesture { logTab = tag }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.7)
            }
            .buttonStyle(.plain)
            .help("Close the \(title.lowercased()) terminal")
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? AnyShapeStyle(Color.accentColor)
                             : AnyShapeStyle(Color(.quaternaryLabelColor)),
                    in: Capsule())
    }

    private func serverLog(_ session: DevSession) -> some View {
        LogPaneView(lines: session.logLines,
                    inputPlaceholder: "Send input to the dev server (press Enter)…",
                    onSubmit: { session.sendInput($0) })
    }
}
