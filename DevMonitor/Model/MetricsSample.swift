import Foundation

/// One sampled point of system + dev-tree resource usage (≈1 Hz).
struct MetricPoint: Identifiable, Sendable {
    let id: Int                 // monotonic tick index (also the chart X value)
    let systemCPU: Double       // 0…100
    let systemMemUsed: Double    // bytes
    let systemMemTotal: Double   // bytes
    let treeCPU: Double          // per-core %, can exceed 100 (one pinned core ≈ 100)
    let treeMem: Double          // bytes
    let buildCPU: Double         // per-core % of the build tree (0 until P5)
    let orphanCPU: Double        // per-core % of detected orphans (0 until P3)
    let loadAvg: Double

    var systemMemPercent: Double { systemMemTotal > 0 ? systemMemUsed / systemMemTotal * 100 : 0 }
}
