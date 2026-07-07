import SwiftUI
import AppKit

/// Per-project header card: identity and the live server status/run control in one compact row.
/// Open/Code and Build live in the window toolbar now (see `ProjectOpenGroup` / `ProjectBuildButton`);
/// Activity and the terminal are global (see ActivityView / GlobalTerminalView).
struct DashboardView: View {
    @Environment(AppState.self) private var app
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Identity row: icon · name · git branch.
            HStack(spacing: 12) {
                ProjectIconView(project: project, size: 30)
                Text(project.name).font(.title2.bold()).lineLimit(1)
                    .help(project.path)
                BranchWorktreeMenu(project: project)
                Spacer()
            }
            Divider()
            // One play/stop pill per run-control the project has — dev, worker, build, preview, … —
            // all from AppState.runControls(for:), so a new process type appears here automatically.
            HStack(spacing: 10) {
                ForEach(app.runControls(for: project)) { control in
                    RunControlButton(title: control.title, status: control.status, onToggle: control.onToggle)
                }
                Spacer(minLength: 0)
            }
            // Live CPU/RAM charts for the project's active dev/preview tree. Isolated in
            // SessionChartsView so its ~1 Hz churn doesn't re-render this card.
            if app.settings.showCharts, let session = activeSession {
                Divider()
                SessionChartsView(session: session)
            }
        }
        .dmCard()
    }

    /// The project's active supervised session — dev if running, else the preview (mutually
    /// exclusive per project). nil when nothing is live, so the charts stay hidden.
    private var activeSession: DevSession? {
        if let s = app.sessions[project.id], s.state.isActive { return s }
        if let p = app.previews[project.id], p.state.isActive { return p }
        return nil
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
        openWith(appNamed: app.settings.browser, target: url.absoluteString, fallback: url)
    }

    private func openInEditor(_ project: Project) {
        let editor = app.settings.editor ?? app.installedEditors.first ?? "Visual Studio Code"
        openWith(appNamed: editor, target: project.path, fallback: URL(fileURLWithPath: project.path))
    }

    private func openInFinder(_ project: Project) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
    }

    /// `open -a <app> <target>`, falling back to the system default handler if no app is set or the
    /// launch fails. Shared by the browser and editor buttons.
    private func openWith(appNamed appName: String?, target: String, fallback: URL) {
        guard let appName, !appName.isEmpty else { NSWorkspace.shared.open(fallback); return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", appName, target]
        do { try task.run() } catch { NSWorkspace.shared.open(fallback) }
    }
}

// The build control moved into the dashboard's run-control column (see RunControlRow), so the
// toolbar build button / "Build Running" label that used to live here are gone.
