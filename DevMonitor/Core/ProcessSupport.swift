import Foundation
import Darwin

/// Small process-control primitives shared by the dev-server supervisor (`DevSession`) and the
/// one-shot build runner (`BuildRunner`), so the two don't reimplement the same POSIX glue.
enum ProcessSupport {

    /// Decode a `waitpid` status into an exit code, the way both runners need it: a normal exit
    /// (`WIFEXITED`) yields its `WEXITSTATUS`; a signal-terminated process yields the raw status
    /// (a non-zero value that callers treat as "failed"). Replaces the duplicated bit-twiddling.
    static func decodeExitCode(_ status: Int32) -> Int32 {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : status
    }

    /// SIGTERM the whole tree of session leader `leader` — its session members AND any `setsid`
    /// descendants (which escape a plain `killpg`) — then SIGKILL after a short grace so a tree that
    /// ignores the polite signal is still reaped. Fire-and-forget; the escalation runs on a detached
    /// task and re-enumerates so a child spawned during the grace is still caught. Replaces the old
    /// killpg-only path so a detached worker can't outlive the server/build that started it.
    static func gracefulKillTree(_ leader: pid_t, after grace: Duration = .seconds(2)) {
        signalTree(ProcessTree.fullTree(of: leader), SIGTERM)
        Task.detached {
            try? await Task.sleep(for: grace)
            signalTree(ProcessTree.fullTree(of: leader), SIGKILL)
        }
    }

    /// Send `sig` to every pid in `pids` and to each one's process group (so a new group created by a
    /// `setsid` child is reaped too). Pids ≤ 1 are skipped. Shared by the tree-kill and app shutdown.
    static func signalTree(_ pids: [pid_t], _ sig: Int32) {
        for p in Set(pids) where p > 1 {
            kill(p, sig)
            let pg = getpgid(p)
            if pg > 1 { killpg(pg, sig) }
        }
    }

    /// The Node heap flag (`--max-old-space-size=<MB>`) injected via `NODE_OPTIONS`. Centralizes the
    /// GB→MB conversion both runners use; only `NODE_OPTIONS`-allowlisted flags work here (V8 flags
    /// like `--optimize-for-size` are rejected and make node exit immediately).
    static func nodeHeapFlag(memoryGB: Int) -> String {
        "--max-old-space-size=\(memoryGB * 1024)"
    }
}
