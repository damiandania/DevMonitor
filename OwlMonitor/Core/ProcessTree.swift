import Foundation

/// Enumerates the process tree of a supervised dev server.
enum ProcessTree {
    /// All pids in the same session as `leader`. We spawn with `setsid` + `exec`, so the
    /// leader is a session leader and the whole tree shares its session id — robust to the
    /// re-parenting / process-group churn that shells like p10k/fnm introduce.
    static func sessionMembers(of leader: pid_t) -> [pid_t] {
        guard leader > 0 else { return [] }
        let sid = getsid(leader)
        guard sid > 0 else { return [leader] }
        var buffer = [pid_t](repeating: 0, count: 1024)
        let count = Int(dm_session_pids(sid, &buffer, 1024))
        return count > 0 ? Array(buffer[0..<count]) : [leader]
    }

    /// Every pid reachable from `leader`: the session members PLUS any descendant reachable by the
    /// parent→child (ppid) link. The ppid walk is what catches a child that called `setsid()` — that
    /// gives the child a NEW session and process group, so both `killpg` and `sessionMembers` miss
    /// it, but its parent pid is unchanged, so `proc_listchildpids` (via `dm_child_pids`) still finds
    /// it. Used by the tree-kill so a detached worker can't outlive the server that started it.
    static func fullTree(of leader: pid_t) -> [pid_t] {
        guard leader > 0 else { return [] }
        var seen = Set<pid_t>(sessionMembers(of: leader))
        seen.insert(leader)
        var frontier = Array(seen)
        var buf = [pid_t](repeating: 0, count: 256)
        while let p = frontier.popLast() {
            let n = Int(dm_child_pids(p, &buf, 256))
            for i in 0..<n where buf[i] > 1 && !seen.contains(buf[i]) {
                seen.insert(buf[i])
                frontier.append(buf[i])
            }
        }
        return Array(seen)
    }
}
