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
