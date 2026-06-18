import SwiftUI
import AppKit

/// Per-project dashboard: status, launch controls and live log (P1). Charts (P2), health controls
/// (P3) and build runner (P5) extend this. Laid out as grouped "cards" like the Settings/Doctor
/// modals (window-tinted base + inset rounded surfaces).
struct DashboardView: View {
    @Environment(AppState.self) private var app
    let project: Project
    @State private var percentOfMachine = false
    @State private var logTab = 0   // 0 = server, 1 = build

    private var session: DevSession? { app.session(for: project) }

    var body: some View {
        let build = app.build(for: project)
        let buildShown = (build?.isRunning ?? false) || (build?.result != nil)
        let live = session != nil || buildShown

        VStack(spacing: 14) {
            headerCard
            if live {
                activityCard
                terminalCard(build: buildShown ? build : nil)
                    .frame(maxHeight: .infinity)
            } else {
                emptyCard
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        // Surface the build terminal automatically when a build starts.
        .onChange(of: app.build(for: project)?.isRunning) { _, running in
            if running == true { logTab = 1 }
        }
    }

    /// Inset rounded surface used for every section — the modal/System-Settings look.
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
    }

    // MARK: - Header + controls (one card)

    private var headerCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ProjectIconView(project: project, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(project.name).font(.title2.bold())
                            if let branch = GitInfo.branch(for: project.path) {
                                HStack(spacing: 4) {
                                    Image("github").resizable().renderingMode(.template)
                                        .aspectRatio(contentMode: .fit).frame(width: 11, height: 11)
                                    Text(branch)
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            }
                        }
                        Text(project.path)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    statusPill
                }
                Divider()
                controlButtons
            }
        }
    }

    private var statusPill: some View {
        let state = session?.state ?? .idle
        return Label(statusText, systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
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

    private var controlButtons: some View {
        let running = session?.state.isActive ?? false
        return HStack(spacing: 12) {
            PillButton(title: running ? "Stop" : "Launch",
                       systemImage: running ? "stop.fill" : "play.fill") {
                if running { app.stop(project) } else { app.launch(project) }
            }
            .keyboardShortcut(running ? "." : "r", modifiers: .command)

            if running {
                PillButton(title: "Restart", systemImage: "arrow.clockwise") { session?.recycle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            if let port = session?.effectivePort {
                PillButton(title: "Open", systemImage: "globe") { openInBrowser(port: port) }
                    .help("Open http://localhost:\(port) in \(app.settings.browser ?? "your default browser")")
            }
            PillButton(title: "Code", systemImage: "chevron.left.forwardslash.chevron.right") { openInEditor() }
                .help("Open the project in \(app.settings.editor ?? "your code editor")")

            Spacer()
            buildControls
        }
    }

    private func openInBrowser(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)/") else { return }
        if let browser = app.settings.browser, !browser.isEmpty {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", browser, url.absoluteString]
            do { try task.run() } catch { NSWorkspace.shared.open(url) }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openInEditor() {
        let editor = app.settings.editor ?? app.installedEditors.first ?? "Visual Studio Code"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", editor, project.path]
        do { try task.run() } catch { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
    }

    @ViewBuilder private var buildControls: some View {
        if project.buildCommand != nil {
            if let build = app.build(for: project), build.isRunning {
                PillButton(title: "Stop build", systemImage: "stop.fill", prominent: true) { build.stop() }
                    .tint(.red)
            } else {
                if let r = app.build(for: project)?.result {
                    Button { logTab = 1 } label: {
                        Label(r == 0 ? "Built" : "Build failed",
                              systemImage: r == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r == 0 ? .green : .red)
                    }
                    .buttonStyle(.plain).help("Show the build log")
                }
                PillButton(title: "Build", systemImage: "hammer.fill", prominent: true) { app.runBuild(project) }
            }
        }
    }

    // MARK: - Activity card (meters + process table)

    private var activityCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Activity", systemImage: "cpu").font(.headline)
                    Spacer()
                    Toggle("% of machine", isOn: $percentOfMachine)
                        .toggleStyle(.switch).controlSize(.small)
                }
                systemBars
                ProcessTableView(sampler: app.systemSampler, percentOfMachine: $percentOfMachine)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder private var systemBars: some View {
        let s = app.systemSampler
        let bars = app.settings.bars
        let gb = 1_073_741_824.0
        HStack(spacing: 22) {
            if bars.contains("cpu") {
                systemBar(title: "CPU", percent: s.systemCPU, detail: "\(Int(s.systemCPU))%", color: .blue)
            }
            if bars.contains("memory") {
                systemBar(title: "Memory", percent: s.systemMemPercent,
                          detail: String(format: "%.1f / %.0f GB", s.systemMemUsed / gb, s.totalMem / gb),
                          color: .purple)
            }
            if bars.contains("swap") {
                systemBar(title: "Swap", percent: s.systemSwapPercent,
                          detail: s.systemSwapTotal > 0
                            ? String(format: "%.1f / %.0f GB", s.systemSwapUsed / gb, s.systemSwapTotal / gb)
                            : "off",
                          color: .orange)
            }
            if bars.contains("load") {
                systemBar(title: "Load", percent: min(100, s.loadAverage / Double(s.coreCount) * 100),
                          detail: String(format: "%.2f", s.loadAverage), color: .teal)
            }
            if bars.contains("devcpu") {
                systemBar(title: "Dev CPU", percent: min(100, s.devTreeCPU / Double(s.coreCount)),
                          detail: "\(Int(s.devTreeCPU))%", color: .green)
            }
            if bars.contains("devmem") {
                systemBar(title: "Dev RAM", percent: s.totalMem > 0 ? s.devTreeMem / s.totalMem * 100 : 0,
                          detail: String(format: "%.0f MB", s.devTreeMem / 1_048_576), color: .green)
            }
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

    // MARK: - Terminal card (server / build logs)

    private func terminalCard(build: BuildRunner?) -> some View {
        let hasServer = session != nil
        let hasBuild = build != nil
        let tab = (hasServer && hasBuild) ? logTab : (hasBuild ? 1 : 0)
        return card {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    if hasServer {
                        terminalTab(title: "Server", tag: 0, selected: tab == 0) { app.closeServer(project) }
                    }
                    if hasBuild {
                        terminalTab(title: "Build", tag: 1, selected: tab == 1) { app.closeBuild(project) }
                    }
                    Spacer()
                }
                Group {
                    if tab == 1, let build {
                        LogPaneView(lines: build.logLines)
                    } else if let session {
                        serverLog(session)
                    } else if let build {
                        LogPaneView(lines: build.logLines)
                    }
                }
                .frame(minHeight: 160, maxHeight: .infinity)
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
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.7)
            }
            .buttonStyle(.plain)
            .help("Close the \(title.lowercased()) terminal")
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(selected ? AnyShapeStyle(Color.accentColor)
                             : AnyShapeStyle(Color(.quaternaryLabelColor)),
                    in: Capsule())
    }

    private func serverLog(_ session: DevSession) -> some View {
        LogPaneView(lines: session.logLines,
                    inputPlaceholder: "Send input to the dev server (press Enter)…",
                    onSubmit: { session.sendInput($0) })
    }

    // MARK: - Empty

    private var emptyCard: some View {
        card {
            ContentUnavailableView(
                "Not Running",
                systemImage: "play.circle",
                description: Text("Press Launch (⌘R) to start the dev server and stream its logs.")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }
}
