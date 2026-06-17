import Foundation

// dev-monitor — CLI client for the Dev Monitor hub (Unix socket).
// Lets any terminal launch/query a dev server through the app.

let usage = """
dev-monitor — launch and supervise dev servers through the Dev Monitor app.

USAGE:
  dev-monitor run [path] [--gb N]   Launch + supervise a project (default: current directory)
  dev-monitor status                Show the active server (name, state, port)
  dev-monitor stop                  Stop the active server
  dev-monitor restart               Recycle (kill tree + relaunch) the active server
  dev-monitor logs [-f]             Print (or follow with -f) the live server log
  dev-monitor docs                  Print this help

The Dev Monitor app must be running (it hosts the hub at ~/Library/Application Support/DevMonitor/dm.sock).
"""

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "status"

func roundtrip(_ req: IPCRequest) -> [IPCMessage]? {
    let fd = dm_ipc_connect(IPCSocket.path)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    guard var data = try? JSONEncoder().encode(req) else { return nil }
    data.append(0x0A)
    data.withUnsafeBytes { raw in if let b = raw.baseAddress { _ = write(fd, b, raw.count) } }
    var messages: [IPCMessage] = []
    var buffer = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == 0x0A {
            if let m = try? JSONDecoder().decode(IPCMessage.self, from: buffer) { messages.append(m) }
            buffer.removeAll()
        } else {
            buffer.append(byte)
        }
    }
    return messages
}

func requireHub(_ req: IPCRequest) -> [IPCMessage] {
    guard let messages = roundtrip(req) else {
        FileHandle.standardError.write(Data("dev-monitor: Dev Monitor app is not running (open it first).\n".utf8))
        exit(1)
    }
    return messages
}

switch cmd {
case "run":
    let pathArg = args.dropFirst().first { !$0.hasPrefix("--") }
    var req = IPCRequest(cmd: "run", path: pathArg ?? FileManager.default.currentDirectoryPath, name: nil, gb: nil)
    if let i = args.firstIndex(of: "--gb"), i + 1 < args.count { req.gb = Int(args[i + 1]) }
    for m in requireHub(req) {
        if m.type == "error" {
            FileHandle.standardError.write(Data("dev-monitor: \(m.message ?? "error")\n".utf8)); exit(1)
        }
        print(m.message ?? m.type)
    }

case "restart":
    for m in requireHub(IPCRequest(cmd: "restart", path: nil, name: nil, gb: nil)) {
        if m.type == "error" {
            FileHandle.standardError.write(Data("dev-monitor: \(m.message ?? "error")\n".utf8)); exit(1)
        }
        print(m.message ?? m.type)
    }

case "logs":
    let logPath = NSHomeDirectory() + "/Library/Application Support/DevMonitor/dev-server.log"
    if args.contains("-f") || args.contains("--follow") {
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-n", "300", "-f", logPath]
        try? tail.run()
        tail.waitUntilExit()
    } else if let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print("(no log yet — launch a server first)")
    }

case "status":
    for m in requireHub(IPCRequest(cmd: "status", path: nil, name: nil, gb: nil)) where m.type == "status" {
        let servers = m.servers ?? []
        if servers.isEmpty { print("No active server."); break }
        for s in servers {
            print("● \(s.name)  —  \(s.state)\(s.port.map { "  :\($0)" } ?? "")")
            print("  \(s.path)")
        }
    }

case "stop":
    for m in requireHub(IPCRequest(cmd: "stop", path: nil, name: nil, gb: nil)) { print(m.message ?? m.type) }

case "docs", "--help", "-h":
    print(usage)

default:
    FileHandle.standardError.write(Data("dev-monitor: unknown command '\(cmd)'. Try 'dev-monitor --help'.\n".utf8))
    exit(1)
}
