import Foundation

// dev-monitor — CLI client for the Dev Monitor hub (Unix socket).
// Lets any terminal launch/query a dev server through the app.

// A socket client must never die from SIGPIPE when the peer closes mid-write.
signal(SIGPIPE, SIG_IGN)

let dmVersion = "0.1.0"   // keep in sync with project.yml MARKETING_VERSION

let usage = """
dev-monitor — launch, build and supervise dev servers through the Dev Monitor app.

USAGE:
  dev-monitor up [path] [--gb N] [--wait]   Start the server (--wait blocks until ready, prints URL). Alias: run
  dev-monitor build [path]          Build the project (runs alongside the dev server)
  dev-monitor status [--json]       List every known project (name, state, port)
  dev-monitor stop [path] [--all]   Stop one project's server (default: cwd), or --all of them
  dev-monitor restart [path]        Relaunch the project's server (works from any state)
  dev-monitor remove [path]         Stop and forget the project (aliases: rm, forget)
  dev-monitor logs [path] [-f]      Print (or follow with -f) that project's log (default: cwd)
  dev-monitor version               Print the version (aliases: -v, --version)
  dev-monitor docs                  Print this help

One supervised server PER PROJECT; several projects can run at once. Paths default to the
current directory and are resolved to absolute. The Dev Monitor app hosts the hub at
~/Library/Application Support/DevMonitor/dm.sock — if it isn't running, it's started for you.
"""

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "status"
let rest = Array(args.dropFirst())

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("dev-monitor: \(msg)\n".utf8)); exit(1)
}

/// Exactly one optional path positional; resolved to absolute. More than one is an error.
func singlePath(_ a: DMArgs) -> String {
    if a.positionals.count > 1 { die("too many arguments: \(a.positionals.joined(separator: " "))") }
    if let p = a.positionals.first { return DMParse.absolutePath(p) }
    return FileManager.default.currentDirectoryPath
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

/// Opens the Dev Monitor app via LaunchServices and waits (up to ~15s) for its hub
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

/// All known projects, as reported by the hub (used by `status`, `logs` and `--wait`).
func fetchServers() -> [IPCServerInfo] {
    var servers: [IPCServerInfo] = []
    for m in requireHub(IPCRequest(cmd: "status", path: nil, name: nil, gb: nil, all: nil)) where m.type == "status" {
        servers = m.servers ?? []
    }
    return servers
}

/// Block until the project at `path` is HTTP-ready (print its URL, exit 0), has Failed (print the
/// cause, exit 1), or the timeout elapses — so `up --wait` saves the caller from polling itself.
func waitUntilReady(_ path: String, timeoutSeconds: Double = 180) {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        // Tolerate a transient untrack/retrack (e.g. a rapid stop→up, or a crash auto-restart): if
        // the project momentarily isn't in the list, keep waiting rather than failing — only `Failed`
        // or the overall timeout ends the wait.
        if let s = fetchServers().first(where: { $0.path == path }) {
            if s.ready == true { print("ready: \(s.url ?? "(running)")"); return }
            if s.state.hasPrefix("Failed") { die("failed: \(s.lastError ?? s.state)") }
        }
        usleep(400_000)
    }
    die("timed out after \(Int(timeoutSeconds))s waiting for readiness (see: dev-monitor logs '\(path)')")
}

switch cmd {
case "run", "up":
    let a = DMParse.parse(rest, boolFlags: ["--wait"], allowGB: true)
    if let e = a.error { die(e) }
    let upPath = singlePath(a)
    runAndReport(IPCRequest(cmd: cmd, path: upPath, name: nil, gb: a.gb, all: nil))
    if a.flags.contains("--wait") { waitUntilReady(upPath) }

case "build", "restart", "remove", "rm", "forget":
    let a = DMParse.parse(rest, boolFlags: [], allowGB: false)
    if let e = a.error { die(e) }
    let normalized = (cmd == "rm" || cmd == "forget") ? "remove" : cmd
    runAndReport(IPCRequest(cmd: normalized, path: singlePath(a), name: nil, gb: nil, all: nil))

case "stop":
    let a = DMParse.parse(rest, boolFlags: ["--all"], allowGB: false)
    if let e = a.error { die(e) }
    let all = a.flags.contains("--all")
    runAndReport(IPCRequest(cmd: "stop", path: all ? nil : singlePath(a),
                            name: nil, gb: nil, all: all ? true : nil))

case "status":
    let a = DMParse.parse(rest, boolFlags: ["--json"], allowGB: false)
    if let e = a.error { die(e) }
    let servers = fetchServers()
    if a.flags.contains("--json") {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(servers), let s = String(data: data, encoding: .utf8) { print(s) }
        else { print("[]") }
    } else if servers.isEmpty {
        print("No projects yet.")
    } else {
        for s in servers {
            // The state label already carries the port for a running server ("Running · :3999"),
            // so only append the port when the label doesn't already mention it (e.g. a configured
            // port on an idle project).
            let portSuffix = (s.port.map { ":\($0)" }).flatMap { s.state.contains($0) ? nil : "  \($0)" } ?? ""
            print("● \(s.name)  —  \(s.state)\(portSuffix)")
            print("  \(s.path)")
        }
    }

case "logs":
    let a = DMParse.parse(rest, boolFlags: ["-f", "--follow"], allowGB: false)
    if let e = a.error { die(e) }
    let follow = a.flags.contains("-f") || a.flags.contains("--follow")
    let target = singlePath(a)
    guard let server = fetchServers().first(where: { $0.path == target }), let logPath = server.logPath else {
        die("no project tracked for \(target) — run 'dev-monitor up' here first")
    }
    if follow {
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

case "version", "--version", "-v":
    print("dev-monitor \(dmVersion)")

case "docs", "--help", "-h", "help":
    print(usage)

default:
    die("unknown command '\(cmd)'. Try 'dev-monitor --help'.")
}
