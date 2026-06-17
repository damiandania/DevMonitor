import Foundation

// dev-monitor — CLI client for the Dev Monitor hub (Unix socket).
// Lets any terminal launch/query a dev server through the app.

let usage = """
dev-monitor — launch and supervise dev servers through the Dev Monitor app.

USAGE:
  dev-monitor run [--gb N]   Launch + supervise the project in the current directory
  dev-monitor status         Show the active server (name, state, port)
  dev-monitor stop           Stop the active server
  dev-monitor docs           Print this help

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
    var req = IPCRequest(cmd: "run", path: FileManager.default.currentDirectoryPath, name: nil, gb: nil)
    if let i = args.firstIndex(of: "--gb"), i + 1 < args.count { req.gb = Int(args[i + 1]) }
    for m in requireHub(req) {
        if m.type == "error" {
            FileHandle.standardError.write(Data("dev-monitor: \(m.message ?? "error")\n".utf8)); exit(1)
        }
        print(m.message ?? m.type)
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
