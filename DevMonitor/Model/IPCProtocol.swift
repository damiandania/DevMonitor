import Foundation

/// Shared IPC types between the app (hub) and the `dev-monitor` CLI.
struct IPCRequest: Codable, Sendable {
    var cmd: String          // "run" | "status" | "stop"
    var path: String?        // project path (run)
    var name: String?        // project name (stop)
    var gb: Int?             // heap override (run)
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
