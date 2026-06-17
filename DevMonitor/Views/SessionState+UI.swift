import SwiftUI

extension SessionState {
    /// Status tint for the UI. Kept out of the model so SessionState stays UI-free.
    var tint: Color {
        switch self {
        case .idle, .stopped: return .secondary
        case .launching: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }
}
