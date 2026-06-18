import Foundation

// dev-monitor — CLI client for the Dev Monitor hub (Unix socket).
// Lets any terminal launch/query a dev server through the app.

// A socket client must never die from SIGPIPE when the peer closes mid-write.
signal(SIGPIPE, SIG_IGN)

let usage = """
dev-monitor — launch, build and supervise dev servers through the Dev Monitor app.

USAGE:
  dev-monitor up [path] [--gb N]    Start the project's server (no-op if already up). Alias: run
  dev-monitor build [path]          Build the project — stops its server first, relaunches after
  dev-monitor status [--json]       List every supervised server (name, state, port)
  dev-monitor stop [path] [--all]   Stop one project's server (default: cwd), or --all of them
  dev-monitor restart [path]        Recycle (kill tree + relaunch) the project's server
  dev-monitor logs [-f]             Print (or follow with -f) the live server log
  dev-monitor docs                  Print this help

One supervised server PER PROJECT; several projects can run at once. Paths default to the
current directory. The Dev Monitor app hosts the hub at
~/Library/Application Support/DevMonitor/dm.sock — if it isn't running, it's started for you.
"""

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "status"

/// First non-flag argument, or the current working directory.
func pathArg() -> String {
    args.dropFirst().first { !$0.hasPrefix("-") } ?? FileManager.default.currentDirectoryPath
}

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

/// Opens the Dev Monitor app via LaunchServices and waits (up to ~8s) for its hub
/// socket to come up. Returns true once the socket accepts a connection.
func launchAppAndWait() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", "Dev Monitor"]
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    for _ in 0..<75 {                       // 75 × 200ms ≈ 15s (cold first-launch margin)
        let fd = dm_ipc_connect(IPCSocket.path)
        if fd >= 0 { close(fd); return true }
        usleep(200_000)
    }
    return false
}

func requireHub(_ req: IPCRequest) -> [IPCMessage] {
    if let messages = roundtrip(req) { return messages }
    // Hub unreachable — start the app, then retry (the first request right after a
    // cold launch can race the IPC accept loop, so give it a few attempts).
    FileHandle.standardError.write(Data("dev-monitor: starting Dev Monitor…\n".utf8))
    if launchAppAndWait() {
        for _ in 0..<10 {
            if let messages = roundtrip(req) { return messages }
            usleep(300_000)
        }
    }
    FileHandle.standardError.write(Data("dev-monitor: could not reach the Dev Monitor app.\n".utf8))
    exit(1)
}

/// Send a request, print ok messages, exit 1 on error.
func runAndReport(_ req: IPCRequest) {
    for m in requireHub(req) {
        if m.type == "error" {
            FileHandle.standardError.write(Data("dev-monitor: \(m.message ?? "error")\n".utf8)); exit(1)
        }
        print(m.message ?? m.type)
    }
}

switch cmd {
case "run", "up":
    var req = IPCRequest(cmd: cmd, path: pathArg(), name: nil, gb: nil, all: nil)
    if let i = args.firstIndex(of: "--gb"), i + 1 < args.count { req.gb = Int(args[i + 1]) }
    runAndReport(req)

case "build":
    runAndReport(IPCRequest(cmd: "build", path: pathArg(), name: nil, gb: nil, all: nil))

case "restart":
    runAndReport(IPCRequest(cmd: "restart", path: pathArg(), name: nil, gb: nil, all: nil))

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
    let wantJSON = args.contains("--json")
    for m in requireHub(IPCRequest(cmd: "status", path: nil, name: nil, gb: nil, all: nil)) where m.type == "status" {
        let servers = m.servers ?? []
        if wantJSON {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(servers), let s = String(data: data, encoding: .utf8) { print(s) }
            else { print("[]") }
            break
        }
        if servers.isEmpty { print("No active servers."); break }
        for s in servers {
            print("● \(s.name)  —  \(s.state)\(s.port.map { "  :\($0)" } ?? "")")
            print("  \(s.path)")
        }
    }

case "stop":
    let all = args.contains("--all")
    let req = IPCRequest(cmd: "stop", path: all ? nil : pathArg(), name: nil, gb: nil, all: all ? true : nil)
    runAndReport(req)

case "docs", "--help", "-h":
    print(usage)

default:
    FileHandle.standardError.write(Data("dev-monitor: unknown command '\(cmd)'. Try 'dev-monitor --help'.\n".utf8))
    exit(1)
}
