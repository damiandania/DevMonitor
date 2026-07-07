import SwiftUI

/// Body of the Activity card's timeline accordion: whole-machine CPU / Memory / Swap as one live
/// line chart over the last ~5 minutes, from `SystemSampler.history`. Isolated in its own view so
/// its ~2 Hz refresh invalidates only this subtree, not the rest of the Activity card.
struct ActivityTimelineView: View {
    let sampler: SystemSampler

    var body: some View {
        let history = sampler.history
        if history.count < 2 {
            Text("Collecting…")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
        } else {
            MetricChart(
                series: [
                    MetricSeries(id: "cpu", label: "CPU", color: .blue,
                                 points: history.map { MetricPointXY(x: $0.id, y: $0.systemCPU) }),
                    MetricSeries(id: "mem", label: "Memory", color: .indigo,
                                 points: history.map { MetricPointXY(x: $0.id, y: $0.memPercent) }),
                    MetricSeries(id: "swap", label: "Swap", color: .orange,
                                 points: history.map { MetricPointXY(x: $0.id, y: $0.swapPercent) }),
                ],
                yAxis: .percent, window: 300, height: 150)
        }
    }
}
