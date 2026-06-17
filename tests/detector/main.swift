import Foundation

var failures = 0

func check(_ label: String, _ cond: Bool, _ detail: String) {
    print((cond ? "PASS " : "FAIL ") + label + " — " + detail)
    if !cond { failures += 1 }
}

// MiddleSpace: npm + Nuxt
let ms = Detector.detect(path: "/Users/damiandania/Metasense/MiddleSpace")
check("MiddleSpace",
      ms.packageManager == .npm && ms.framework == .nuxt && ms.devCommand == "npm run dev",
      "pm=\(ms.packageManager) fw=\(ms.framework) dev=\(ms.devCommand) build=\(ms.buildCommand ?? "nil")")

// A few ~/dev projects (best-effort; only assert if folder exists).
let cases: [(String, PackageManager?, Framework?)] = [
    ("/Users/damiandania/dev/AztecasFC", .pnpm, .nuxt),
    ("/Users/damiandania/dev/TokyBat", .npm, .next),
    ("/Users/damiandania/dev/Portfolio", .pnpm, .astro),
]
for (path, pm, fw) in cases {
    guard FileManager.default.fileExists(atPath: path + "/package.json") else {
        print("SKIP \(URL(fileURLWithPath: path).lastPathComponent) — no package.json")
        continue
    }
    let r = Detector.detect(path: path)
    let name = URL(fileURLWithPath: path).lastPathComponent
    let ok = (pm == nil || r.packageManager == pm) && (fw == nil || r.framework == fw)
    check(name, ok, "pm=\(r.packageManager) fw=\(r.framework) dev=\(r.devCommand)")
}

check("defaultMemoryGB Nuxt=8", Detector.defaultMemoryGB(for: .nuxt) == 8, "\(Detector.defaultMemoryGB(for: .nuxt))")

print(failures == 0 ? "ALL DETECTOR TESTS PASSED" : "\(failures) DETECTOR TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
