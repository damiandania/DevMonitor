import Foundation

setenv("SHELL_SESSIONS_DISABLE", "1", 1)
var failures = 0

// 1) spawn + pipe capture + exit
do {
    var fd: Int32 = -1
    let pid = dm_spawn_session("echo DEVMON_OK; sleep 0.05; echo SECOND_LINE", "/tmp", &fd, nil)
    guard pid > 0, fd >= 0 else { print("FAIL spawn: pid=\(pid)"); exit(1) }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    close(fd)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    let text = String(data: out, encoding: .utf8) ?? ""
    let ok = text.contains("DEVMON_OK") && text.contains("SECOND_LINE")
    print(ok ? "PASS spawn/pipe capture" : "FAIL spawn/pipe — got: \(text.debugDescription)")
    if !ok { failures += 1 }
}

// 2) cwd is honored
do {
    var fd: Int32 = -1
    let pid = dm_spawn_session("pwd", "/usr", &fd, nil)
    var out = Data(); var buf = [UInt8](repeating: 0, count: 1024)
    while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
    close(fd); var s: Int32 = 0; waitpid(pid, &s, 0)
    let text = (String(data: out, encoding: .utf8) ?? "")
    let ok = text.contains("/usr")
    print(ok ? "PASS cwd honored" : "FAIL cwd — got: \(text.debugDescription)")
    if !ok { failures += 1 }
}

// 3) no Apple-Terminal session noise leaks through
do {
    var fd: Int32 = -1
    let pid = dm_spawn_session("echo CLEAN", "/tmp", &fd, nil)
    var out = Data(); var buf = [UInt8](repeating: 0, count: 1024)
    while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
    close(fd); var s: Int32 = 0; waitpid(pid, &s, 0)
    let text = String(data: out, encoding: .utf8) ?? ""
    let ok = text.contains("CLEAN") && !text.contains("Restored session") && !text.contains("Saving session")
    print(ok ? "PASS no shell noise" : "FAIL shell noise — got: \(text.debugDescription)")
    if !ok { failures += 1 }
}

// 4) killpg reaps the whole session quickly
do {
    var fd: Int32 = -1
    let pid = dm_spawn_session("sleep 30", "/tmp", &fd, nil)
    usleep(150_000)
    let rc = killpg(pid, SIGKILL)
    let t0 = Date()
    var s: Int32 = 0
    waitpid(pid, &s, 0)
    let dt = Date().timeIntervalSince(t0)
    close(fd)
    let ok = rc == 0 && dt < 2.0
    print(ok ? String(format: "PASS killpg reaped in %.2fs", dt) : "FAIL killpg — rc=\(rc) dt=\(dt)")
    if !ok { failures += 1 }
}

print(failures == 0 ? "ALL SPAWN TESTS PASSED" : "\(failures) SPAWN TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
