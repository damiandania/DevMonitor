import Foundation

/// The Doctor's three READ-ONLY AI analyses — a diagnostic report about Dev Monitor itself, the
/// heavy-process resource advice, and the memory-relief advice. Each is backed by an `AsyncJob`
/// (declared on `AppState`) so the guard → flag → `Task` → cancel lifecycle lives once. The
/// `diagnosticReport`/`isGeneratingReport`/… properties are thin read-only shims so views are
/// unchanged.
extension AppState {

    // MARK: Diagnostics — a Claude report about Dev Monitor itself.

    var diagnosticReport: ClaudeRunner.Report? { reportJob.output }
    var isGeneratingReport: Bool { reportJob.isRunning }

    func generateReport() {
        let log = AppLog.shared.recent()
        let model = settings.analysisModel
        reportJob.run { await ClaudeRunner.diagnose(internalLog: log, model: model) }
    }

    func stopReport() { reportJob.stop() }
    func resetReport() { reportJob.reset() }

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
