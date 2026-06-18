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
            let servers = app.sessions.values
                .sorted { $0.project.name < $1.project.name }
                .map { IPCServerInfo(name: $0.project.name, path: $0.project.path,
                                     state: $0.state.label, port: $0.effectivePort) }
            IPCIO.write(client, IPCMessage(type: "status", servers: servers))

        case "run", "up":
            guard let project = resolveProject(req, app: app, client: client) else { return }
            if let gb = req.gb { app.setMemoryGB(gb, for: project.id) }
            app.selectedProjectID = project.id
            // Idempotent: if this project's server is already supervised, report it, don't relaunch.
            if let existing = app.sessions[project.id], existing.state.isActive {
                let port = existing.effectivePort.map { " on :\($0)" } ?? ""
                IPCIO.write(client, IPCMessage(type: "ok", message: "\(project.name) already running\(port)"))
                return
            }
            let toLaunch = app.projects.first { $0.id == project.id }!
            app.launch(toLaunch)
            IPCIO.write(client, IPCMessage(type: "ok",
                message: "launched \(project.name) (\(project.framework.displayName), \(toLaunch.memoryGB) GB)"))

        case "build":
            guard let project = resolveProject(req, app: app, client: client) else { return }
            app.selectedProjectID = project.id
            let willRestart = app.sessions[project.id]?.state.isActive ?? false
            app.runBuild(project)
            let note = willRestart ? " (stopping the running server first; will relaunch after)" : ""
            IPCIO.write(client, IPCMessage(type: "ok", message: "building \(project.name)\(note)"))

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
            if let path = req.path, let project = app.projects.first(where: { $0.path == path }),
               let session = app.sessions[project.id], session.state.isActive {
                session.recycle()
                IPCIO.write(client, IPCMessage(type: "ok", message: "restarting \(project.name)"))
            } else {
                IPCIO.write(client, IPCMessage(type: "error", message: "no active server for this path"))
            }

        default:
            IPCIO.write(client, IPCMessage(type: "error", message: "unknown command"))
        }
    }

    /// Resolve the request's `path` to a known/added project, writing an error to the client and
    /// returning nil if it can't. Shared by run/up/build.
    private func resolveProject(_ req: IPCRequest, app: AppState, client: Int32) -> Project? {
        guard let path = req.path else {
            IPCIO.write(client, IPCMessage(type: "error", message: "missing path")); return nil
        }
        app.addProject(path: path)
        guard let project = app.projects.first(where: { $0.path == path }) else {
            IPCIO.write(client, IPCMessage(type: "error", message: "could not add project")); return nil
        }
        return project
    }
}

/// Blocking line-delimited JSON socket I/O (used off the main actor).
enum IPCIO {
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { break }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }

    static func write(_ fd: Int32, _ message: IPCMessage) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = Darwin.write(fd, base, raw.count) }
        }
    }
}
