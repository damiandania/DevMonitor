import SwiftUI

extension ResourceAdvisor.Severity {
    /// Status tint for a recommendation's severity dot. Kept out of ResourceAdvisor so it stays UI-free.
    var tint: Color {
        switch self {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .secondary
        }
    }
}
