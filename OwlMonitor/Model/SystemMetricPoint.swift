import Foundation

/// One sampled point of whole-machine resource usage (≈2 Hz), buffered by `SystemSampler` to feed
/// the Activity timeline charts. Distinct from `MetricPoint` (per dev-server tree, ~1 Hz).
struct SystemMetricPoint: Identifiable, Sendable {
    let id: Int              // monotonic tick index (also the chart X value)
    let date: Date           // wall-clock of the sample, for the hover readout
    let systemCPU: Double    // 0…100
    let memUsed: Double       // bytes
    let memTotal: Double      // bytes
    let swapUsed: Double      // bytes
    let swapTotal: Double     // bytes
    let loadAverage: Double
    let temperature: Double   // °C, or -1 when no sensor is readable

    var memPercent: Double { memTotal > 0 ? memUsed / memTotal * 100 : 0 }
    var swapPercent: Double { swapTotal > 0 ? swapUsed / swapTotal * 100 : 0 }
}
