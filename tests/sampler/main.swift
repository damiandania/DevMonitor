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
    devs: [(id: -1, pids: [100, 101], label: "MiddleSpace :3000")],
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
    devs: [], build: (pids: [200], label: "Build · X"),
    coreCount: 8, totalMem: 8 * GB, topN: 40)
chk(aggIdle.contains { $0.id == -2 }, "aggregate: idle build still shown (always-on like server)")

// Workers: one identified row per worker, tree summed, members not double-listed.
let aggWorker = SystemSampler.aggregate(
    rows: [
        ProcessRow(id: 400, name: "node", cpuPerCore: 20, memBytes: 150 * MB),
        ProcessRow(id: 401, name: "tsx", cpuPerCore: 15, memBytes: 50 * MB),
    ],
    devs: [], build: nil,
    workers: [(id: -4, pids: [400, 401], label: "MiddleSpace · worker")],
    coreCount: 8, totalMem: 8 * GB, topN: 40)
let workerRow = aggWorker.first { $0.id == -4 }
chk(workerRow != nil && workerRow!.isWorker, "aggregate: worker row present + flagged")
chk(workerRow?.cpuPerCore == 35, "aggregate: worker CPU summed (20+15)", "\(workerRow?.cpuPerCore ?? -1)")
chk(workerRow?.memBytes == 200 * MB, "aggregate: worker mem summed", "\(workerRow?.memBytes ?? -1)")
chk(!aggWorker.contains { $0.id == 400 || $0.id == 401 }, "aggregate: worker members not double-listed")

// A supervised dev row is ALWAYS shown, even when its tree has no live stats this tick.
let aggGhost = SystemSampler.aggregate(
    rows: [], devs: [(id: -7, pids: [999], label: "ghost :3000")], build: nil,
    coreCount: 8, totalMem: 8 * GB, topN: 40)
chk(aggGhost.contains { $0.id == -7 && $0.cpuPerCore == 0 }, "aggregate: idle dev still shown at 0")

// topN caps only the unsupervised tail; supervised rows always survive the cap.
let manyHeavy = (0..<6).map { ProcessRow(id: Int32(500 + $0), name: "hog\($0)", cpuPerCore: 100, memBytes: GB) }
let aggCap = SystemSampler.aggregate(
    rows: manyHeavy, devs: [(id: -1, pids: [], label: "dev")], build: nil,
    coreCount: 8, totalMem: 8 * GB, topN: 3)
chk(aggCap.filter { $0.id >= 500 }.count == 3, "aggregate: others capped at topN", "\(aggCap.count) rows")
chk(aggCap.contains { $0.id == -1 }, "aggregate: supervised row survives the cap")

// Others rank by impact (CPU share + mem share): a 4 GB idle process outweighs a 40%-CPU one.
let aggRank = SystemSampler.aggregate(
    rows: [
        ProcessRow(id: 600, name: "midcpu", cpuPerCore: 40, memBytes: 10 * MB),
        ProcessRow(id: 601, name: "bigmem", cpuPerCore: 0, memBytes: 4 * GB),
    ],
    devs: [], build: nil, coreCount: 8, totalMem: 8 * GB, topN: 40)
chk((aggRank.firstIndex { $0.id == 601 } ?? 99) < (aggRank.firstIndex { $0.id == 600 } ?? -1),
    "aggregate: ranked by impact, heaviest first")

// totalMem = 0 (metrics read failed) must not crash the impact math; CPU-heavy rows still surface.
let aggZero = SystemSampler.aggregate(
    rows: [ProcessRow(id: 700, name: "busy", cpuPerCore: 90, memBytes: 100 * MB)],
    devs: [], build: nil, coreCount: 8, totalMem: 0, topN: 40)
chk(aggZero.contains { $0.id == 700 }, "aggregate: totalMem=0 guarded")

// --- projectName(fromArgs:) — external dev-server labelling ---
chk(SystemSampler.projectName(fromArgs: "node /Users/x/Dev/MiddleSpace/node_modules/.bin/nuxt dev") == "MiddleSpace",
    "projectName: folder before node_modules")
chk(SystemSampler.projectName(fromArgs: "node dist/server.js") == nil, "projectName: no node_modules → nil")
chk(SystemSampler.projectName(fromArgs: "/node_modules/.bin/vite") == nil, "projectName: root node_modules → nil")
chk(SystemSampler.projectName(fromArgs: "/w/App/node_modules/foo/node_modules/.bin/x") == "App",
    "projectName: first node_modules wins")

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

r = SS.evaluatePressure(cpu: 95, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 105*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .normal && r.hotSince == 100*G && !r.justStuck, "pressure: hot but not yet sustained stays normal")

r = SS.evaluatePressure(cpu: 95, memPercent: 50, swapPercent: 10, hotSince: 100*G, now: 108*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .stuck && r.justStuck, "pressure: exact sustain boundary trips")

r = SS.evaluatePressure(cpu: 40, memPercent: 95, swapPercent: 20, hotSince: nil, now: 100*G, sustainSeconds: S, current: .normal)
chk(r.pressure == .normal && r.hotSince == nil, "pressure: full memory WITHOUT swap is not hot")

// --- live off-main sampling (the async collect pass) ---
// Rows + system stats materialize, a supervised leader resolves to its own row via the single
// sid-grouping sweep (this process is the leader), and a dead leader drops out instead of crashing.
let live = SystemSampler()
live.devServerInfo = { [(id: -900, leader: getpid(), label: "suite"),
                        (id: -901, leader: 3_999_999, label: "dead")] }
live.start()
try? await Task.sleep(for: .seconds(5))   // ≥2 ticks at 2 s
chk(!live.processes.isEmpty, "live: processes populated", "\(live.processes.count) rows")
chk(live.systemMemUsed > 0 && live.totalMem > 0, "live: memory sampled",
    "\(Int(live.systemMemUsed / MB))MB")
chk(live.systemCPU >= 0 && live.systemCPU <= 100, "live: CPU% in range", "\(live.systemCPU)")
chk(live.loadAverage > 0, "live: load average sampled", "\(live.loadAverage)")
let liveDev = live.processes.first { $0.id == -900 }
chk(liveDev != nil && liveDev!.isDevServer && liveDev!.name == "suite",
    "live: supervised row resolved from leader via sid grouping", liveDev?.name ?? "missing")
chk(liveDev.map { $0.memBytes > 0 } ?? false, "live: supervised tree stats non-zero")
chk(!live.processes.contains { $0.id == -901 }, "live: dead leader dropped")

print(fail == 0 ? "ALL SAMPLER TESTS PASSED" : "SOME SAMPLER TESTS FAILED")
exit(Int32(fail))
