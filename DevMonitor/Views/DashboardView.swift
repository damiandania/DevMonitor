import SwiftUI
import AppKit

/// Per-project header card: identity and the live server status/run control in one compact row.
/// Open/Code and Build live in the window toolbar now (see `ProjectOpenGroup` / `ProjectBuildButton`);
/// Activity and the terminal are global (see ActivityView / GlobalTerminalView).
struct DashboardView: View {
    @Environment(AppState.self) private var app
    let project: Project

    private var session: DevSession? { app.session(for: project) }

    var body: some View {
        HStack(spacing: 12) {
            ProjectIconView(project: project, size: 30)
            Text(project.name).font(.title2.bold()).lineLimit(1)
                .help(project.path)
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
                .help("Current Git branch: \(branch)")
            }
            Spacer()
            serverControl
        }
        .dmCard()
    }

    /// Status text including the package manager when the server is up, e.g. "Running · npm · :3000".
    private var statusText: String {
        let state = session?.state ?? .idle
        if case .running = state { return "Running" }
        if case .idle = state { return "Server" }
        return state.label
    }

    /// Spoken-out status for the pill tooltip — also surfaces the full message for failed states.
    private var statusHelp: String {
        switch session?.state ?? .idle {
        case .idle: return "No dev server running — click ▶ to launch"
        case .launching: return "Starting the dev server…"
        case .running(let port):
            let pm = project.packageManager.rawValue
            return port.map { "Running with \(pm) on port \($0)" } ?? "Running with \(pm)"
        case .degraded(let n): return "Server unresponsive (\(n) strikes)"
        case .recycling: return "Restarting the dev server…"
        case .stopped(let code): return code == 0 ? "Server stopped" : "Server stopped with code \(code)"
        case .failed(let msg): return "Server failed: \(msg)"
        }
    }

    /// Live server status as one big, full-rounded pill that changes color with the state (green
    /// when running) so it stands out. Stop/Restart/Launch live inside it as plain icon buttons —
    /// no boxed-in square controls.
    private var serverControl: some View {
        let state = session?.state ?? .idle
        let running = state.isActive
        return HStack(spacing: 14) {
            Text(statusText)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .help(statusHelp)
            if running {
                pillIcon("stop.fill", "Stop") { app.stop(project) }
                    .keyboardShortcut(".", modifiers: .command)
                pillIcon("arrow.clockwise", "Restart") { session?.recycle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            } else {
                pillIcon("play.fill", "Launch") { app.launch(project) }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(pillColor(state), in: Capsule())
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    /// A plain icon button (no box) tinted white, for use inside the colored status pill.
    private func pillIcon(_ system: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Solid, readable fill for the status pill — keyed to the state so the pill changes color
    /// (green running, orange launching, red failed, gray idle).
    private func pillColor(_ state: SessionState) -> Color {
        switch state {
        case .idle: return .blue
        case .stopped: return .red
        // running=.green, launching/recycling=.orange, degraded=.yellow, failed=.red
        default: return state.tint
        }
    }
}

/// Group 1 of the window toolbar: open the running server in the browser, the project in the editor,
/// and the project folder in Finder — as one united `ControlGroup` that matches the native
/// Settings/Doctor button style. Acts on the currently selected project.
struct ProjectOpenGroup: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let project = app.selectedProject {
            ControlGroup {
                if let port = app.session(for: project)?.effectivePort {
                    Button { openInBrowser(port: port) } label: {
                        Label("Open in browser", systemImage: "globe")
                    }
                    .help("Open http://localhost:\(port) in \(app.settings.browser ?? "your browser")")
                }
                Button { openInEditor(project) } label: {
                    Label("Open in editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("Open in \(app.settings.editor ?? "your editor")")
                Button { openInFinder(project) } label: {
                    Label("Open folder", systemImage: "folder")
                }
                .help("Open the project folder in Finder")
            }
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

    private func openInEditor(_ project: Project) {
        let editor = app.settings.editor ?? app.installedEditors.first ?? "Visual Studio Code"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", editor, project.path]
        do { try task.run() } catch { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
    }

    private func openInFinder(_ project: Project) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
    }
}

/// Group 2 of the window toolbar: the build control as a single button matching the native
/// Settings/Doctor style. Acts on the currently selected project.
struct ProjectBuildButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let project = app.selectedProject, project.buildCommand != nil {
            if let build = app.build(for: project), build.isRunning {
                Button { build.stop() } label: { Label("Stop build", systemImage: "stop.fill") }
                    .help("Stop build")
            } else {
                Button { app.runBuild(project) } label: { Label("Build", systemImage: "hammer.fill") }
                    .help(buildHelp(project))
            }
        }
    }

    private func buildHelp(_ project: Project) -> String {
        switch app.build(for: project)?.result {
        case .some(0): return "Built — click to rebuild"
        case .some: return "Build failed — click to rebuild"
        default: return "Build the project"
        }
    }
}
