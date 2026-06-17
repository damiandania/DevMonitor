import Foundation

/// A noteworthy supervision event, surfaced to the UI/notifications layer.
/// Kept UI/framework-free so DevSession stays testable headless.
enum SupervisionEvent: Sendable {
    case hung(project: String)
    case recycled(project: String)
    case recovered(project: String)
    case crashed(project: String, code: Int32)
    case buildFinished(project: String, success: Bool)
}
