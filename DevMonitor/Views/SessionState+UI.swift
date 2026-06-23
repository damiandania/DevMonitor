import SwiftUI

extension SessionState {
    /// Status tint for the UI. Kept out of the model so SessionState stays UI-free.
    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .stopped, .failed: return .red
        case .launching, .recycling: return .orange
        case .running: return .green
        case .degraded: return .yellow
        }
    }
}
