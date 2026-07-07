import Foundation

// Tests the pure math behind the metric charts: MetricChartMath (ring buffer, nice-ceil axis,
// Y/X domains, downsample, nearest). No SwiftUI/Charts — headless.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

// --- appendCapped ---
var buf: [Int] = []
for i in 1...5 { MetricChartMath.appendCapped(&buf, i, cap: 3) }
chk(buf == [3, 4, 5], "appendCapped: keeps last `cap`, drops oldest", "\(buf)")
var buf2: [Int] = []
MetricChartMath.appendCapped(&buf2, 1, cap: 3)
chk(buf2 == [1], "appendCapped: under cap keeps all", "\(buf2)")
var buf3 = [1, 2, 3]
MetricChartMath.appendCapped(&buf3, 4, cap: 0)   // cap 0 = unbounded guard
chk(buf3 == [1, 2, 3, 4], "appendCapped: cap<=0 never trims", "\(buf3)")

// --- niceCeil ---
chk(MetricChartMath.niceCeil(0) == 0, "niceCeil: 0 → 0")
chk(MetricChartMath.niceCeil(-5) == 0, "niceCeil: negative → 0")
chk(MetricChartMath.niceCeil(1) == 1, "niceCeil: 1 → 1")
chk(MetricChartMath.niceCeil(1.5) == 2, "niceCeil: 1.5 → 2", "\(MetricChartMath.niceCeil(1.5))")
chk(MetricChartMath.niceCeil(3) == 5, "niceCeil: 3 → 5", "\(MetricChartMath.niceCeil(3))")
chk(MetricChartMath.niceCeil(7) == 10, "niceCeil: 7 → 10", "\(MetricChartMath.niceCeil(7))")
chk(MetricChartMath.niceCeil(230) == 500, "niceCeil: 230 → 500", "\(MetricChartMath.niceCeil(230))")
chk(MetricChartMath.niceCeil(1_600_000_000) == 2_000_000_000, "niceCeil: 1.6 GB → 2 GB",
    "\(MetricChartMath.niceCeil(1_600_000_000))")

// --- yDomain ---
let dPct = MetricChartMath.yDomain(maxY: 42, floor: 100)
chk(dPct == 0...100, "yDomain: floor 100 holds for a low % series", "\(dPct)")
let dAuto = MetricChartMath.yDomain(maxY: 230, floor: 0)
chk(dAuto.lowerBound == 0 && dAuto.upperBound >= 253, "yDomain: auto adds headroom then nice-ceils", "\(dAuto)")
let dFlat = MetricChartMath.yDomain(maxY: 0, floor: 0)
chk(dFlat == 0...1, "yDomain: all-zero series never collapses to 0...0", "\(dFlat)")
let dCore = MetricChartMath.yDomain(maxY: 380, floor: 100)
chk(dCore.upperBound >= 418, "yDomain: per-core CPU >100 scales past the floor", "\(dCore)")

// --- xDomain ---
let xPartial = MetricChartMath.xDomain(minX: 0, maxX: 40, window: 300)
chk(xPartial == 0...40, "xDomain: partial buffer anchors left", "\(xPartial)")
let xFull = MetricChartMath.xDomain(minX: 0, maxX: 500, window: 300)
chk(xFull == 201...500, "xDomain: full buffer slides to the last window", "\(xFull)")
let xOne = MetricChartMath.xDomain(minX: 7, maxX: 7, window: 300)
chk(xOne.lowerBound == 7 && xOne.upperBound == 7 + 299, "xDomain: single point → full window width, no zero span", "\(xOne)")

// --- downsample ---
let small = Array(0..<10)
chk(MetricChartMath.downsample(small, maxCount: 50) == small, "downsample: under budget returns input")
let big = Array(0..<1000)
let ds = MetricChartMath.downsample(big, maxCount: 100)
chk(ds.count == 100, "downsample: caps at maxCount", "\(ds.count)")
chk(ds.first == 0 && ds.last == 999, "downsample: always keeps first + last", "\(ds.first ?? -1)/\(ds.last ?? -1)")
chk(zip(ds, ds.dropFirst()).allSatisfy { $0 <= $1 }, "downsample: preserves order (monotonic)")

// --- nearestIndex ---
chk(MetricChartMath.nearestIndex([], toX: 3) == nil, "nearestIndex: empty → nil")
chk(MetricChartMath.nearestIndex([5], toX: 3) == 0, "nearestIndex: single → 0")
chk(MetricChartMath.nearestIndex([0, 10, 20, 30], toX: 22) == 2, "nearestIndex: picks closest",
    "\(String(describing: MetricChartMath.nearestIndex([0, 10, 20, 30], toX: 22)))")
chk(MetricChartMath.nearestIndex([0, 10, 20], toX: 100) == 2, "nearestIndex: beyond end clamps to last")

print(fail == 0 ? "ALL CHARTS TESTS PASSED" : "\(fail) CHARTS TEST(S) FAILED")
exit(Int32(fail))
