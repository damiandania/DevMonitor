import Foundation

// Tests the Project model: backward-compatible decoding (older projects.json without the auto
// flags), the effective-memory rule, and an encode→decode round trip.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

let dec = JSONDecoder()

// Old JSON: no memoryAuto / packageManagerAuto / port → must default to auto.
let oldJSON = """
{"id":"\(UUID().uuidString)","name":"Old","path":"/tmp/x","packageManager":"npm","framework":"nuxt","memoryGB":8}
""".data(using: .utf8)!

guard let old = try? dec.decode(Project.self, from: oldJSON) else {
    print("FAIL model: legacy JSON failed to decode"); exit(1)
}
chk(old.memoryAuto, "model: missing memoryAuto defaults to true")
chk(old.packageManagerAuto, "model: missing packageManagerAuto defaults to true")
chk(old.port == nil, "model: missing port = nil (auto)")

// Round trip preserves the new fields.
let p = Project(name: "RT", path: "/tmp/y", packageManager: .pnpm, framework: .astro,
                memoryGB: 5, memoryAuto: false, port: 4321, packageManagerAuto: false)
guard let data = try? JSONEncoder().encode(p),
      let back = try? dec.decode(Project.self, from: data) else {
    print("FAIL model: round-trip encode/decode failed"); exit(1)
}
chk(back.memoryAuto == false && back.packageManagerAuto == false
    && back.port == 4321 && back.memoryGB == 5,
    "model: round-trip preserves flags / port / memory")

// Effective heap — the deterministic rule behind the OOM fix:
//   auto  → framework default (NOT the stored memoryGB, which may be a stale low value)
//   manual → the explicit memoryGB, floored at minHeapGB
//   always capped at physical RAM.
let nuxtAuto = Project(name: "n", path: "/tmp/n", framework: .nuxt, memoryGB: 1, memoryAuto: true)
chk(nuxtAuto.effectiveMemoryGB(systemGB: 64) == HeapScaling.firstGB,
    "effective: auto starts at firstGB, ignores stale memoryGB=1", "\(nuxtAuto.effectiveMemoryGB(systemGB: 64))")
let nodeAuto = Project(name: "x", path: "/tmp/x", framework: .node, memoryAuto: true)
chk(nodeAuto.effectiveMemoryGB(systemGB: 64) == HeapScaling.firstGB, "effective: auto node → firstGB")
let manual = Project(name: "m", path: "/tmp/m", framework: .nuxt, memoryGB: 6, memoryAuto: false)
chk(manual.effectiveMemoryGB(systemGB: 64) == 6, "effective: manual respects memoryGB=6")
let lowManual = Project(name: "l", path: "/tmp/l", framework: .node, memoryGB: 1, memoryAuto: false)
chk(lowManual.effectiveMemoryGB(systemGB: 64) == Project.minHeapGB, "effective: manual floored at minHeapGB")
chk(nuxtAuto.effectiveMemoryGB(systemGB: 4) == 4, "effective: capped at system RAM (4)")

// Per-project log path: stable, ends in .log, unique per id.
let lp1 = Project(name: "Foo Bar", path: "/tmp/a", framework: .node)
let lp2 = Project(name: "Foo Bar", path: "/tmp/b", framework: .node)
chk(lp1.logFileURL.lastPathComponent.hasSuffix(".log"), "log: ends in .log", lp1.logFileURL.lastPathComponent)
chk(lp1.logFileURL == lp1.logFileURL, "log: stable for a project")
chk(lp1.logFileURL != lp2.logFileURL, "log: distinct per project (different id)")

// AppSettings: empty JSON → defaults; round trip preserves values.
guard let defs = try? dec.decode(AppSettings.self, from: "{}".data(using: .utf8)!) else {
    print("FAIL model: AppSettings '{}' failed to decode"); exit(1)
}
chk(defs.browser == nil, "settings: default browser = system default (nil)")
chk(defs.analysisModel == AppSettings.defaultModel, "settings: default model = haiku", defs.analysisModel)
chk(defs.autoCloseOrphans, "settings: auto-close orphans on by default")
chk(defs.defaultMemoryGB == 4, "settings: default heap 4")
chk(defs.editor == nil, "settings: default editor = first found (nil)")
chk(defs.bars == AppSettings.defaultBars, "settings: default bars = cpu/memory/swap")
chk(defs.notificationsEnabled, "settings: notifications enabled by default")
chk(defs.notifyFailures && defs.notifyRecovery && defs.notifyBuilds && defs.notifyPressure,
    "settings: all notification categories on by default")

let custom = AppSettings(browser: "Firefox", analysisModel: "claude-opus-4-8",
                         autoCloseOrphans: false, defaultMemoryGB: 8,
                         notificationsEnabled: false, notifyFailures: false, notifyPressure: false)
guard let sData = try? JSONEncoder().encode(custom),
      let sBack = try? dec.decode(AppSettings.self, from: sData) else {
    print("FAIL model: AppSettings round-trip failed"); exit(1)
}
chk(sBack == custom, "settings: round-trip preserves all fields")

print(fail == 0 ? "ALL MODEL TESTS PASSED" : "SOME MODEL TESTS FAILED")
exit(Int32(fail))
