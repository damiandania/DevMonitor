import SwiftUI

extension BuildRunner {
    /// Status colour for a build tab's dot: running orange, succeeded green, failed red, else
    /// secondary. Kept out of the model so BuildRunner stays UI-free (mirrors SessionState.tint).
    var statusColor: Color {
        if isRunning { return .orange }
        switch result {
        case .some(0): return .green
        case .some:    return .red
        default:       return .secondary
        }
    }
}
