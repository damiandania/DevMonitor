import SwiftUI
import AppKit

/// Per-project header card: identity, live status, and launch/build controls. Activity and the
/// terminal are global now (see ActivityView / GlobalTerminalView).
struct DashboardView: View {
    @Environment(AppState.self) private var app
    let project: Project

    private var session: DevSession? { app.session(for: project) }

    var body: some View {
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
            }
            Divider()
            controlButtons
        }
        .dmCard()
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
        HStack(spacing: 10) {
            serverControl
            openCodeGroup
            Spacer()
            buildControls
        }
    }

    /// Merged server control: the live status (dot + "Running · npm · :3001") and the
    /// run/stop/restart actions in a single Finder-style capsule.
    private var serverControl: some View {
        let state = session?.state ?? .idle
        let running = state.isActive
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(state.tint)
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(running ? state.tint : .secondary)
                    .lineLimit(1)
            }
            Divider().frame(height: 14)
            if running {
                inlineIcon("stop.fill", "Stop") { app.stop(project) }
                    .keyboardShortcut(".", modifiers: .command)
                inlineIcon("arrow.clockwise", "Restart") { session?.recycle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            } else {
                inlineIcon("play.fill", "Launch") { app.launch(project) }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.leading, 11).padding(.trailing, 5).padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    /// Open-in-browser + open-in-editor as a grouped, icon-only capsule (Finder-toolbar style).
    private var openCodeGroup: some View {
        HStack(spacing: 0) {
            if let port = session?.effectivePort {
                inlineIcon("globe", "Open http://localhost:\(port) in \(app.settings.browser ?? "your browser")") {
                    openInBrowser(port: port)
                }
                Divider().frame(height: 14)
            }
            inlineIcon("chevron.left.forwardslash.chevron.right",
                       "Open in \(app.settings.editor ?? "your editor")") { openInEditor() }
        }
        .padding(.horizontal, 4).padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    /// A borderless icon button sized like a Finder toolbar control.
    private func inlineIcon(_ system: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
                    Button { app.selectedTerminalID = "b:\(project.id)" } label: {
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
}
