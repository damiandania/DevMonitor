import Foundation

/// Shared heap-autoscaling policy for the dev server AND the build.
///
/// In AUTO mode the heap starts at `firstGB` and climbs in fixed steps (4 → 6 → 8) each time an
/// out-of-memory is detected, up to the machine's physical RAM. The learned level is persisted per
/// project (separately for the dev server and the build), so the next launch starts where it left
/// off instead of replaying the OOMs.
enum HeapScaling {
    /// The starting heap (GB) for a project with no learned level yet.
    static let firstGB = 4
    /// The ladder of heaps (GB) tried in AUTO mode, in order.
    static let steps = [4, 6, 8]

    /// The next heap (GB) to try after `gb`, or nil when there's no higher step that still fits
    /// physical RAM (`systemGB`). The ceiling is `min(lastStep, systemGB)`, never below `firstGB`.
    static func next(after gb: Int, systemGB: Int) -> Int? {
        let ceiling = min(steps.last ?? firstGB, max(firstGB, systemGB))
        return steps.first { $0 > gb && $0 <= ceiling }
    }

    /// Heuristic: did this exit look like a V8 out-of-memory? `exitCode == 6` is V8's
    /// FatalProcessOutOfMemory; otherwise we scan the tail of the log for the usual heap messages
    /// (robust to the exit code, which varies — SIGABRT 134, Nuxt 6, …).
    static func looksLikeOOM(logLines: [String], exitCode: Int32) -> Bool {
        if exitCode == 6 { return true }
        return logLines.suffix(60).contains { line in
            let s = line.lowercased()
            return s.contains("heap out of memory") || s.contains("javascript heap")
                || s.contains("reached heap limit") || s.contains("allocation failed")
        }
    }
}
