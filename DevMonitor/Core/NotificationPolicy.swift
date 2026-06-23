import Foundation

/// Pure (UI/UN-free) notification policy: which events notify, how they're classified, and
/// banner throttling. Compiled standalone into the headless test target.
enum NotificationPolicy {

    /// Whether a category should post a system banner, given the user's settings (master + per-category).
    static func shouldNotify(_ category: NotificationCategory, _ settings: AppSettings) -> Bool {
        guard settings.notificationsEnabled else { return false }
        switch category {
        case .failures: return settings.notifyFailures
        case .recovery: return settings.notifyRecovery
        case .builds:   return settings.notifyBuilds
        case .pressure: return settings.notifyPressure
        }
    }

    /// Map a supervision event to its category, urgency, and interactive-action set.
    static func classify(_ event: SupervisionEvent) -> (NotificationCategory, NotificationSeverity, NotificationAction) {
        switch event {
        case .hung:                       return (.failures, .passive, .none)
        case .crashed:                    return (.failures, .urgent,  .restartOpen)
        case .failed:                     return (.failures, .urgent,  .restartOpen)
        case .oomRetry:                   return (.failures, .passive, .none)
        case .recycled:                   return (.recovery, .passive, .none)
        case .recovered:                  return (.recovery, .passive, .none)
        case .buildFinished(_, let ok):   return (.builds,   ok ? .passive : .urgent, ok ? .none : .openLogs)
        }
    }

    /// Build the full notification (title + body) for a supervision event.
    static func make(from event: SupervisionEvent, projectID: UUID?) -> NotificationItem {
        let (category, severity, action) = classify(event)
        let (title, body): (String, String)
        switch event {
        case .hung(let p):
            (title, body) = ("Dev server unresponsive", "\(p) stopped responding.")
        case .recycled(let p):
            (title, body) = ("Dev server recycled", "\(p) was hung and has been restarted.")
        case .recovered(let p):
            (title, body) = ("Dev server recovered", "\(p) is responding again.")
        case .crashed(let p, let code):
            (title, body) = ("Dev server crashed", "\(p) exited with code \(code).")
        case .oomRetry(let p, let gb):
            (title, body) = ("Out of memory — retrying", "\(p) ran out of memory; restarting with \(gb) GB.")
        case .failed(let p, let reason):
            (title, body) = ("Dev server failed", "\(p): \(reason)")
        case .buildFinished(let p, let ok):
            (title, body) = (ok ? "Build succeeded" : "Build failed",
                             "\(p) build \(ok ? "completed successfully" : "failed").")
        }
        return NotificationItem(title: title, body: body, category: category,
                                severity: severity, projectID: projectID, action: action)
    }
}

/// Banner de-dup: suppress a repeat of the same key within `window` (the feed still records every event).
enum NotificationThrottle {
    static func shouldSuppress(key: String, now: Date, last: Date?, window: TimeInterval) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) < window
    }
}
