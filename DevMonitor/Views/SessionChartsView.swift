import SwiftUI

/// Per-project charts shown under the dashboard pills for the active dev/preview session: the
/// supervised tree's CPU (per-core %, can exceed 100) and RAM (bytes), from `DevSession.history`
/// (~1 Hz). Reads `history` INSIDE its own body so only this subtree re-renders each tick, never
/// the whole `DashboardView`.
struct SessionChartsView: View {
    let session: DevSession

    var body: some View {
        let history = session.history
        if history.count >= 2 {
            HStack(alignment: .top, spacing: 12) {
                chart(title: "Server CPU",
                      series: MetricSeries(id: "cpu", label: "CPU", color: .green,
                                           points: history.map { MetricPointXY(x: $0.id, y: $0.treeCPU) }),
                      yAxis: .unbounded(floor: 100))
                chart(title: "Server RAM",
                      series: MetricSeries(id: "mem", label: "RAM", color: .teal,
                                           points: history.map { MetricPointXY(x: $0.id, y: $0.treeMem) }),
                      yAxis: .bytes)
            }
        }
    }

    private func chart(title: String, series: MetricSeries, yAxis: MetricYAxis) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            MetricChart(series: [series], yAxis: yAxis, window: 120, height: 84, showLegend: false)
        }
        .frame(maxWidth: .infinity)
    }
}
