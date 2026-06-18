import Foundation

setenv("SHELL_SESSIONS_DISABLE", "1", 1)
var fail = 0
func chk(_ l: String, _ c: Bool, _ d: String = "") {
    print((c ? "PASS " : "FAIL ") + l + (d.isEmpty ? "" : " — " + d)); if !c { fail += 1 }
}

// 1) per-process rusage for self
let me = getpid()
let s = dm_proc_stat_for(me)
chk("proc rusage valid", s.valid == 1 && s.cpu_time_ns > 0 && s.phys_footprint > 0,
    "cpu_ns=\(s.cpu_time_ns) mem=\(s.phys_footprint / 1_048_576)MB")

// 2) system cpu ticks → sane % across a busy interval
var t0 = dm_cpu_ticks(); _ = dm_system_cpu_ticks(&t0)
var acc = 0.0; for i in 0..<8_000_000 { acc += Double(i).squareRoot() }
var t1 = dm_cpu_ticks(); _ = dm_system_cpu_ticks(&t1)
let dTotal = Double(t1.total &- t0.total), dIdle = Double(t1.idle &- t0.idle)
let cpu = dTotal > 0 ? (1 - dIdle / dTotal) * 100 : -1
chk("system cpu% in 0...100", cpu >= 0 && cpu <= 100, String(format: "%.1f%% (acc=%.0f)", cpu, acc))

// 3) system memory
var m = dm_mem_info(); _ = dm_system_mem(&m)
chk("system mem sane", m.used > 0 && m.used < m.total && m.total > 1_000_000_000,
    "used=\(m.used / 1_048_576)MB / total=\(m.total / 1_048_576)MB")

// 3b) swap usage (total can be 0 if swap is disabled; used must never exceed total)
var sw = dm_mem_info(); let swrc = dm_system_swap(&sw)
chk("swap read ok", swrc == 0 && sw.used <= sw.total,
    "used=\(sw.used / 1_048_576)MB / total=\(sw.total / 1_048_576)MB")

// 4) load average
let la = dm_load_avg()
chk("load avg > 0", la > 0, "\(la)")

// 5) child enumeration on a spawned tree
var fd: Int32 = -1
// Force a real fork tree (two background children under the zsh leader).
let pid = dm_spawn_session("sleep 3 & sleep 3 & wait", "/tmp", &fd, nil)
usleep(500_000)
var kids = [pid_t](repeating: 0, count: 64)
let n = Int(dm_child_pids(pid, &kids, 64))
print("INFO leader=\(pid) children=\(n): \(Array(kids[0..<max(0, min(n, 8))]))")
chk("child enumeration finds children", n >= 1, "n=\(n)")
killpg(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0); close(fd)

print(fail == 0 ? "ALL METRICS TESTS PASSED" : "\(fail) METRICS TEST(S) FAILED")
exit(fail == 0 ? 0 : 1)
