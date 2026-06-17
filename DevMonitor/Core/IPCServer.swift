import Foundation
import Darwin

/// Unix-socket hub: lets `dev-monitor` CLIs launch and query dev servers through the app.
/// One active server at a time in this MVP (matches the UI); the accept loop runs on a
/// background queue and dispatches request handling to the main actor.
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
            var servers: [IPCServerInfo] = []
            if let s = app.activeSession {
                servers.append(IPCServerInfo(name: s.project.name, path: s.project.path,
                                             state: s.state.label, port: s.effectivePort))
            }
            IPCIO.write(client, IPCMessage(type: "status", servers: servers))

        case "run":
            guard let path = req.path else {
                IPCIO.write(client, IPCMessage(type: "error", message: "missing path")); return
            }
            app.addProject(path: path)
            guard let project = app.projects.first(where: { $0.path == path }) else {
                IPCIO.write(client, IPCMessage(type: "error", message: "could not add project")); return
            }
            if let gb = req.gb { app.setMemoryGB(gb, for: project.id) }
            let toLaunch = app.projects.first(where: { $0.id == project.id })!
            app.selectedProjectID = project.id
            app.launch(toLaunch)
            IPCIO.write(client, IPCMessage(type: "ok",
                message: "launched \(project.name) (\(project.framework.displayName), \(toLaunch.memoryGB) GB)"))

        case "stop":
            app.stopActive()
            IPCIO.write(client, IPCMessage(type: "ok", message: "stopped"))

        case "restart":
            if let session = app.activeSession {
                session.recycle()
                IPCIO.write(client, IPCMessage(type: "ok", message: "restarting \(session.project.name)"))
            } else {
                IPCIO.write(client, IPCMessage(type: "error", message: "no active server"))
            }

        default:
            IPCIO.write(client, IPCMessage(type: "error", message: "unknown command"))
        }
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
