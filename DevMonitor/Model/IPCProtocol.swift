import Foundation

/// Shared IPC types between the app (hub) and the `dev-monitor` CLI.
struct IPCRequest: Codable, Sendable {
    var cmd: String          // "run"/"up" | "status" | "stop" | "restart" | "build"
    var path: String?        // project path (run/up/build/stop/restart) — defaults to the CLI's cwd
    var name: String?        // reserved
    var gb: Int?             // heap override (run/up)
    var all: Bool?           // stop: stop every supervised server, not just this path's
}

struct IPCServerInfo: Codable, Sendable {
    var name: String
    var path: String
    var state: String
    var port: Int?
    /// Absolute path to this project's log file (so `dev-monitor logs [path]` can find it).
    var logPath: String?
    // Structured fields so an agent can operate/diagnose from `status --json` alone — no curl, no
    // reading internal files. All optional for backward/forward compatibility.
    /// HTTP-confirmed running (reliable readiness — true only after a successful health probe).
    var ready: Bool?
    /// The server URL once a port is known, e.g. "http://localhost:3000/".
    var url: String?
    /// Process-group leader pid while running (nil when not running).
    var pid: Int?
    /// Exit code of the last process exit (nil if it has never exited).
    var exitCode: Int?
    /// Human cause of the last failure, with a remedy when known (e.g. an OOM hint).
    var lastError: String?
}

struct IPCMessage: Codable, Sendable {
    var type: String         // "status" | "ok" | "error"
    var servers: [IPCServerInfo]?
    var message: String?
}

enum IPCSocket {
    /// `~/Library/Application Support/DevMonitor/dm.sock`
    static var path: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/DevMonitor/dm.sock")
    }
}
