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
            (title, body) = (String(localized: "Dev server unresponsive"),
                             String(localized: "\(p) stopped responding."))
        case .recycled(let p):
            (title, body) = (String(localized: "Dev server recycled"),
                             String(localized: "\(p) was hung and has been restarted."))
        case .recovered(let p):
            (title, body) = (String(localized: "Dev server recovered"),
                             String(localized: "\(p) is responding again."))
        case .crashed(let p, let code):
            (title, body) = (String(localized: "Dev server crashed"),
                             String(localized: "\(p) exited with code \(Int(code))."))
        case .oomRetry(let p, let gb):
            (title, body) = (String(localized: "Out of memory — retrying"),
                             String(localized: "\(p) ran out of memory; restarting with \(gb) GB."))
        case .failed(let p, let reason):
            (title, body) = (String(localized: "Dev server failed"),
                             String(localized: "\(p): \(reason)"))
        case .buildFinished(let p, let ok):
            (title, body) = (ok ? String(localized: "Build succeeded") : String(localized: "Build failed"),
                             ok ? String(localized: "\(p) build completed successfully.")
                                : String(localized: "\(p) build failed."))
        }
        return NotificationItem(title: title, body: body, category: category,
                                severity: severity, projectID: projectID, action: action)
    }

    // MARK: - Machine-pressure notifications
    // These aren't derived from a per-project `SupervisionEvent`; they're machine-wide. Kept here
    // (not inline in AppState) so the wording/classification is policy and stays unit-testable.

    /// Posted once when the machine enters a stuck/pressure episode. Urgent so it cuts through.
    static func machineUnderPressure(reason: String) -> NotificationItem {
        NotificationItem(title: String(localized: "Machine under pressure"),
                         body: reason.isEmpty ? String(localized: "The machine is stuck.") : reason,
                         category: .pressure, severity: .urgent, projectID: nil, action: .open)
    }

    /// Posted when the machine recovers from a pressure episode we previously warned about.
    static func pressureCleared() -> NotificationItem {
        NotificationItem(title: String(localized: "System pressure cleared"),
                         body: String(localized: "The machine is no longer under pressure."),
                         category: .pressure, severity: .passive, projectID: nil, action: .open)
    }

    /// Posted on launch when a persisted store (projects.json / settings.json) was unreadable: the
    /// bad file has been backed up and the data reset to defaults, so the user knows it was reset
    /// (and where to recover it) instead of silently losing every project / preference.
    static func storeCorrupted(what: String, backup: URL?) -> NotificationItem {
        let recovery = backup.map { String(localized: " A backup was saved to “\($0.lastPathComponent)”.") } ?? ""
        return NotificationItem(title: String(localized: "\(what) was reset"),
                                body: String(localized: "\(what) couldn’t be read and was reset to defaults.") + recovery,
                                category: .failures, severity: .urgent, projectID: nil, action: .none)
    }

    /// Posted after auto-closing orphaned dev processes to relieve pressure.
    static func orphansClosed(count: Int, names: String) -> NotificationItem {
        let title = count > 1 ? String(localized: "Closed orphaned dev processes")
                              : String(localized: "Closed orphaned dev process")
        return NotificationItem(title: title,
                                body: String(localized: "Auto-closed \(count) to relieve pressure: \(names)"),
                                category: .pressure, severity: .passive, projectID: nil, action: .none)
    }
}

/// Banner de-dup: suppress a repeat of the same key within `window` (the feed still records every event).
enum NotificationThrottle {
    /// Default suppression window for repeated banners of the same key.
    static let defaultWindow: TimeInterval = 15
    static func shouldSuppress(key: String, now: Date, last: Date?, window: TimeInterval) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) < window
    }
}
