import SwiftUI
import Charts

/// One point on a metric chart. X is the sample's monotonic tick index; Y is the value in the
/// series' native unit (percent, bytes, or per-core %).
struct MetricPointXY: Identifiable, Sendable {
    let x: Int
    let y: Double
    var id: Int { x }
}

/// One line on a metric chart (e.g. "CPU"), with its own colour.
struct MetricSeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    let points: [MetricPointXY]
}

/// How to scale/label the Y axis.
enum MetricYAxis {
    case percent                    // fixed 0…100, "%" labels
    case bytes                      // auto, nice-ceil, GB/MB labels
    case unbounded(floor: Double)   // auto with a floor (per-core CPU pins the floor at 100)
}

/// The single line chart used for both the system timeline and the per-session charts. Pure
/// consumer of `[MetricSeries]` + `MetricChartMath` — no sampling of its own. Kept intentionally
/// jank-free at 2 Hz: line-only, animation disabled, a fixed sliding X domain, and downsampling
/// past `maxRenderPoints`.
struct MetricChart: View {
    let series: [MetricSeries]
    let yAxis: MetricYAxis
    /// Number of samples visible at once (the sliding window width).
    let window: Int
    var height: CGFloat = 120
    var showLegend: Bool = true
    var maxRenderPoints: Int = 300

    @State private var selectedX: Int?

    var body: some View {
        let rendered = series.map {
            MetricSeries(id: $0.id, label: $0.label, color: $0.color,
                         points: MetricChartMath.downsample($0.points, maxCount: maxRenderPoints))
        }
        let allX = rendered.flatMap { $0.points.map(\.x) }
        let maxY = rendered.flatMap { $0.points.map(\.y) }.max() ?? 0
        let xDom = MetricChartMath.xDomain(minX: allX.min() ?? 0, maxX: allX.max() ?? (window - 1), window: window)
        let yDom = yDomain(maxY: maxY)

        Chart {
            ForEach(rendered) { s in
                ForEach(s.points) { p in
                    LineMark(x: .value("t", p.x), y: .value(s.label, p.y))
                        .foregroundStyle(by: .value("Series", s.label))
                        .interpolationMethod(.monotone)
                }
            }
            if let sx = selectedX, xDom.contains(sx) {
                RuleMark(x: .value("t", sx))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        readout(atX: sx, in: rendered)
                    }
            }
        }
        .chartXScale(domain: xDom)
        .chartYScale(domain: yDom)
        .chartForegroundStyleScale(domain: rendered.map(\.label), range: rendered.map(\.color))
        .chartLegend(showLegend ? .visible : .hidden)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                if let v = value.as(Double.self) {
                    AxisValueLabel { Text(axisLabel(v)).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .chartXSelection(value: $selectedX)
        .frame(height: height)
        .transaction { $0.animation = nil }   // no implicit animation on each 2 Hz redraw
    }

    // MARK: - Domain & labels

    private func yDomain(maxY: Double) -> ClosedRange<Double> {
        switch yAxis {
        case .percent:               return 0...100
        case .bytes:                 return MetricChartMath.yDomain(maxY: maxY, floor: 0)
        case .unbounded(let floor):  return MetricChartMath.yDomain(maxY: maxY, floor: floor)
        }
    }

    private func axisLabel(_ v: Double) -> String {
        switch yAxis {
        case .percent:      return "\(Int(v))%"
        case .unbounded:    return "\(Int(v))"
        case .bytes:        return Self.bytesLabel(v)
        }
    }

    static func bytesLabel(_ bytes: Double) -> String {
        let gb = 1_073_741_824.0, mb = 1_048_576.0
        if bytes >= gb { return String(format: "%.1f GB", bytes / gb) }
        return "\(Int(bytes / mb)) MB"
    }

    // MARK: - Hover readout

    @ViewBuilder
    private func readout(atX sx: Int, in rendered: [MetricSeries]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rendered) { s in
                if let idx = MetricChartMath.nearestIndex(s.points.map(\.x), toX: sx) {
                    HStack(spacing: 5) {
                        Circle().fill(s.color).frame(width: 6, height: 6)
                        Text(s.label).font(.caption2).foregroundStyle(.secondary)
                        Text(valueLabel(s.points[idx].y)).font(.caption2.monospacedDigit().weight(.semibold))
                    }
                }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func valueLabel(_ y: Double) -> String {
        switch yAxis {
        case .percent:   return "\(Int(y))%"
        case .unbounded: return "\(Int(y))%"
        case .bytes:     return Self.bytesLabel(y)
        }
    }
}

/// A minimal, axis-less line+area chart for embedding a trend behind a compact tile. Not wired into
/// the meter tiles by default — offered for callers that want an inline trend.
struct Sparkline: View {
    let points: [Double]
    let color: Color
    var height: CGFloat = 22
    var filled: Bool = true

    var body: some View {
        Chart(Array(points.enumerated()), id: \.offset) { i, y in
            LineMark(x: .value("i", i), y: .value("v", y))
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
            if filled {
                AreaMark(x: .value("i", i), y: .value("v", y))
                    .foregroundStyle(color.opacity(0.15))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: height)
        .transaction { $0.animation = nil }
    }
}
