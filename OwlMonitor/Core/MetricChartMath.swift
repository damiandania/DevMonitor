import Foundation

/// Pure, headless-testable math behind the metric charts — no SwiftUI, no Charts, no run loop.
/// Same pattern as `SystemSampler.aggregate` / `evaluatePressure`: `nonisolated`, framework-free,
/// so it can be unit-tested with plain `swiftc`.
enum MetricChartMath {
    /// Append `point` to a ring buffer, dropping the oldest so it never exceeds `cap`.
    static func appendCapped<T>(_ buffer: inout [T], _ point: T, cap: Int) {
        buffer.append(point)
        if cap > 0, buffer.count > cap {
            buffer.removeFirst(buffer.count - cap)
        }
    }

    /// Round `value` UP to a "nice" 1/2/5×10ⁿ number, so a bytes/auto axis doesn't jitter as the
    /// live maximum drifts tick to tick. 0 (or negative) → 0.
    static func niceCeil(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let normalized = value / base            // in [1, 10)
        let nice: Double = normalized <= 1 ? 1 : (normalized <= 2 ? 2 : (normalized <= 5 ? 5 : 10))
        return nice * base
    }

    /// Y domain for a chart: `0 … max(floor, niceCeil(maxY × (1 + headroom)))`. `floor` keeps the
    /// axis from collapsing when the series is flat/low (e.g. per-core CPU pins the floor at 100).
    static func yDomain(maxY: Double, floor: Double, headroom: Double = 0.1) -> ClosedRange<Double> {
        let top = Swift.max(floor, niceCeil(maxY * (1 + headroom)))
        return 0...Swift.max(top, 1)
    }

    /// Sliding X window ending at `maxX` and spanning `window` points, but anchored to the left
    /// (`minX`) while the buffer is still shorter than the window. Never zero-width.
    static func xDomain(minX: Int, maxX: Int, window: Int) -> ClosedRange<Int> {
        let w = Swift.max(1, window)
        guard maxX > minX else {
            let lo = Swift.min(minX, maxX)
            return lo...(lo + w - 1)
        }
        let lo = Swift.max(minX, maxX - w + 1)
        return lo...Swift.max(lo + 1, maxX)
    }

    /// Uniform-stride downsample to at most `maxCount` points, always keeping the first and last.
    /// Returns the input untouched when it already fits (or `maxCount < 2`).
    static func downsample<T>(_ points: [T], maxCount: Int) -> [T] {
        guard maxCount >= 2, points.count > maxCount else { return points }
        let n = points.count
        let step = Double(n - 1) / Double(maxCount - 1)
        var out: [T] = []
        out.reserveCapacity(maxCount)
        for k in 0..<maxCount {
            let idx = Swift.min(n - 1, Int((Double(k) * step).rounded()))
            out.append(points[idx])
        }
        return out
    }

    /// Index of the point whose X value is nearest `toX`; nil for an empty series. Backs the
    /// hover readout (map the selected X back to the closest real sample).
    static func nearestIndex(_ xs: [Int], toX: Int) -> Int? {
        guard !xs.isEmpty else { return nil }
        var best = 0
        for i in 1..<xs.count where abs(xs[i] - toX) < abs(xs[best] - toX) { best = i }
        return best
    }
}
