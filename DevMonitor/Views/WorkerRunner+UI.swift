import SwiftUI

extension WorkerRunner {
    /// Status colour for a worker's dot/pill: running green, crashed red, otherwise secondary.
    /// Kept out of the model so WorkerRunner stays UI-free (mirrors SessionState.tint / BuildRunner).
    var statusColor: Color {
        if isRunning { return .green }
        if didCrash { return .red }
        return .secondary
    }
}
