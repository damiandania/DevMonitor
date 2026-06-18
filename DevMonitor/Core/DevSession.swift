import Foundation
import Observation
import Darwin

/// Supervises a single dev-server process tree: launches it via the C session shim,
/// streams its merged stdout/stderr, samples resource metrics, probes its health, and
/// auto-recycles the whole tree (killpg + relaunch) when it hangs.
@MainActor
@Observable
final class DevSession {
    let project: Project
    private(set) var state: SessionState = .idle
    private(set) var logLines: [String] = []
    private(set) var detectedPort: Int?
    private(set) var pid: pid_t = 0
    private(set) var startedAt: Date?
    private(set) var recycleCount = 0

    /// Supervision-event hook (notifications). Set by AppState; nil in headless tests.
    var onEvent: (@MainActor (SupervisionEvent) -> Void)?

    private let maxLogLines = 2000
    private var lineBuffer = ""
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var graceTask: Task<Void, Never>?
    private var consumeTask: Task<Void, Never>?
    private var stopping = false
    private var stdinFD: Int32 = -1
    private var logFile: FileHandle?

    // Metrics sampling (P2)
    private(set) var history: [MetricPoint] = []
    private let maxHistory = 120
    private var sampleTask: Task<Void, Never>?
    private var tick = 0
    private var prevTreeCPUns: Int64 = 0
    private var prevWall: UInt64 = 0
    private var prevSysTicks: dm_cpu_ticks?

    // Health & recycle (P3)
    private var healthTask: Task<Void, Never>?
    private var strikes = 0
    private var hasBeenHealthy = false
    private var recycling = false
    private var lastMemoryGB = 4
    private let probeInterval: Duration = .seconds(6)
    private let httpTimeout: TimeInterval = 8   // tolerant of a busy server under load
    private let strikeLimit = 2

    private enum Chunk: Sendable {
        case data(Data)
        case eof
        case exit(code: Int32)
    }

    init(project: Project) {
        self.project = project
    }

    var effectivePort: Int? { detectedPort ?? project.port }

    // MARK: - Launch / stop

    func start(memoryGB: Int) {
        guard !state.isActive else { return }
        state = .launching
        stopping = false
        recycling = false
        strikes = 0
        lastMemoryGB = memoryGB
        logLines.removeAll()
        lineBuffer = ""
        detectedPort = nil
        startedAt = Date()
        openLogFile()

        let baseCommand = project.devCommand ?? Detector.detect(path: project.path).devCommand
        // Prepend env inline (the login shell applies it), and `exec` so the dev process
        // REPLACES the shell — making it the session leader we spawned, so the whole tree
        // is reliably enumerable (by session) and killable (by killpg).
        let portEnv = project.port.map { "PORT=\($0) " } ?? ""
        // NUXT_IGNORE_LOCK=1: Dev Monitor is the single authority that supervises one server per
        // project, so Nuxt's own dev-lock would only get in the way — e.g. a stale `nuxt.lock`
        // left behind by a SIGKILLed run would block the relaunch. We dedupe ourselves.
        let command = "NUXT_IGNORE_LOCK=1 NODE_OPTIONS=--max-old-space-size=\(memoryGB * 1024) FORCE_COLOR=1 \(portEnv)exec \(baseCommand)"
        append(line: "$ \(command)  (cwd: \(project.path))")

        var fd: Int32 = -1
        var inFD: Int32 = -1
        let childPid = dm_spawn_session(command, project.path, &fd, &inFD)
        guard childPid > 0, fd >= 0 else {
            state = .failed("spawn failed")
            AppLog.shared.event("DevSession: spawn failed for \(project.name) — cmd: \(command)")
            return
        }
        pid = childPid
        stdinFD = inFD
        let pipeFD = fd  // immutable copy for the @Sendable Dispatch handlers

        let (stream, continuation) = AsyncStream<Chunk>.makeStream()
        let queue = DispatchQueue(label: "devsession.\(childPid)")

        let reader = DispatchSource.makeReadSource(fileDescriptor: pipeFD, queue: queue)
        reader.setEventHandler { @Sendable in
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            let n = read(pipeFD, &buffer, buffer.count)
            if n > 0 {
                continuation.yield(.data(Data(buffer[0..<n])))
            } else {
                continuation.yield(.eof)
            }
        }
        reader.setCancelHandler { @Sendable in close(pipeFD) }
        reader.resume()
        readSource = reader

        let watcher = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: queue)
        watcher.setEventHandler { @Sendable in
            var status: Int32 = 0
            waitpid(childPid, &status, 0)
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : status
            continuation.yield(.exit(code: code))
        }
        watcher.resume()
        exitSource = watcher

        consumeTask = Task { @MainActor [weak self] in
            for await chunk in stream {
                guard let self else { continue }
                switch chunk {
                case .data(let data): self.ingest(data)
                case .eof: self.readSource?.cancel(); self.readSource = nil
                case .exit(let code): self.handleExit(code: code)
                }
            }
        }

        // Warm-up safety net: many dev servers print "Local:" long before HTTP is ready
        // (e.g. MiddleSpace ~25s of Vite compile). We do NOT recycle during warm-up; only the
        // first successful HTTP probe flips to .running (see startHealth). If nothing ever
        // answers within the window (e.g. an API with no "/" route), assume it's up.
        graceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(150))
            guard let self, !self.hasBeenHealthy, case .launching = self.state else { return }
            self.hasBeenHealthy = true
            self.state = .running(port: self.effectivePort ?? 3000)
            self.append(line: "warn: no HTTP within warm-up window — assuming running")
        }

        startSampling()
        startHealth()
    }

    /// Send a line of input to the running dev server's stdin.
    func sendInput(_ text: String) {
        guard stdinFD >= 0 else { return }
        let line = text + "\n"
        _ = line.withCString { ptr in write(stdinFD, ptr, strlen(ptr)) }
        append(line: "> \(text)")
    }

    private func closeStdin() {
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
    }

    func stop() {
        stopping = true
        recycling = false
        graceTask?.cancel()
        sampleTask?.cancel()
        healthTask?.cancel()
        closeStdin()
        guard pid > 0 else {
            state = .stopped(code: 0)
            return
        }
        let target = pid
        append(line: "stop: SIGTERM → killpg \(target)")
        killpg(target, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            killpg(target, SIGKILL)
        }
    }

    // MARK: - Output handling

    private func ingest(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lineBuffer += text
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
            lineBuffer.removeSubrange(...nl)
            handle(line: line)
        }
    }

    private func handle(line: String) {
        let clean = line.strippedANSI
        if clean.hasPrefix("Restored session:") || clean.contains("Saving session...completed") { return }
        append(line: line)
        if detectedPort == nil,
           let match = clean.firstMatch(of: /https?:\/\/[^\s:\/]+:(\d{2,5})/),
           let port = Int(match.1) {
            detectedPort = port
        }
        // NOTE: we do NOT flip to .running on the "ready" log line — the server is usually
        // still compiling and not accepting HTTP yet. .running is set by the first successful
        // health probe (startHealth), which is what prevents the recycle-during-warm-up loop.
    }

    private func append(line: String) {
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
        if let data = (line.strippedANSI + "\n").data(using: .utf8) {
            logFile?.write(data)
        }
    }

    /// Mirrors the session log (ANSI-stripped) to a file so it can be followed live from a
    /// terminal — the diagnostics channel: ~/Library/Application Support/DevMonitor/dev-server.log
    private func openLogFile() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("dev-server.log")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        logFile = try? FileHandle(forWritingTo: url)
    }

    private func handleExit(code: Int32) {
        graceTask?.cancel()
        sampleTask?.cancel()
        sampleTask = nil
        pid = 0
        closeStdin()
        readSource?.cancel()
        readSource = nil
        exitSource = nil

        if recycling {
            append(line: "recycle: old tree exited (code \(code)) — relaunching")
            relaunchAfterRecycle()
            return
        }

        healthTask?.cancel()
        healthTask = nil
        switch state {
        case .running, .launching, .degraded:
            if stopping || code == 0 {
                state = .stopped(code: 0)
            } else {
                state = .failed("exited with code \(code)")
                onEvent?(.crashed(project: project.name, code: code))
                AppLog.shared.event("DevSession: \(project.name) crashed (exit \(code))")
            }
        default:
            break
        }
        append(line: "exit: process exited (code \(code))")
    }

    // MARK: - Metrics sampling (P2)

    private func startSampling() {
        prevTreeCPUns = 0
        prevWall = 0
        prevSysTicks = nil
        tick = 0
        history.removeAll()
        sampleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sampleOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func sampleOnce() {
        let now = DispatchTime.now().uptimeNanoseconds

        var treeCPUns: Int64 = 0
        var treeMem: Int64 = 0
        if pid > 0 {
            for p in ProcessTree.sessionMembers(of: pid) {
                let st = dm_proc_stat_for(p)
                if st.valid == 1 {
                    treeCPUns += st.cpu_time_ns
                    treeMem += st.phys_footprint
                }
            }
        }
        var treeCPU = 0.0
        if prevWall > 0, treeCPUns >= prevTreeCPUns {
            let dt = Double(now - prevWall)
            if dt > 0 { treeCPU = Double(treeCPUns - prevTreeCPUns) / dt * 100 }
        }
        prevTreeCPUns = treeCPUns
        prevWall = now

        var ticks = dm_cpu_ticks()
        _ = dm_system_cpu_ticks(&ticks)
        var sysCPU = 0.0
        if let prev = prevSysTicks {
            let dTotal = Double(ticks.total &- prev.total)
            let dIdle = Double(ticks.idle &- prev.idle)
            if dTotal > 0 { sysCPU = max(0, min(100, (1 - dIdle / dTotal) * 100)) }
        }
        prevSysTicks = ticks

        var mem = dm_mem_info()
        _ = dm_system_mem(&mem)

        let point = MetricPoint(
            id: tick,
            systemCPU: sysCPU,
            systemMemUsed: Double(mem.used),
            systemMemTotal: Double(mem.total),
            treeCPU: treeCPU,
            treeMem: Double(treeMem),
            buildCPU: 0,
            orphanCPU: 0,
            loadAvg: dm_load_avg()
        )
        tick += 1
        history.append(point)
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
    }

    // MARK: - Health & recycle (P3)

    private func startHealth() {
        strikes = 0
        hasBeenHealthy = false
        healthTask = Task { @MainActor [weak self] in
            // Probe a bit more often while warming up so we flip to .running promptly.
            while !Task.isCancelled {
                guard let self else { return }
                let interval: Duration = self.hasBeenHealthy ? self.probeInterval : .seconds(2)
                try? await Task.sleep(for: interval)
                switch self.state {
                case .stopped, .failed, .recycling, .idle: continue
                default: break
                }
                guard let port = self.effectivePort else { continue }
                let alive = await Self.probe(port: port, timeout: self.httpTimeout)
                if Task.isCancelled || self.stopping || self.recycling { continue }

                if alive {
                    let recovering = self.hasBeenHealthy && self.strikes > 0
                    let firstTime = !self.hasBeenHealthy
                    self.hasBeenHealthy = true
                    self.strikes = 0
                    if firstTime { self.append(line: "ok: server is responding on :\(port)") }
                    if recovering {
                        self.append(line: "ok: health recovered")
                        self.onEvent?(.recovered(project: self.project.name))
                    }
                    self.state = .running(port: port)
                } else if self.hasBeenHealthy {
                    // Was healthy and stopped responding → strike toward recycle.
                    self.strikes += 1
                    self.append(line: "warn: health probe failed (\(self.strikes)/\(self.strikeLimit))")
                    if self.strikes >= self.strikeLimit {
                        self.recycle()
                    } else {
                        self.state = .degraded(strikes: self.strikes)
                        self.onEvent?(.hung(project: self.project.name))
                    }
                }
                // else: still warming up (server has never answered yet) — keep waiting,
                // do NOT recycle. The grace task assumes-running after the warm-up window.
            }
        }
    }

    private static func probe(port: Int, timeout: TimeInterval) async -> Bool {
        // Use "localhost" (not 127.0.0.1): many dev servers bind IPv6 [::1] only, so an IPv4-only
        // probe gets "connection refused" and the server appears stuck in "Launching" forever.
        guard let url = URL(string: "http://localhost:\(port)/") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.httpMethod = "GET"
        do {
            _ = try await URLSession.shared.data(for: req)
            return true
        } catch {
            return false
        }
    }

    /// Kill the whole tree and relaunch with the last memory setting.
    func recycle() {
        guard !recycling else { return }
        recycling = true
        recycleCount += 1
        state = .recycling
        append(line: "recycle: kill tree + relaunch")
        onEvent?(.recycled(project: project.name))
        AppLog.shared.event("DevSession: recycling \(project.name) (recycle #\(recycleCount), port \(effectivePort.map(String.init) ?? "?"))")
        healthTask?.cancel()
        sampleTask?.cancel()
        graceTask?.cancel()
        if pid > 0 {
            let target = pid
            killpg(target, SIGTERM)
            Task.detached {
                try? await Task.sleep(for: .seconds(2))
                killpg(target, SIGKILL)
            }
            // handleExit() fires on exit and calls relaunchAfterRecycle().
        } else {
            relaunchAfterRecycle()
        }
    }

    private func relaunchAfterRecycle() {
        recycling = false
        state = .idle  // clear "active" so start() proceeds
        let gb = lastMemoryGB
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.start(memoryGB: gb)
        }
    }
}
