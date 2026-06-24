import Foundation

@MainActor
func runSessionTests() async -> Int {
    var failures = 0
    func check(_ label: String, _ cond: Bool, _ detail: String = "") {
        print((cond ? "PASS " : "FAIL ") + label + (detail.isEmpty ? "" : " — " + detail))
        if !cond { failures += 1 }
    }

    // Real HTTP server so warm-up → running (via the first HTTP probe) is exercised —
    // this is the regression test for the recycle-during-warm-up loop.
    let project = Project(
        name: "fake", path: "/tmp",
        devCommand: "node -e 'require(\"http\").createServer((q,r)=>r.end(\"ok\")).listen(4321,\"127.0.0.1\",()=>console.log(\"Local: http://localhost:4321/\"))'",
        memoryGB: 2
    )
    let session = DevSession(project: project)
    session.start(memoryGB: 2)

    try? await Task.sleep(for: .seconds(5))

    check("port parsed", session.detectedPort == 4321, "port=\(String(describing: session.detectedPort))")
    let running: Bool = { if case .running = session.state { return true }; return false }()
    check("reached running via HTTP", running, "state=\(session.state.label)")
    check("isReady true once running", session.isReady, "ready=\(session.isReady)")
    check("url reported", session.url == "http://localhost:4321/", "url=\(session.url ?? "nil")")
    check("no lastError while healthy", session.lastError == nil, "err=\(session.lastError ?? "nil")")
    check("log captured", session.logLines.contains { $0.contains("4321") })
    check("NODE_OPTIONS injected", session.logLines.contains { $0.contains("max-old-space-size=2048") })
    check("no shell noise in log", !session.logLines.contains { $0.contains("Restored session") })

    // Stop should kill the tree; state becomes stopped/failed shortly after.
    session.stop()
    try? await Task.sleep(for: .seconds(3))
    let stopped: Bool = { switch session.state { case .stopped, .failed: return true; default: return false } }()
    check("stopped after stop()", stopped, "state=\(session.state.label)")
    check("isReady false after stop", !session.isReady, "ready=\(session.isReady)")

    // Failure diagnostics (agent-operability): a server that exits non-zero records the exit code and
    // a human-readable lastError, so `status --json` can diagnose without reading internal files.
    let failProj = Project(name: "failx", path: "/tmp",
        devCommand: "sh -c 'echo starting; exit 5'", memoryGB: 2)
    let failSession = DevSession(project: failProj)
    failSession.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(3))
    let didFail: Bool = { if case .failed = failSession.state { return true }; return false }()
    check("fail: reached Failed", didFail, "state=\(failSession.state.label)")
    check("fail: exitCode recorded", failSession.lastExitCode == 5, "code=\(String(describing: failSession.lastExitCode))")
    check("fail: lastError mentions code", (failSession.lastError ?? "").contains("code 5"), "err=\(failSession.lastError ?? "nil")")

    // Crash auto-revive: a server that WAS healthy then has its process killed externally must
    // relaunch itself (bounded backoff), not stay dead. Regression test for the #10 auto-revive.
    let reviveProj = Project(name: "revive", path: "/tmp",
        devCommand: "node -e 'require(\"http\").createServer((q,r)=>r.end(\"ok\")).listen(4322,\"127.0.0.1\",()=>console.log(\"Local: http://localhost:4322/\"))'",
        memoryGB: 2)
    let reviveSession = DevSession(project: reviveProj)
    reviveSession.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(4))      // let it become healthy
    let healthyPid = reviveSession.pid
    check("revive: ready before kill", reviveSession.isReady, "state=\(reviveSession.state.label)")
    kill(healthyPid, SIGKILL)                    // simulate an external crash of the dev process
    try? await Task.sleep(for: .seconds(6))      // exit + backoff (~1s) + relaunch + warm-up
    let revivedActive = reviveSession.state.isActive
    let revivedPid = reviveSession.pid
    check("revive: active again after external kill", revivedActive, "state=\(reviveSession.state.label)")
    check("revive: relaunched with a fresh pid", revivedPid > 0 && revivedPid != healthyPid,
          "before=\(healthyPid) after=\(revivedPid)")
    reviveSession.stop()
    try? await Task.sleep(for: .seconds(2.6))

    // Metrics sampling on a CPU-bound child.
    let cpuProject = Project(name: "cpu", path: "/tmp", devCommand: "yes > /dev/null", memoryGB: 2)
    let cpuSession = DevSession(project: cpuProject)
    cpuSession.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(2.6))
    let samples = cpuSession.history.count
    let maxTreeCPU = cpuSession.history.map(\.treeCPU).max() ?? 0
    let lastMem = cpuSession.history.last?.treeMem ?? 0
    let sysMem = cpuSession.history.last?.systemMemTotal ?? 0
    check("metrics: sampler runs", samples >= 2, "samples=\(samples)")
    check("metrics: treeCPU detected", maxTreeCPU > 10, String(format: "max %.0f%%", maxTreeCPU))
    check("metrics: treeMem > 0", lastMem > 0, "\(Int(lastMem / 1_048_576))MB")
    check("metrics: systemMem read", sysMem > 1_000_000_000, "\(Int(sysMem / 1_048_576))MB")
    cpuSession.stop()
    try? await Task.sleep(for: .seconds(2.6))

    // P3: recycle() kills the tree and relaunches with a fresh pid.
    let recProject = Project(
        name: "rec", path: "/tmp",
        devCommand: "sh -c 'echo \"Local: http://localhost:4399/\"; sleep 30'",
        memoryGB: 2
    )
    let recSession = DevSession(project: recProject)
    recSession.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(1.5))
    let pidBefore = recSession.pid
    check("recycle: active before", recSession.state.isActive && pidBefore > 0, "pid=\(pidBefore)")
    recSession.recycle()
    try? await Task.sleep(for: .seconds(3.0))  // SIGTERM + 0.4s + relaunch + grace
    let pidAfter = recSession.pid
    check("recycle: count incremented", recSession.recycleCount == 1, "count=\(recSession.recycleCount)")
    check("recycle: fresh pid", pidAfter > 0 && pidAfter != pidBefore, "before=\(pidBefore) after=\(pidAfter)")
    check("recycle: active again", recSession.state.isActive, "state=\(recSession.state.label)")
    recSession.stop()
    try? await Task.sleep(for: .seconds(2.6))

    // P5: build runner — success and failure.
    let okBuild = BuildRunner(project: Project(name: "b", path: "/tmp",
        buildCommand: "sh -c 'echo BUILDING_OK; exit 0'"))
    okBuild.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(2))
    check("build: success", okBuild.result == 0 && !okBuild.isRunning, "result=\(String(describing: okBuild.result))")
    check("build: log captured", okBuild.logLines.contains { $0.contains("BUILDING_OK") })

    let failBuild = BuildRunner(project: Project(name: "bf", path: "/tmp",
        buildCommand: "sh -c 'exit 3'"))
    var failEvented = false
    failBuild.onEvent = { _ in failEvented = true }
    failBuild.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(2))
    check("build: failure code", failBuild.result == 3, "result=\(String(describing: failBuild.result))")
    check("build: failure posts a buildFinished event", failEvented, "evented=\(failEvented)")

    // P6: a user-initiated stop() must NOT post a buildFinished event — the process is signal-killed
    // (non-zero exit), but the user cancelled deliberately, so it isn't a "Build failed". onFinish
    // still fires so the orchestrator can relaunch the dev server it paused.
    let stopBuild = BuildRunner(project: Project(name: "bs", path: "/tmp",
        buildCommand: "sh -c 'sleep 10'"))
    var stopEvented = false
    var stopFinished = false
    stopBuild.onEvent = { _ in stopEvented = true }
    stopBuild.onFinish = { _ in stopFinished = true }
    stopBuild.start(memoryGB: 2)
    try? await Task.sleep(for: .seconds(0.5))
    stopBuild.stop()
    try? await Task.sleep(for: .seconds(2))
    check("build: stop() posts no buildFinished event", !stopEvented, "evented=\(stopEvented)")
    check("build: stop() still calls onFinish", stopFinished, "finished=\(stopFinished)")
    check("build: stop() logs 'build stopped'", stopBuild.logLines.contains { $0.contains("build stopped") })

    // A4: reapLeftovers matches a project path by boundary, not substring — a project at /p/foo must
    // never reap a sibling server at /p/foobar.
    check("path: exact arg match", DevSession.args("node /p/foo/server.js", referencePath: "/p/foo"))
    check("path: trailing match", DevSession.args("cd /p/foo", referencePath: "/p/foo"))
    check("path: sibling NOT matched", !DevSession.args("node /p/foobar/server.js", referencePath: "/p/foo"))
    check("path: longer-name NOT matched", !DevSession.args("/p/foobar", referencePath: "/p/foo"))

    // A5: fullTree enumerates the whole tree (leader + children) and the tree-kill reaps all of it,
    // including children that live in their own process group (the setsid-escapee case the old
    // killpg-only path missed).
    if let proc = SpawnedProcess.spawn(command: "sh -c 'sleep 30 & sleep 30 & wait'",
                                       cwd: "/tmp", wantsStdin: false) {
        try? await Task.sleep(for: .seconds(1.0))
        let tree = ProcessTree.fullTree(of: proc.pid)
        check("tree: fullTree includes leader + children", tree.count >= 3, "count=\(tree.count)")
        ProcessSupport.gracefulKillTree(proc.pid)
        try? await Task.sleep(for: .seconds(3.5))   // SIGTERM + 2s grace + SIGKILL + reap
        let aliveAfter = tree.filter { kill($0, 0) == 0 }
        check("tree: every pid reaped by tree-kill", aliveAfter.isEmpty, "alive=\(aliveAfter)")
        proc.release()
    } else {
        check("tree: spawn succeeded", false, "spawn failed")
    }

    return failures
}

let failures = await runSessionTests()
print(failures == 0 ? "ALL SESSION TESTS PASSED" : "\(failures) SESSION TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
