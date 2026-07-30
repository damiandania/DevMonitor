import Foundation

/// Pure memory-headroom checks for a RAM-constrained Mac (the whole reason this app exists).
/// Framework-free and `nonisolated` so it's unit-testable headless, like `SystemSampler.aggregate`.
enum MemoryGuard {
    /// Swap fill (%) at/above which we consider the machine memory-stressed — lower than the
    /// pressure state-machine's stuck threshold, so we can warn BEFORE it's actually thrashing.
    static let highSwapThreshold: Double = 60

    private static let gb = 1_073_741_824.0

    /// A human warning when starting a process that will claim `heapGB` is risky given the current
    /// memory state — nil when there's enough headroom. Risky when the heap won't fit in free
    /// physical RAM, or swap is already high. Used to warn (not block) before a launch.
    static func launchWarning(heapGB: Int, memUsed: Double, memTotal: Double,
                              swapUsed: Double, swapTotal: Double) -> String? {
        let freeBytes = max(0, memTotal - memUsed)
        let heapBytes = Double(heapGB) * gb
        let swapPct = swapTotal > 0 ? swapUsed / swapTotal * 100 : 0
        var reasons: [String] = []
        if heapBytes > freeBytes {
            reasons.append(String(format: "its %d GB heap exceeds the ~%.1f GB of free RAM", heapGB, freeBytes / gb))
        }
        if swapPct >= highSwapThreshold {
            reasons.append("swap is already \(Int(swapPct))% full")
        }
        guard !reasons.isEmpty else { return nil }
        return reasons.joined(separator: ", and ")
            + " — starting it may cause heavy swapping. Consider closing idle projects or lowering its heap."
    }

    /// Edge-trigger for the standalone high-swap warning: given the previous "warned" flag and the
    /// current swap %, returns whether to warn now and the new flag. Warns once when crossing ABOVE
    /// `highSwapThreshold`; re-arms only after dropping below it minus `hysteresis` (so it doesn't
    /// flap around the threshold). Pure so the crossing logic is testable without a run loop.
    static func swapCrossing(swapPercent: Double, wasWarned: Bool, hysteresis: Double = 10)
        -> (warn: Bool, warned: Bool) {
        if !wasWarned, swapPercent >= highSwapThreshold { return (true, true) }
        if wasWarned, swapPercent < highSwapThreshold - hysteresis { return (false, false) }
        return (false, wasWarned)
    }
}
