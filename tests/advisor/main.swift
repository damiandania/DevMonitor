import Foundation

// Headless tests for ResourceAdvisor's pure logic: snapshot rendering + tolerant JSON parsing.

var fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("PASS \(msg)") } else { print("FAIL \(msg)"); fail = 1 }
}

// --- snapshotText ---
let procs = [
    ResourceAdvisor.Proc(pid: -1, name: "MiddleSpace :3000", cpuPerCore: 140, memMB: 900, managedDev: true),
    ResourceAdvisor.Proc(pid: 4242, name: "Code Helper", cpuPerCore: 88, memMB: 1200, managedDev: false),
]
let snap = ResourceAdvisor.snapshotText(systemCPU: 75, systemMemPercent: 80, coreCount: 8, procs: procs)
check(snap.contains("System CPU: 75% of 8 cores"), "snapshot: system cpu line")
check(snap.contains("[DEV SERVER — managed by Dev Monitor]"), "snapshot: managed tag")
check(snap.contains("[foreign]"), "snapshot: foreign tag")
check(snap.contains("pid 4242"), "snapshot: foreign pid")

// --- parse: clean JSON ---
let names: [Int32: String] = [-1: "Dev server", 4242: "Code Helper"]
let clean = """
{"summary":"machine is busy","recommendations":[
  {"pid":-1,"action":"stop_dev_server","severity":"medium","reason":"idle server"},
  {"pid":4242,"action":"close_process","severity":"high","reason":"runaway helper"},
  {"pid":99,"action":"keep","severity":"low","reason":"fine"}
]}
"""
let r1 = ResourceAdvisor.parse(clean, names: names)
check(r1.summary == "machine is busy", "parse: summary")
check(r1.recs.count == 3, "parse: 3 recs")
// sorted by severity desc → high first
check(r1.recs.first?.action == .closeProcess, "parse: high severity first")
check(r1.recs.first?.severity == .high, "parse: severity high")
check(r1.recs.first?.name == "Code Helper", "parse: pid→name mapping")
let devRec = r1.recs.first { $0.id == -1 }
check(devRec?.action == .stopDevServer, "parse: stop_dev_server action")
check(devRec?.managed == true, "parse: dev rec is managed")
let foreign = r1.recs.first { $0.id == 4242 }
check(foreign?.managed == false, "parse: foreign rec not managed")

// --- parse: JSON wrapped in prose + code fence (tolerant extraction) ---
let messy = """
Here is my analysis:
```json
{"summary":"ok","recommendations":[{"pid":7,"action":"investigate","severity":"low","reason":"meh"}]}
```
Hope that helps!
"""
let r2 = ResourceAdvisor.parse(messy, names: [7: "node"])
check(r2.summary == "ok", "parse: extracts JSON from prose")
check(r2.recs.count == 1 && r2.recs.first?.action == .investigate, "parse: investigate action")
check(r2.recs.first?.name == "node", "parse: name fallback from map")

// --- parse: garbage → empty, no crash ---
let r3 = ResourceAdvisor.parse("totally not json", names: [:])
check(r3.recs.isEmpty, "parse: garbage yields no recs")

// --- heuristicKills: excludes protected + managed, ranks by impact, caps at 4 ---
let pool = [
    ResourceAdvisor.Proc(pid: -1, name: "MiddleSpace :3000", cpuPerCore: 200, memMB: 900, managedDev: true),
    ResourceAdvisor.Proc(pid: 10, name: "WindowServer", cpuPerCore: 150, memMB: 500, managedDev: false),
    ResourceAdvisor.Proc(pid: 11, name: "Visual Studio Code Helper", cpuPerCore: 120, memMB: 800, managedDev: false),
    ResourceAdvisor.Proc(pid: 12, name: "Google Chrome Helper", cpuPerCore: 90, memMB: 2000, managedDev: false),
    ResourceAdvisor.Proc(pid: 13, name: "node (orphan)", cpuPerCore: 60, memMB: 1500, managedDev: false),
    ResourceAdvisor.Proc(pid: 14, name: "some-daemon", cpuPerCore: 40, memMB: 300, managedDev: false),
    ResourceAdvisor.Proc(pid: 15, name: "another", cpuPerCore: 30, memMB: 200, managedDev: false),
]
let kills = ResourceAdvisor.heuristicKills(procs: pool)
let killIDs = Set(kills.map { $0.id })
check(!killIDs.contains(-1), "heuristic: excludes managed dev tree")
check(!killIDs.contains(10), "heuristic: excludes WindowServer")
check(!killIDs.contains(11), "heuristic: excludes editor (VS Code)")
check(kills.count <= 4, "heuristic: caps at 4")
check(kills.first?.id == 12, "heuristic: heaviest first (Chrome)")
check(kills.allSatisfy { $0.action == .closeProcess }, "heuristic: all close_process")

print(fail == 0 ? "ALL ADVISOR TESTS PASSED" : "SOME ADVISOR TESTS FAILED")
exit(Int32(fail))
