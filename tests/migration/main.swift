import Foundation

// Tests LegacyMigration against TEMP directories (never the real Application Support / ~/.local/bin).
//
// The cases that matter, because the first cut of this migration got all three wrong:
//   1. `logs/` exists on BOTH sides — the old install's log files must still be adopted, not skipped
//      as though the directory were one already-occupied slot.
//   2. The old CLI is a COPIED binary, not a symlink — `tools/install-local.sh` ditto-copies it, so a
//      symlink-only ownership check would leave a stale `dev-monitor` on PATH forever.
//   3. A `dev-monitor` the user rolled themselves must never be deleted.

var fail = 0
func chk(_ c: Bool, _ l: String, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

// Top-level code in a bare `swiftc` build is not main-actor isolated, but LegacyMigration is (it
// logs through AppLog.shared). Top-level code does run on the main thread, so assumeIsolated is
// both correct and the least noisy way in.
@MainActor
func runMigrationTests() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("om-migration-\(ProcessInfo.processInfo.processIdentifier)")
    try? fm.removeItem(at: root)

    let support = root.appendingPathComponent("Application Support", isDirectory: true)
    let old = support.appendingPathComponent("DevMonitor", isDirectory: true)
    let new = support.appendingPathComponent("OwlMonitor", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)

    func write(_ text: String, to url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    // ── Seed a pre-rename install ────────────────────────────────────────────────
    write(#"{"version":1,"data":[]}"#, to: old.appendingPathComponent("projects.json"))
    write("{\"e\":1}\n", to: old.appendingPathComponent("events.jsonl"))
    write("old dev log", to: old.appendingPathComponent("logs/alpha.log"))
    write("old api log", to: old.appendingPathComponent("logs/beta.log"))
    write("", to: old.appendingPathComponent("dm.sock"))   // live socket stand-in: must not travel

    // The new folder already exists WITH a logs/ of its own — exactly the state after the stores'
    // property-default initialisers have run and anything has logged once.
    write("new log", to: new.appendingPathComponent("logs/gamma.log"))
    // Something already filed under the new name must win over the old copy.
    write(#"{"version":1,"data":["kept"]}"#, to: new.appendingPathComponent("settings.json"))
    write("{}", to: old.appendingPathComponent("settings.json"))

    // ── Ownership predicate, both shapes ─────────────────────────────────────────
    let ourCopy = bin.appendingPathComponent("dev-monitor")
    write("MACHO-ish payload …Library/Application Support/DevMonitor/dm.sock… trailing", to: ourCopy)
    chk(LegacyMigration.isOurs(ourCopy), "a copied binary carrying the old socket path reads as ours")

    let foreign = root.appendingPathComponent("foreign/dev-monitor")
    write("someone else's tool, nothing to do with us", to: foreign)
    chk(!LegacyMigration.isOurs(foreign), "an unrelated dev-monitor does NOT read as ours")

    let ourLink = root.appendingPathComponent("link/dev-monitor")
    try? fm.createDirectory(at: ourLink.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(
        atPath: ourLink.path,
        withDestinationPath: "/Applications/Dev Monitor.app/Contents/MacOS/dev-monitor")
    chk(LegacyMigration.isOurs(ourLink), "a symlink into an app bundle reads as ours")

    // ── Run the migration against the temp tree ──────────────────────────────────
    LegacyMigration.supportDir = support
    CLIInstaller.installDir = bin
    ClaudeHookInstaller.baseDir = root      // no hook seeded ⇒ that step is a no-op
    LegacyMigration.run()

    // ── Support directory ────────────────────────────────────────────────────────
    chk(fm.fileExists(atPath: new.appendingPathComponent("projects.json").path),
        "projects.json adopted")
    chk(fm.fileExists(atPath: new.appendingPathComponent("events.jsonl").path),
        "events.jsonl adopted")
    chk(fm.fileExists(atPath: new.appendingPathComponent("logs/alpha.log").path),
        "old logs/ merged, not skipped (alpha)")
    chk(fm.fileExists(atPath: new.appendingPathComponent("logs/beta.log").path),
        "old logs/ merged, not skipped (beta)")
    chk(fm.fileExists(atPath: new.appendingPathComponent("logs/gamma.log").path),
        "pre-existing new log survives the merge")
    let settings = (try? String(contentsOf: new.appendingPathComponent("settings.json"),
                                encoding: .utf8)) ?? ""
    chk(settings.contains("kept"), "never clobbers a file already under the new name")
    chk(!fm.fileExists(atPath: new.appendingPathComponent("dm.sock").path),
        "the live socket is not carried over")

    // ── CLI safety ───────────────────────────────────────────────────────────────
    // There's no app bundle around a test binary, so CLIInstaller.install() cannot succeed here. That
    // exercises the ordering guarantee: the replacement goes in FIRST, so a failure must leave the CLI the
    // user already had rather than deleting it and installing nothing.
    chk(fm.fileExists(atPath: ourCopy.path),
        "a failed install leaves the old CLI in place instead of stranding the user with none")

    // ── Idempotence: a second run must be a harmless no-op ───────────────────────
    LegacyMigration.run()
    chk(settings == ((try? String(contentsOf: new.appendingPathComponent("settings.json"),
                                  encoding: .utf8)) ?? ""),
        "second run changes nothing")
    chk(fm.fileExists(atPath: new.appendingPathComponent("logs/alpha.log").path),
        "second run leaves adopted files alone")

    try? fm.removeItem(at: root)
}

MainActor.assumeIsolated { runMigrationTests() }
print(fail == 0 ? "ALL MIGRATION TESTS PASSED" : "\(fail) MIGRATION TEST(S) FAILED")
exit(fail == 0 ? 0 : 1)
