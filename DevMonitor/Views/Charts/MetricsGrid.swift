import SwiftUI
import Charts

/// 2×2 grid of live resource charts for a dev session (P2).
struct MetricsGrid: View {
    let session: DevSession

    var body: some View {
        let pts = session.history
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                ChartCard(title: "System CPU", suffix: "%", color: .blue, maxY: 100,
                          values: pts.map { ($0.id, $0.systemCPU) },
                          current: pts.last?.systemCPU)
                ChartCard(title: "System Memory", suffix: "%", color: .purple, maxY: 100,
                          values: pts.map { ($0.id, $0.systemMemPercent) },
                          current: pts.last?.systemMemPercent)
            }
            GridRow {
                ChartCard(title: "Dev Server CPU", suffix: "%", color: .green, maxY: nil,
                          values: pts.map { ($0.id, $0.treeCPU) },
                          current: pts.last?.treeCPU)
                ChartCard(title: "Dev Server Memory", suffix: " MB", color: .orange, maxY: nil,
                          values: pts.map { ($0.id, $0.treeMem / 1_048_576) },
                          current: pts.last.map { $0.treeMem / 1_048_576 })
            }
        }
    }
}

/// A single labeled area+line chart over a rolling window.
struct ChartCard: View {
    let title: String
    let suffix: String
    let color: Color
    let maxY: Double?
    let values: [(Int, Double)]
    let current: Double?

    private var upperBound: Double {
        if let maxY { return maxY }
        let peak = values.map(\.1).max() ?? 1
        return Swift.max(1, peak * 1.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let current {
                    Text(String(format: "%.0f%@", current, suffix))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(color)
                }
            }
            Chart {
                ForEach(values, id: \.0) { item in
                    AreaMark(x: .value("t", item.0), y: .value(title, item.1))
                        .foregroundStyle(color.opacity(0.18))
                    LineMark(x: .value("t", item.0), y: .value(title, item.1))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: 0...upperBound)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 86)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if values.isEmpty {
                Text("Waiting for samples…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
