import Foundation

/// One-time migration from the app's former identity — "Dev Monitor", the `dev-monitor` CLI and the
/// `app.devmonitor.*` bundle ids — to the current "Owl Monitor" / `owl-monitor` / `app.owlmonitor.*`.
///
/// v0.1.0 shipped under the old name, so an upgrading install has everything filed under it: projects,
/// settings and event history in `~/Library/Application Support/DevMonitor`, a `dev-monitor` in
/// `~/.local/bin`, and a Claude hook script named after the old app whose body tells other sessions to
/// run `dev-monitor`. Renaming without this would read as data loss (empty sidebar, settings back to
/// defaults) and would strand a CLI on PATH that can no longer reach the hub — the socket moved with
/// the support directory.
///
/// Every step is idempotent and best-effort: a fresh install finds nothing to do, and a failure on any
/// one item is logged and skipped rather than blocking launch. Safe to call on every launch.
///
/// `@MainActor` because it logs through `AppLog.shared` — and because its one caller is
/// `AppState.init()`, which is already on the main actor.
@MainActor
enum LegacyMigration {
    private static let oldSupportName = "DevMonitor"
    private static let newSupportName = "OwlMonitor"
    private static let oldCLIName = "dev-monitor"

    /// Application Support — overridable in tests so they never touch the real one.
    static var supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// Run every step. Call FIRST in `AppState.init()`'s body: the stores are built as property
    /// defaults, so by now the new support directory already exists and the old files must be merged
    /// in BEFORE the `load()` calls further down that body read them.
    static func run() {
        migrateSupportDirectory()
        migrateCLI()
        migrateClaudeHook()
    }

    // MARK: - Application Support

    private static func migrateSupportDirectory() {
        let old = supportDir.appendingPathComponent(oldSupportName, isDirectory: true)
        let new = supportDir.appendingPathComponent(newSupportName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        let adopted = merge(from: old, into: new)
        if adopted > 0 {
            AppLog.shared.event("Rename migration: adopted \(adopted) file(s) from the old "
                + "\(oldSupportName) folder")
        }
        pruneIfSpent(old)
    }

    /// Move everything under `src` to the matching place under `dst`, returning how many files moved.
    ///
    /// Recurses into directories present on BOTH sides instead of skipping them as already-there: by
    /// the time this runs the new folder can already have a `logs/` of its own, and treating that as
    /// one occupied slot would orphan every log file the old install had accumulated. A whole directory
    /// missing on the new side is still moved in one go.
    ///
    /// Never clobbers — a file already filed under the new name wins, so a user who ran the renamed app
    /// first keeps that state.
    @discardableResult
    private static func merge(from src: URL, into dst: URL) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: src.path) else { return 0 }
        var moved = 0
        for name in names where !isRuntimeJunk(name) {
            let from = src.appendingPathComponent(name)
            let to = dst.appendingPathComponent(name)
            if isDirectory(from), isDirectory(to) {
                moved += merge(from: from, into: to)
                continue
            }
            guard !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                moved += 1
            } catch {
                AppLog.shared.event("Rename migration: could not move \(name) — "
                    + "\(error.localizedDescription)")
            }
        }
        return moved
    }

    /// Drop the old folder once nothing of value is left, so later launches stop finding work to do.
    /// Directories emptied by the merge go first; the live socket may legitimately remain, and an old
    /// folder that lingers is harmless — the next launch tries again.
    private static func pruneIfSpent(_ old: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
            let entry = old.appendingPathComponent(name)
            if isDirectory(entry), (try? fm.contentsOfDirectory(atPath: entry.path))?.isEmpty == true {
                try? fm.removeItem(at: entry)
            }
        }
        if let left = try? fm.contentsOfDirectory(atPath: old.path), left.allSatisfy(isRuntimeJunk) {
            try? fm.removeItem(at: old)
        }
    }

    /// The hub's socket is live state bound to the old path, and `.DS_Store` is Finder's — neither is
    /// worth carrying over.
    private static func isRuntimeJunk(_ name: String) -> Bool {
        name.hasSuffix(".sock") || name == ".DS_Store"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: - CLI

    /// Retire `~/.local/bin/dev-monitor` and put `owl-monitor` in its place, so a user who had the CLI
    /// installed still has a working one — the old binary talks to a socket path that no longer exists.
    private static func migrateCLI() {
        let fm = FileManager.default
        let oldPath = CLIInstaller.installDir.appendingPathComponent(oldCLIName)
        guard fm.fileExists(atPath: oldPath.path) else { return }
        guard isOurs(oldPath) else {
            AppLog.shared.event("Rename migration: left ~/.local/bin/\(oldCLIName) in place — "
                + "it isn't one of ours")
            return
        }
        do {
            // Install the replacement BEFORE retiring the old one, so a failure here leaves the user
            // with the CLI they had rather than none at all.
            try CLIInstaller.install()
            try fm.removeItem(at: oldPath)
            AppLog.shared.event("Rename migration: installed owl-monitor and retired "
                + "~/.local/bin/\(oldCLIName)")
        } catch {
            AppLog.shared.event("Rename migration: could not swap the \(oldCLIName) CLI, leaving it in "
                + "place — \(error.localizedDescription)")
        }
    }

    /// Whether the old CLI on PATH is one we put there — the gate on deleting it, since a `dev-monitor`
    /// of the user's own must be left strictly alone. Exposed (not private) so the tests can cover both
    /// shapes directly.
    ///
    /// Two shapes exist in the wild and both have to be recognised: `CLIInstaller` symlinks into the
    /// app bundle, while `tools/install-local.sh` ditto-COPIES the binary. For a copy, the proof is the
    /// old hub socket path embedded in its string table — nothing else would carry it.
    static func isOurs(_ url: URL) -> Bool {
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return dest.hasSuffix("/Contents/MacOS/\(oldCLIName)")
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        let marker = Data("Library/Application Support/\(oldSupportName)/dm.sock".utf8)
        return data.range(of: marker) != nil
    }

    // MARK: - Claude Code hook

    /// Reinstall the hook so the script — and the CLI its block messages name — match this app.
    /// `install()` strips the retired entry as it writes the new one, so the two never coexist.
    private static func migrateClaudeHook() {
        guard ClaudeHookInstaller.hasRetiredHook else { return }
        do {
            try ClaudeHookInstaller.install()
            ClaudeHookInstaller.removeRetiredScripts()
            AppLog.shared.event("Rename migration: reinstalled the Claude Code hook under the new name")
        } catch {
            AppLog.shared.event("Rename migration: could not reinstall the Claude Code hook — "
                + "\(error.localizedDescription)")
        }
    }
}
