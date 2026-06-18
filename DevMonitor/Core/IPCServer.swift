import Foundation
import Darwin

/// Unix-socket hub: lets `dev-monitor` CLIs launch, build and query dev servers through the app.
/// One supervised server per project (several projects can run at once); the accept loop runs on
/// a background queue and dispatches request handling to the main actor.
@MainActor
final class IPCServer {
    private var listenFD: Int32 = -1
    private weak var app: AppState?

    func start(app: AppState) {
        self.app = app
        let dir = (IPCSocket.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = dm_ipc_listen(IPCSocket.path)
        guard fd >= 0 else { return }
        listenFD = fd

        let queue = DispatchQueue(label: "ipc.accept")
        queue.async { [weak self] in
            while true {
                let client = dm_ipc_accept(fd)
                if client < 0 { break }
                guard let reqData = IPCIO.readLine(client),
                      let req = try? JSONDecoder().decode(IPCRequest.self, from: reqData) else {
                    IPCIO.write(client, IPCMessage(type: "error", message: "bad request"))
                    close(client)
                    continue
                }
                Task { @MainActor in
                    self?.handle(req, client: client)
                }
            }
        }
    }

    private func handle(_ req: IPCRequest, client: Int32) {
        defer { close(client) }
        guard let app else {
            IPCIO.write(client, IPCMessage(type: "error", message: "app unavailable"))
            return
        }
        switch req.cmd {
        case "status":
            // Report EVERY persisted project (not just live sessions), so `status` matches
            // projects.json and a crashed/idle project still appears (and exposes its log path).
            let servers = app.projects
                .sorted { $0.name < $1.name }
                .map { p -> IPCServerInfo in
                    let s = app.sessions[p.id]
                    return IPCServerInfo(
                        name: p.name, path: p.path,
                        state: s?.state.label ?? "Idle",
                        port: s?.effectivePort ?? p.port,
                        logPath: p.logFileURL.path,
                        ready: s?.isReady ?? false,
                        url: s.flatMap { $0.isReady ? $0.url : nil },
                        pid: (s?.pid).flatMap { $0 > 0 ? Int($0) : nil },
                        exitCode: (s?.lastExitCode).map { Int($0) },
                        lastError: s?.lastError)
                }
            IPCIO.write(client, IPCMessage(type: "status", servers: servers))

        case "run", "up":
            guard let project = resolveProject(req, app: app, client: client) else { return }
            // An explicit --gb means "use exactly this heap" → pin it AND turn auto off, otherwise
            // auto mode would override it with the framework default.
            if let gb = req.gb {
                app.setMemoryGB(gb, for: project.id)
                app.setMemoryAuto(false, for: project.id)
            }
            app.selectedProjectID = project.id
            // Idempotent: if this project's server is already supervised, report it, don't relaunch.
            if let existing = app.sessions[project.id], existing.state.isActive {
                let port = existing.effectivePort.map { " on :\($0)" } ?? ""
                IPCIO.write(client, IPCMessage(type: "ok", message: "\(project.name) already running\(port)"))
                return
            }
            guard let toLaunch = app.projects.first(where: { $0.id == project.id }) else {
                IPCIO.write(client, IPCMessage(type: "error", message: "project vanished before launch")); return
            }
            app.launch(toLaunch)
            // Surface when the requested/auto heap was capped to physical RAM, so an explicit
            // `--gb 99` on an 8 GB machine reports "8 GB (capped …)" instead of silently shrinking.
            let gb = app.effectiveMemoryGB(for: toLaunch)
            let requested = toLaunch.memoryAuto ? Detector.defaultMemoryGB(for: toLaunch.framework) : toLaunch.memoryGB
            let capNote = gb < requested ? " — capped from \(requested) GB to fit \(app.systemRAMGB) GB RAM" : ""
            IPCIO.write(client, IPCMessage(type: "ok",
                message: "launched \(toLaunch.name) (\(toLaunch.framework.displayName), \(gb) GB\(capNote))"))

        case "build":
            guard let project = resolveProject(req, app: app, client: client) else { return }
            app.selectedProjectID = project.id
            app.runBuild(project)   // runs alongside the dev server (doesn't stop it)
            IPCIO.write(client, IPCMessage(type: "ok", message: "building \(project.name)"))

        case "stop":
            if req.all == true {
                app.stopAllSessions()
                IPCIO.write(client, IPCMessage(type: "ok", message: "stopped all servers"))
            } else if let path = req.path, let project = app.projects.first(where: { $0.path == path }) {
                app.stop(project)
                IPCIO.write(client, IPCMessage(type: "ok", message: "stopped \(project.name)"))
            } else {
                IPCIO.write(client, IPCMessage(type: "error",
                    message: "no server tracked for this path (use --all to stop everything)"))
            }

        case "restart":
            // Relaunch in ANY state — restart is most needed precisely when a server has Failed.
            guard let path = req.path, let project = app.projects.first(where: { $0.path == path }) else {
                IPCIO.write(client, IPCMessage(type: "error",
                    message: "no project tracked for this path — run 'up' here first")); return
            }
            app.selectedProjectID = project.id
            if let session = app.sessions[project.id], session.state.isActive {
                session.recycle()
                IPCIO.write(client, IPCMessage(type: "ok", message: "restarting \(project.name)"))
            } else {
                app.launch(project)
                IPCIO.write(client, IPCMessage(type: "ok", message: "relaunching \(project.name)"))
            }

        case "remove":
            guard let path = req.path, let project = app.projects.first(where: { $0.path == path }) else {
                IPCIO.write(client, IPCMessage(type: "error", message: "no project tracked for this path")); return
            }
            let name = project.name
            app.removeProject(project.id)   // stops its server/build, then forgets it
            IPCIO.write(client, IPCMessage(type: "ok", message: "removed \(name)"))

        default:
            IPCIO.write(client, IPCMessage(type: "error", message: "unknown command"))
        }
    }

    /// Resolve the request's `path` to a known (or newly added) project. Writes an error and returns
    /// nil when the path is missing or isn't a launchable project folder — so a bogus `up <path>`
    /// never creates a junk entry. Shared by run/up/build.
    private func resolveProject(_ req: IPCRequest, app: AppState, client: Int32) -> Project? {
        guard let path = req.path else {
            IPCIO.write(client, IPCMessage(type: "error", message: "missing path")); return nil
        }
        if let existing = app.projects.first(where: { $0.path == path }) { return existing }
        guard Detector.isProject(path: path) else {
            IPCIO.write(client, IPCMessage(type: "error",
                message: "not a project: \(path)\n  (need an existing folder with a package.json / deno config)"))
            return nil
        }
        guard let project = app.addProject(path: path) else {
            IPCIO.write(client, IPCMessage(type: "error", message: "could not add project")); return nil
        }
        return project
    }
}
