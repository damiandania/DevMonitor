import Foundation

/// A noteworthy supervision event, surfaced to the UI/notifications layer.
/// Kept UI/framework-free so DevSession stays testable headless.
enum SupervisionEvent: Sendable {
    case hung(project: String)
    case recycled(project: String)
    case recovered(project: String)
    case crashed(project: String, code: Int32)
    case oomRetry(project: String, newHeapGB: Int)   // out-of-memory → auto-retrying with a bigger heap
    case failed(project: String, reason: String)     // gave up (exhausted restarts / never healthy)
    case buildFinished(project: String, success: Bool)
}
