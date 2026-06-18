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
chk(old.effectiveMemoryGB == 8, "model: auto memory follows framework default (nuxt = 8)", "\(old.effectiveMemoryGB)")

var manual = old
manual.memoryAuto = false
manual.memoryGB = 3
chk(manual.effectiveMemoryGB == 3, "model: manual memory uses memoryGB (3)", "\(manual.effectiveMemoryGB)")

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

print(fail == 0 ? "ALL MODEL TESTS PASSED" : "SOME MODEL TESTS FAILED")
exit(Int32(fail))
