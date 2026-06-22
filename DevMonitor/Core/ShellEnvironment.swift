import Foundation
import Darwin

/// Resolves the user's real shell PATH — the way editors like VS Code do — and exports it into this
/// process so the dev servers we spawn can find Node/npm.
///
/// WHY THIS EXISTS: a GUI app launched by launchd/Finder inherits a minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`) that lacks Homebrew and — critically — Node version managers
/// (fnm, nvm, asdf), whose shims are installed by the user's *interactive* rc file (e.g. `~/.zshrc`).
/// `dm_spawn_session` runs `/bin/zsh -lc` (login, NON-interactive — on purpose, to keep p10k /
/// session-restore noise out of the dev-server log), which sources `~/.zprofile` but NOT `~/.zshrc`.
/// So on a machine where fnm lives in `~/.zshrc`, the spawned server gets `npm: command not found`
/// (exit 127).
///
/// FIX: once, off the spawn path, run a login+INTERACTIVE shell (which DOES source `~/.zshrc`) to
/// print `$PATH`, and export that into our own environment. The spawned shell stays non-interactive
/// (quiet), but now inherits a PATH that already contains the Node shims.
///
/// WHY RESOLVE FRESH (short TTL) RATHER THAN ONCE AT STARTUP: fnm puts a PER-SHELL, ephemeral
/// directory on PATH (`~/.local/state/fnm_multishells/<pid>_<ts>/bin`) and garbage-collects it once
/// the owning shell is gone. A PATH captured at app startup therefore goes stale within minutes (its
/// multishell dir is reaped) → the next relaunch fails with 127 again. Resolving shortly before each
/// (re)launch yields a live multishell dir that stays valid for the few seconds the server needs to
/// boot. The short TTL keeps a burst of crash auto-restarts from re-running a shell every time.
@MainActor
enum ShellEnvironment {
    private static let startMarker = "__DM_PATH_START__"
    private static let endMarker = "__DM_PATH_END__"
    private static let ttl: TimeInterval = 30

    private static var cached: (path: String, at: Date)?

    /// Resolve the user's login+interactive PATH and export it into this process so any child spawned
    /// afterwards (the dev server, via `dm_spawn_session`, which inherits the process environment) can
    /// find node/npm. Cached for a short TTL so a burst of crash auto-restarts doesn't re-run a shell
    /// each time. No-op (keeps the last good / inherited PATH) on failure. Returns the PATH now in
    /// effect, if any.
    @discardableResult
    static func applyResolvedPATH() -> String? {
        if let c = cached, Date().timeIntervalSince(c.at) < ttl {
            setenv("PATH", c.path, 1)
            return c.path
        }
        guard let fresh = resolveLoginPATH() else {
            // Resolution failed — keep the last good value if we have one (still better than the
            // bare launchd PATH); otherwise leave the inherited PATH untouched.
            if let c = cached { setenv("PATH", c.path, 1); return c.path }
            return nil
        }
        cached = (fresh, Date())
        setenv("PATH", fresh, 1)
        return fresh
    }

    /// Run the user's login+interactive shell to print its `$PATH`. Returns nil on any failure.
    /// Bounded by `timeout` so a slow/hanging rc file (p10k, networked mounts) can never block a
    /// launch indefinitely.
    static func resolveLoginPATH(timeout: TimeInterval = 4) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // -i -l -c: a login+interactive shell sources the rc file where fnm/nvm/asdf install their
        // hooks. The sentinels bracket the value so any prompt/instant-prompt noise printed on stdout
        // during startup is stripped reliably.
        proc.arguments = ["-ilc", "printf '%s%s%s' '\(startMarker)' \"$PATH\" '\(endMarker)'"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return nil }

        // Read on a background queue, capturing ONLY the raw file descriptor (Int32 — Sendable),
        // never the Pipe/FileHandle (which Swift 6 strict concurrency forbids in a @Sendable closure),
        // and bound the wait so a slow rc file (or a lingering p10k daemon that keeps the pipe open)
        // can never block the caller. On timeout we SIGKILL the shell and bail with nil rather than
        // read `captured` while the background reader may still be touching it.
        let readFD = outPipe.fileHandleForReading.fileDescriptor
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var captured = Data()
        DispatchQueue.global().async {
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = read(readFD, &buf, buf.count)
                if n <= 0 { break }
                captured.append(contentsOf: buf[0..<n])
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            kill(proc.processIdentifier, SIGKILL)
            proc.waitUntilExit()
            return nil
        }
        proc.waitUntilExit()

        guard let out = String(data: captured, encoding: .utf8),
              let lo = out.range(of: startMarker),
              let hi = out.range(of: endMarker, range: lo.upperBound..<out.endIndex) else { return nil }
        let path = String(out[lo.upperBound..<hi.lowerBound])
        return path.isEmpty ? nil : path
    }
}
