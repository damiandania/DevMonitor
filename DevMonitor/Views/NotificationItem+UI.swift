import SwiftUI

/// UI mapping for the in-app notification feed — kept out of the model (like SessionState+UI).
extension NotificationItem {
    var icon: String {
        switch category {
        case .failures: return severity == .urgent ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        case .recovery: return "arrow.clockwise.circle.fill"
        case .builds:   return action == .openLogs ? "hammer.fill" : "hammer"
        case .pressure: return "gauge.with.dots.needle.67percent"
        }
    }

    var tint: Color {
        if severity == .urgent { return category == .pressure ? .orange : .red }
        switch category {
        case .recovery: return .green
        case .builds:   return action == .openLogs ? .red : .blue
        case .pressure: return .yellow
        case .failures: return .orange      // passive failures: OOM-retry, hung
        }
    }
}
