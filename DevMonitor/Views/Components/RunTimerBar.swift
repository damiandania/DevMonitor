import SwiftUI

/// The status strip shown at the bottom of a terminal pane (in place of the unused stdin "chat"):
/// a live uptime counter for a running dev server / worker, or, for a build, the elapsed time on the
/// left, a progress bar in the middle, and the ETA (the last build's duration) on the right.
struct RunTimerBar: View {
    enum Mode {
        case uptime(since: Date)                            // dev / worker running
        case build(since: Date, estimate: TimeInterval?)    // build running; estimate = last duration
    }
    let mode: Mode

    var body: some View {
        switch mode {
        case .uptime(let since):
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.caption2)
                Text("Running for").font(.caption)
                Text(since, style: .timer).font(.caption.monospacedDigit())
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

        case .build(let since, let estimate):
            // Recompute the elapsed/fraction a couple of times per second.
            TimelineView(.periodic(from: since, by: 0.5)) { ctx in
                let elapsed = max(0, ctx.date.timeIntervalSince(since))
                HStack(spacing: 10) {
                    Text(Self.clock(elapsed))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let estimate, estimate > 0 {
                        ProgressView(value: min(elapsed / estimate, 1))
                            .progressViewStyle(.linear)
                        Text("~\(Self.clock(estimate))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        // No previous build to estimate from — show an indeterminate bar.
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
        }
    }

    /// Seconds → "m:ss" (or "h:mm:ss" past an hour).
    static func clock(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
