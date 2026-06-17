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
}
