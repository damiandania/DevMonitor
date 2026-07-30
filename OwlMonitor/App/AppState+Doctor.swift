import Foundation

/// The Doctor's READ-ONLY AI analyses — the Live Scan (a timed observation of Owl Monitor itself),
/// the heavy-process resource advice, the memory-relief advice, and the per-project failure
/// diagnosis. The advice/memory/project analyses are backed by an `AsyncJob` (declared on `AppState`)
/// so the guard → flag → `Task` → cancel lifecycle lives once; the Live Scan is backed by the
/// `liveScan` manager (its own progress/phase lifecycle). These properties are thin read-only shims
/// so views stay simple.
extension AppState {

    // MARK: Live Scan — watch the app + machine for a while, then a Claude report (processes and who
    // owns them, activity, errors/bugs, improvement points). Backed by the `liveScan` manager.

    var liveScanReport: ClaudeRunner.Report? { liveScan.report }
    var isLiveScanning: Bool { liveScan.isRunning }

    func startLiveScan() { liveScan.start() }
    func stopLiveScan() { liveScan.stop() }
    func resetLiveScan() { liveScan.reset() }

    // MARK: Project diagnosis — Claude explains why the SELECTED project's server/build failed,
    // reading the project's own config plus the supervisor's failure context (state/exit/lastError/log).

    var projectDiagnosis: ClaudeRunner.Report? { projectJob.output }
    var isDiagnosingProject: Bool { projectJob.isRunning }

    /// Diagnose `projectID` (the Doctor's project picker), falling back to the sidebar selection when
    /// nil. No-op if neither resolves to a known project.
    func diagnoseProject(projectID: Project.ID? = nil) {
        let target = projectID.flatMap { id in projects.first { $0.id == id } } ?? selectedProject
        guard let project = target else { return }
        let name = project.name, path = project.path, model = settings.analysisModel
        let context = projectFailureContext(project)
        projectJob.run {
            await ClaudeRunner.diagnoseProject(name: name, projectPath: path, context: context, model: model)
        }
    }

    func stopProjectDiagnosis() { projectJob.stop() }
    func resetProjectDiagnosis() { projectJob.reset() }

    /// Assemble the supervisor's failure context for `project` from whichever runs exist — dev
    /// server, preview, build, worker — each with its state/exit/`lastError` and an ANSI-stripped log
    /// tail. Fed to `ClaudeRunner.diagnoseProject`. Kept to a bounded tail so the prompt stays small.
    func projectFailureContext(_ project: Project) -> String {
        func tail(_ lines: [String], _ n: Int = 120) -> String {
            lines.suffix(n).map(\.strippedANSI).joined(separator: "\n")
        }
        var parts = ["Project: \(project.name)",
                     "Framework: \(project.framework.displayName)",
                     "Package manager: \(project.packageManager.rawValue)",
                     "Path: \(project.path)"]
        var sawRun = false
        if let s = sessions[project.id] {
            sawRun = true
            parts.append("\n[Dev server] state=\(s.state.label), lastExit=\(s.lastExitCode.map(String.init) ?? "—")")
            if let e = s.lastError { parts.append("recorded cause: \(e)") }
            parts.append("--- dev server output (tail) ---\n\(tail(s.logLines))")
        }
        if let p = previews[project.id] {
            sawRun = true
            parts.append("\n[Preview] state=\(p.state.label), lastExit=\(p.lastExitCode.map(String.init) ?? "—")")
            if let e = p.lastError { parts.append("recorded cause: \(e)") }
            parts.append("--- preview output (tail) ---\n\(tail(p.logLines))")
        }
        if let b = builds[project.id] {
            sawRun = true
            let result = b.result.map(String.init) ?? (b.isRunning ? "running" : "—")
            parts.append("\n[Build] result=\(result)")
            parts.append("--- build output (tail) ---\n\(tail(b.logLines))")
        }
        if let w = workers[project.id] {
            sawRun = true
            parts.append("\n[Worker] running=\(w.isRunning), crashed=\(w.didCrash), lastExit=\(w.lastExitCode.map(String.init) ?? "—")")
            parts.append("--- worker output (tail) ---\n\(tail(w.logLines))")
        }
        if !sawRun {
            parts.append("\nNo supervised run (dev/preview/build/worker) has been started for this project in this session — nothing to diagnose yet. Advise the user to start it first, or inspect the project's config for likely startup problems.")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Resource advisor — Claude recommends actions on heavy processes. Managed dev processes
    // may be stopped automatically; foreign processes are only closed after explicit confirmation.

    var advice: ResourceAdvisor.Advice? { adviceJob.output }
    var isAdvising: Bool { adviceJob.isRunning }

    func generateAdvice() {
        let s = systemSampler
        let procs: [ResourceAdvisor.Proc] = s.processes.map {
            .init(pid: $0.id, name: $0.name, cpuPerCore: $0.cpuPerCore,
                  memMB: $0.memBytes / 1_048_576, managedDev: $0.isDevServer)
        }
        let cpu = s.systemCPU, mem = s.systemMemPercent, cores = s.coreCount
        let model = settings.analysisModel
        adviceJob.run {
            await ResourceAdvisor.advise(systemCPU: cpu, systemMemPercent: mem,
                                         coreCount: cores, procs: procs, model: model)
        }
    }

    func stopAdvice() { adviceJob.stop() }
    func resetAdvice() { adviceJob.reset() }

    // MARK: Doctor — Memory & RAM section: structured AI list of processes to close to free RAM.

    var memoryAdvice: ResourceAdvisor.Advice? { memoryJob.output }
    var isGeneratingMemory: Bool { memoryJob.isRunning }

    func generateMemory() {
        let s = systemSampler
        let procs: [ResourceAdvisor.Proc] = s.processes.map {
            .init(pid: $0.id, name: $0.name, cpuPerCore: $0.cpuPerCore,
                  memMB: $0.memBytes / 1_048_576, managedDev: $0.isDevServer)
        }
        let totalGB = s.totalMem / 1_073_741_824
        let usedPct = s.systemMemPercent
        let swapUsedGB = s.systemSwapUsed / 1_073_741_824
        let swapTotalGB = s.systemSwapTotal / 1_073_741_824
        let model = settings.analysisModel
        memoryJob.run {
            await ResourceAdvisor.memoryAdvice(
                totalMemGB: totalGB, usedPercent: usedPct,
                swapUsedGB: swapUsedGB, swapTotalGB: swapTotalGB, procs: procs, model: model)
        }
    }

    func stopMemory() { memoryJob.stop() }
    func resetMemory() { memoryJob.reset() }

    /// Apply a recommendation. Foreign-process closes MUST already be confirmed by the caller.
    /// The recommendation is removed from the Doctor lists immediately so the row disappears.
    func apply(_ r: ResourceAdvisor.Recommendation) {
        switch r.action {
        case .stopDevServer:
            stopAllSessions()
        case .closeProcess:
            if r.id > 0 { Self.killPid(r.id) }   // foreign — caller has confirmed
        case .keep, .investigate:
            break
        }
        adviceJob.update { $0.recommendations.removeAll { $0.id == r.id } }
        memoryJob.update { $0.recommendations.removeAll { $0.id == r.id } }
    }

    /// Apply every closeable recommendation (the "Free memory" / close-all button). The caller
    /// confirms first; managed dev servers are stopped, foreign processes are SIGTERM→SIGKILLed.
    func applyAll(_ recs: [ResourceAdvisor.Recommendation]) {
        for r in recs where r.action == .closeProcess || r.action == .stopDevServer { apply(r) }
    }
}
