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

do { try ClaudeHookInstaller.uninstall() } catch { print("FAIL hook: uninstall threw — \(error)") ; fail += 1 }
chk(!ClaudeHookInstaller.isInstalled, "not installed after uninstall()")
chk(!FileManager.default.fileExists(atPath: ClaudeHookInstaller.scriptURL.path), "hook script removed")
let after2 = (try? String(contentsOf: ClaudeHookInstaller.settingsURL, encoding: .utf8)) ?? ""
chk(after2.contains("keep-me"), "unrelated hook preserved after uninstall")
chk(after2.contains("\"model\""), "unrelated key preserved after uninstall")

try? FileManager.default.removeItem(atPath: base)
print(fail == 0 ? "ALL HOOK TESTS PASSED" : "\(fail) HOOK TEST(S) FAILED")
exit(Int32(fail))
