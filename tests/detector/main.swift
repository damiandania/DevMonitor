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

// isProject: only an existing folder with a package.json / deno config is launchable. This is the
// gate that stops `up /tmp` or `up /does/not/exist` from creating junk entries.
func tmpDir(_ name: String) -> String {
    let dir = NSTemporaryDirectory() + name
    try? FileManager.default.removeItem(atPath: dir)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
let pkgDir = tmpDir("dm-isproj-pkg"); try? "{}".write(toFile: pkgDir + "/package.json", atomically: true, encoding: .utf8)
let denoDir = tmpDir("dm-isproj-deno"); try? "{}".write(toFile: denoDir + "/deno.json", atomically: true, encoding: .utf8)
let bareDir = tmpDir("dm-isproj-bare")
check("isProject: package.json folder", Detector.isProject(path: pkgDir), pkgDir)
check("isProject: deno.json folder", Detector.isProject(path: denoDir), denoDir)
check("isProject: rejects empty folder", !Detector.isProject(path: bareDir), bareDir)
check("isProject: rejects missing path", !Detector.isProject(path: "/no/such/dm-path-xyz"), "missing")
check("isProject: rejects a plain file", !Detector.isProject(path: pkgDir + "/package.json"), "file, not dir")

// Package-manager detection by lockfile/config (temp dirs).
func tmpProject(_ files: [String: String]) -> String {
    let dir = NSTemporaryDirectory() + "dm-det-\(files.keys.sorted().joined().hashValue)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (f, c) in files { try? c.write(toFile: dir + "/" + f, atomically: true, encoding: .utf8) }
    return dir
}
check("detect bun", Detector.detect(path: tmpProject(["bun.lockb": "", "package.json": "{}"])).packageManager == .bun, "bun.lockb")
check("detect deno", Detector.detect(path: tmpProject(["deno.json": "{}"])).packageManager == .deno, "deno.json")
let denoCmd = Detector.commands(path: tmpProject(["deno.json": "{\"tasks\":{}}", "package.json": "{\"scripts\":{\"dev\":\"x\"}}"]), packageManager: .deno)
check("deno dev command", denoCmd.dev == "deno task dev", denoCmd.dev)

print(failures == 0 ? "ALL DETECTOR TESTS PASSED" : "\(failures) DETECTOR TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
