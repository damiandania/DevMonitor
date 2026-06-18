import Foundation

// Tests the pure logic behind the activity table: SystemSampler.aggregate (dev/build identified
// rows + impact filtering) and SystemSampler.evaluatePressure (the stuck-machine state machine).

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

let GB = 1_073_741_824.0
let MB = 1_048_576.0

// --- aggregate ---
let rows = [
    ProcessRow(id: 100, name: "node", cpuPerCore: 50, memBytes: 200 * MB),     // dev member
    ProcessRow(id: 101, name: "esbuild", cpuPerCore: 30, memBytes: 100 * MB),  // dev member
    ProcessRow(id: 200, name: "node", cpuPerCore: 80, memBytes: 300 * MB),     // build member
    ProcessRow(id: 300, name: "Chrome", cpuPerCore: 90, memBytes: 2000 * MB),  // heavy other
    ProcessRow(id: 301, name: "idle", cpuPerCore: 1, memBytes: 10 * MB),       // light → filtered
]
let agg = SystemSampler.aggregate(
    rows: rows,
    dev: (pids: [100, 101], label: "MiddleSpace :3000"),
    build: (pids: [200], label: "Build · MiddleSpace"),
    coreCount: 8, totalMem: 8 * GB, topN: 40)

let devRow = agg.first { $0.id == -1 }
chk(devRow != nil && devRow!.isDevServer, "aggregate: dev row present + flagged")
chk(devRow?.cpuPerCore == 80, "aggregate: dev CPU summed (50+30)", "\(devRow?.cpuPerCore ?? -1)")
let buildRow = agg.first { $0.id == -2 }
chk(buildRow != nil && buildRow!.isBuild, "aggregate: build row identified like the server")
chk(buildRow?.cpuPerCore == 80, "aggregate: build CPU", "\(buildRow?.cpuPerCore ?? -1)")
chk(agg.contains { $0.id == 300 }, "aggregate: heavy other process shown")
chk(!agg.contains { $0.id == 301 }, "aggregate: light process filtered out")
chk(!agg.contains { [100, 101, 200].contains($0.id) }, "aggregate: tree members not double-listed")

let aggIdle = SystemSampler.aggregate(
    rows: [ProcessRow(id: 200, name: "node", cpuPerCore: 1, memBytes: 5 * MB)],
    dev: nil, build: (pids: [200], label: "Build · X"),
    coreCount: 8, totalMem: 8 * GB, topN: 40)
chk(aggIdle.contains { $0.id == -2 }, "aggregate: idle build still shown (always-on like server)")

// --- evaluatePressure ---
let S = 8.0
let G = 1_000_000_000 as UInt64
typealias SS = SystemSampler

var r = SS.evaluatePressure(cpu: 30, memPercent: 50, swapPercent: 10, hotSince: nil, now: 100*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .normal && !r.justStuck, "pressure: idle stays normal")

r = SS.evaluatePressure(cpu: 95, memPercent: 50, swapPercent: 10, hotSince: nil, now: 100*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .normal && r.hotSince == 100*G && !r.justStuck, "pressure: hot starts the clock")

r = SS.evaluatePressure(cpu: 95, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 109*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .stuck && r.justStuck && r.reason.contains("CPU"), "pressure: sustained CPU → stuck", r.reason)

r = SS.evaluatePressure(cpu: 40, memPercent: 95, swapPercent: 70, hotSince: 100*G, now: 110*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .stuck && r.reason.contains("Memory"), "pressure: sustained mem+swap → stuck", r.reason)

r = SS.evaluatePressure(cpu: 95, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 120*G, sustainSeconds: S, current: .stuck)
chk(r.pressure == .stuck && !r.justStuck, "pressure: stays stuck without re-triggering")

r = SS.evaluatePressure(cpu: 40, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 130*G, sustainSeconds: S, current: .stuck)
chk(r.pressure == .normal && r.hotSince == nil, "pressure: cools back to normal")

r = SS.evaluatePressure(cpu: 80, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 131*G, sustainSeconds: S, current: .stuck)
chk(r.pressure == .stuck && r.hotSince == 100*G, "pressure: hysteresis band holds state")

print(fail == 0 ? "ALL SAMPLER TESTS PASSED" : "SOME SAMPLER TESTS FAILED")
exit(Int32(fail))
