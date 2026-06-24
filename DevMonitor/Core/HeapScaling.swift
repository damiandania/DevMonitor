import Foundation

/// Shared heap-autoscaling policy for the dev server AND the build.
///
/// In AUTO mode the heap starts at `firstGB` and climbs through `steps` each time an out-of-memory
/// is detected, up to the machine's physical RAM. The learned level is persisted per project
/// (separately for the dev server and the build), so the next launch starts where it left off
/// instead of replaying the OOMs.
enum HeapScaling {
    /// The starting heap (GB) for a project with no learned level yet.
    static let firstGB = 4
    /// The ladder of heaps (GB) tried in AUTO mode, in order. Extends well past 8 GB so a big-RAM
    /// Mac keeps climbing instead of giving up at 8 — `next(after:systemGB:)` clamps it to the
    /// machine's actual RAM, so on an 8 GB Mac the effective ladder is still 4 → 6 → 8.
    static let steps = [4, 6, 8, 12, 16, 24]

    /// The next heap (GB) to try after `gb`, or nil when there's no higher step that still fits
    /// physical RAM (`systemGB`). The ceiling is `min(lastStep, systemGB)`, never below `firstGB`.
    static func next(after gb: Int, systemGB: Int) -> Int? {
        let ceiling = min(steps.last ?? firstGB, max(firstGB, systemGB))
        return steps.first { $0 > gb && $0 <= ceiling }
    }

    /// Heuristic: did this exit look like a V8 out-of-memory? `exitCode == 6` is V8's
    /// FatalProcessOutOfMemory (the strongest signal). A *clean* exit is never an OOM, however the
    /// log reads — so a successful run/build that merely printed the word "heap" is not misclassified
    /// and pointlessly retried one rung up. Otherwise we scan the tail of the log, but require an
    /// unambiguous V8 line (or "allocation failed" paired with a fatal marker) rather than any lone
    /// generic keyword, since the exit code varies (SIGABRT 134, Nuxt 6, …).
    static func looksLikeOOM(logLines: [String], exitCode: Int32) -> Bool {
        if exitCode == 6 { return true }
        if exitCode == 0 { return false }
        let tail = logLines.suffix(60).map { $0.lowercased() }
        // Unambiguous V8 OOM lines.
        let strong = ["heap out of memory", "reached heap limit", "javascript heap"]
        if tail.contains(where: { line in strong.contains(where: line.contains) }) { return true }
        // "allocation failed" is generic on its own (native modules, allocators) — only count it as
        // OOM alongside a fatal-error marker, not by itself.
        let hasFatal = tail.contains { $0.contains("fatal error") }
        let hasAllocFail = tail.contains { $0.contains("allocation failed") }
        return hasFatal && hasAllocFail
    }
}
