import Foundation

/// Lifecycle of a supervised dev-server session. Pure model (no UI deps).
enum SessionState: Equatable, Sendable {
    case idle
    case launching
    case running(port: Int?)
    case degraded(strikes: Int)
    case recycling
    case stopped(code: Int32)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .launching, .running, .degraded, .recycling: return true
        case .idle, .stopped, .failed: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .launching: return "Launching…"
        case .running(let port): return port.map { "Running · :\($0)" } ?? "Running"
        case .degraded(let n): return "Unresponsive (\(n))"
        case .recycling: return "Recycling…"
        case .stopped(let code): return code == 0 ? "Stopped" : "Stopped (\(code))"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }
}
