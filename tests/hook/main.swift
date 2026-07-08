import Foundation

// Tests ClaudeHookInstaller install/uninstall against a TEMP base dir (never the real ~/.claude):
// the hook is added/removed and the user's other settings keys + hooks are preserved.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

let base = NSTemporaryDirectory() + "dm-hook-\(ProcessInfo.processInfo.processIdentifier)"
try? FileManager.default.removeItem(atPath: base)
try? FileManager.default.createDirectory(atPath: base + "/.claude", withIntermediateDirectories: true)
ClaudeHookInstaller.baseDir = URL(fileURLWithPath: base)   // never touch the real ~/.claude

// Seed an unrelated top-level key + an unrelated PreToolUse hook that must survive install/uninstall.
let seed = #"{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo keep-me"}]}]}}"#
try? seed.write(toFile: base + "/.claude/settings.json", atomically: true, encoding: .utf8)

chk(!ClaudeHookInstaller.isInstalled, "not installed initially")

do { try ClaudeHookInstaller.install() } catch { print("FAIL hook: install threw — \(error)") ; fail += 1 }
chk(ClaudeHookInstaller.isInstalled, "installed after install()")
chk(FileManager.default.fileExists(atPath: ClaudeHookInstaller.scriptURL.path), "hook script written")
let after = (try? String(contentsOf: ClaudeHookInstaller.settingsURL, encoding: .utf8)) ?? ""
chk(after.contains("keep-me"), "preserves unrelated hook")
chk(after.contains("\"model\""), "preserves unrelated top-level key")
chk(after.contains(ClaudeHookInstaller.scriptName), "settings references our script")

// Behavioural coverage of the installed script itself: pipe a synthetic PreToolUse payload in and
// check the real exit code / stderr, so a regex change is caught even if it only breaks at runtime.
func runHook(_ command: String, cwd: String = "/tmp/proj") -> (exit: Int32, stderr: String) {
    let payload = try! JSONSerialization.data(withJSONObject: ["tool_input": ["command": command], "cwd": cwd])
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [ClaudeHookInstaller.scriptURL.path]
    let inPipe = Pipe(), errPipe = Pipe()
    proc.standardInput = inPipe
    proc.standardError = errPipe
    proc.standardOutput = Pipe()
    try? proc.run()
    inPipe.fileHandleForWriting.write(payload)
    inPipe.fileHandleForWriting.closeFile()
    proc.waitUntilExit()
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (proc.terminationStatus, err)
}

// PREVIEW_RE: a raw preview launch is blocked and routed to `dev-monitor preview`.
for cmd in ["npm run preview", "pnpm preview", "vite preview", "nuxt preview", "next start"] {
    let r = runHook(cmd)
    chk(r.exit == 2 && r.stderr.contains("dev-monitor preview '/tmp/proj'"),
        "hook: blocks preview launch — \(cmd)", "exit=\(r.exit) stderr=\(r.stderr)")
}
// Ambiguous bare `start` (e.g. create-react-app's dev server) is deliberately NOT blocked — only
// framework-specific, unambiguous preview commands are.
let bareStart = runHook("npm start")
chk(bareStart.exit == 0, "hook: bare 'npm start' is not treated as a preview", "exit=\(bareStart.exit)")
// Already-routed and inspection commands stay exempt from the new rule too.
let alreadyRouted = runHook("dev-monitor preview /tmp/proj")
chk(alreadyRouted.exit == 0, "hook: a dev-monitor command is never blocked", "exit=\(alreadyRouted.exit)")
let bareBuildCLI = runHook("dev-monitor build /tmp/proj")
chk(bareBuildCLI.exit == 0, "hook: a bare 'dev-monitor build' is never blocked", "exit=\(bareBuildCLI.exit)")
// Regression: a chained launch hiding behind a dev-monitor invocation must NOT slip through — the old
// blanket `grep dev-monitor` substring match whitelisted the whole command, so `dev-monitor stop X &&
// npm run build` ran unsupervised. It's now caught by BUILD_RE.
let chainedHole = runHook("dev-monitor stop /tmp/proj && npm run build")
chk(chainedHole.exit == 2 && chainedHole.stderr.contains("dev-monitor build '/tmp/proj'"),
    "hook: a launch chained after a dev-monitor command is still blocked",
    "exit=\(chainedHole.exit) stderr=\(chainedHole.stderr)")
// Hard block: DM_RAW=1 is no longer an escape hatch for launches — a build always routes through the
// app. (This is the exact bypass a runaway session used to run builds unsupervised.)
let dmRawBuild = runHook("DM_RAW=1 npm run build")
chk(dmRawBuild.exit == 2, "hook: DM_RAW=1 no longer bypasses a build launch", "exit=\(dmRawBuild.exit)")
let dmRawDev = runHook("DM_RAW=1 nuxt dev")
chk(dmRawDev.exit == 2, "hook: DM_RAW=1 no longer bypasses a dev launch", "exit=\(dmRawDev.exit)")
let inspecting = runHook("pgrep -fl 'vite preview'")
chk(inspecting.exit == 0, "hook: inspecting a preview command by name is not blocked", "exit=\(inspecting.exit)")
// Regression: DEV_RE/BUILD_RE still fire after adding PREVIEW_RE.
let devLaunch = runHook("npm run dev")
chk(devLaunch.exit == 2 && devLaunch.stderr.contains("dev-monitor up"),
    "hook: still blocks a dev launch", "exit=\(devLaunch.exit)")

do { try ClaudeHookInstaller.uninstall() } catch { print("FAIL hook: uninstall threw — \(error)") ; fail += 1 }
chk(!ClaudeHookInstaller.isInstalled, "not installed after uninstall()")
chk(!FileManager.default.fileExists(atPath: ClaudeHookInstaller.scriptURL.path), "hook script removed")
let after2 = (try? String(contentsOf: ClaudeHookInstaller.settingsURL, encoding: .utf8)) ?? ""
chk(after2.contains("keep-me"), "unrelated hook preserved after uninstall")
chk(after2.contains("\"model\""), "unrelated key preserved after uninstall")

try? FileManager.default.removeItem(atPath: base)
print(fail == 0 ? "ALL HOOK TESTS PASSED" : "\(fail) HOOK TEST(S) FAILED")
exit(Int32(fail))
