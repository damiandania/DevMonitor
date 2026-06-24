import Foundation

/// A supervision / pressure event persisted to disk so the history survives an app restart (the
/// in-app feed only keeps the last few in memory). One of these is written per `AppState.route(_:)`.
struct PersistedEvent: Codable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    var category: NotificationCategory
    /// Whether the source notification was urgent (drives the history row's tint, like the feed).
    var urgent: Bool
    var title: String
    var body: String
    /// Project this event belongs to (nil for machine-wide pressure events).
    var projectID: UUID?
    /// Resolved project name at the time of the event (kept so history reads even after a rename/remove).
    var projectName: String?
}
