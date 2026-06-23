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

    /// SIGTERM a process *group*, then SIGKILL it after a short grace so a tree that ignores the
    /// polite signal is still reaped. Fire-and-forget; the escalation runs on a detached task.
    /// (The dev server and build both run as session leaders, so killing the group reaps the tree.)
    static func gracefulKillGroup(_ pgid: pid_t, after grace: Duration = .seconds(2)) {
        killpg(pgid, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: grace)
            killpg(pgid, SIGKILL)
        }
    }

    /// The Node heap flag (`--max-old-space-size=<MB>`) injected via `NODE_OPTIONS`. Centralizes the
    /// GB→MB conversion both runners use; only `NODE_OPTIONS`-allowlisted flags work here (V8 flags
    /// like `--optimize-for-size` are rejected and make node exit immediately).
    static func nodeHeapFlag(memoryGB: Int) -> String {
        "--max-old-space-size=\(memoryGB * 1024)"
    }
}
