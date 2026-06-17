import Foundation
import UserNotifications

/// Posts native macOS notifications (with sound) for supervision events.
@MainActor
final class Notifier {
    static let shared = Notifier()
    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ event: SupervisionEvent) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        switch event {
        case .hung(let p):
            content.title = "Dev server unresponsive"
            content.body = "\(p) stopped responding."
        case .recycled(let p):
            content.title = "Dev server recycled"
            content.body = "\(p) was hung and has been restarted."
        case .recovered(let p):
            content.title = "Dev server recovered"
            content.body = "\(p) is responding again."
        case .crashed(let p, let code):
            content.title = "Dev server crashed"
            content.body = "\(p) exited with code \(code)."
        case .buildFinished(let p, let ok):
            content.title = ok ? "Build succeeded" : "Build failed"
            content.body = "\(p) build \(ok ? "completed successfully" : "failed")."
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
