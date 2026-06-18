import Foundation
import Observation

/// Root observable app state. Owns the project list, selection and the active session.
@MainActor
@Observable
final class AppState {
    var projects: [Project] = []
    var selectedProjectID: Project.ID?
    /// One actively-supervised server at a time (MVP).
    var activeSession: DevSession?
    /// One active build at a time.
    var activeBuild: BuildRunner?

    /// App-wide settings (browser, analysis model, …) — the gear at the bottom of the sidebar.
    var settings: AppSettings
    /// Browsers installed on this Mac (display names), for the "open in" picker.
    var installedBrowsers: [String] = []
    /// Code editors installed on this Mac, for the "Code" button picker.
    var installedEditors: [String] = []

    @ObservationIgnored private let store = ProjectStore()
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let ipcServer = IPCServer()
    let systemSampler = SystemSampler()

    init() {
        settings = settingsStore.load()
        projects = store.load()
        installedBrowsers = BrowserList.installed()
        installedEditors = EditorList.installed()
        selectedProjectID = projects.first?.id
        ipcServer.start(app: self)
        systemSampler.start()
        systemSampler.devServerInfo = { [weak self] in
            guard let session = self?.activeSession, session.pid > 0 else { return nil }
            let pids = Set(ProcessTree.sessionMembers(of: session.pid))
            guard !pids.isEmpty else { return nil }
            let label = session.project.name + (session.effectivePort.map { " :\($0)" } ?? "")
            return (pids, label)
        }
        systemSampler.buildInfo = { [weak self] in
            guard let build = self?.activeBuild, build.isRunning, build.pid > 0 else { return nil }
            let pids = Set(ProcessTree.sessionMembers(of: build.pid))
            guard !pids.isEmpty else { return nil }
            return (pids, "Build · \(build.project.name)")
        }
        systemSampler.onStuck = { [weak self] in self?.evaluatePressure() }
    }

    var selectedProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    func addProject(path: String) {
        if let existing = projects.first(where: { $0.path == path }) {
            selectedProjectID = existing.id
            return
        }
        let d = Detector.detect(path: path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        let project = Project(
            name: name,
            path: path,
            packageManager: d.packageManager,
            framework: d.framework,
            devCommand: d.devCommand,
            buildCommand: d.buildCommand,
            memoryGB: settings.defaultMemoryGB,   // new projects inherit the default-heap setting
            port: d.port
        )
        projects.append(project)
        selectedProjectID = project.id
        persist()
    }

    func removeProject(_ id: Project.ID) {
        if activeSession?.project.id == id { activeSession?.stop() }
        projects.removeAll { $0.id == id }
        if selectedProjectID == id { selectedProjectID = projects.first?.id }
        persist()
    }

    func setMemoryGB(_ gb: Int, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].memoryGB = max(1, gb)
        persist()
    }

    func setMemoryAuto(_ auto: Bool, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].memoryAuto = auto
        persist()
    }

    func setPort(_ port: Int?, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].port = (port ?? 0) > 0 ? port : nil
        persist()
    }

    /// Manually override the package manager → regenerate the dev/build commands for it.
    func setPackageManager(_ pm: PackageManager, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        let c = Detector.commands(path: projects[i].path, packageManager: pm)
        projects[i].packageManager = pm
        projects[i].devCommand = c.dev
        projects[i].buildCommand = c.build
        persist()
    }

    /// Toggle package-manager auto. Turning it back on re-detects and restores the commands.
    func setPackageManagerAuto(_ auto: Bool, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        if auto {
            let d = Detector.detect(path: projects[i].path)
            projects[i].packageManager = d.packageManager
            projects[i].devCommand = d.devCommand
            projects[i].buildCommand = d.buildCommand
        }
        projects[i].packageManagerAuto = auto
        persist()
    }

    func launch(_ project: Project) {
        if let s = activeSession, s.project.id != project.id { s.stop() }
        let session = DevSession(project: project)
        session.onEvent = { event in Notifier.shared.notify(event) }
        activeSession = session
        session.start(memoryGB: project.memoryGB)
    }

    func stopActive() {
        activeSession?.stop()
    }

    /// Close the server terminal+tab: stop the dev server and drop it from the dashboard.
    func closeServer() {
        activeSession?.stop()
        activeSession = nil
    }

    /// Close the build terminal+tab: stop the build if running and drop it.
    func closeBuild() {
        activeBuild?.stop()
        activeBuild = nil
    }

    /// The active session if it belongs to `project`, else nil.
    func session(for project: Project) -> DevSession? {
        guard let s = activeSession, s.project.id == project.id else { return nil }
        return s
    }

    func runBuild(_ project: Project) {
        let build = BuildRunner(project: project)
        build.onEvent = { event in Notifier.shared.notify(event) }
        activeBuild = build
        build.start()
    }

    /// The active build if it belongs to `project`, else nil.
    func build(for project: Project) -> BuildRunner? {
        guard let b = activeBuild, b.project.id == project.id else { return nil }
        return b
    }

    // Diagnostics (P7): a READ-ONLY Claude report about Dev Monitor itself.
    var diagnosticReport: ClaudeRunner.Report?
    var isGeneratingReport = false
    @ObservationIgnored private var reportTask: Task<Void, Never>?

    func generateReport() {
        guard !isGeneratingReport else { return }
        isGeneratingReport = true
        diagnosticReport = nil
        let log = AppLog.shared.recent()
        let model = settings.analysisModel
        reportTask = Task { [weak self] in
            let report = await ClaudeRunner.diagnose(internalLog: log, model: model)
            if Task.isCancelled { return }
            self?.diagnosticReport = report
            self?.isGeneratingReport = false
        }
    }

    func stopReport() { reportTask?.cancel(); isGeneratingReport = false }
    func resetReport() { stopReport(); diagnosticReport = nil }

    // Resource advisor (P9): Claude recommends actions on heavy processes. Managed dev processes
    // may be stopped automatically; foreign processes are only closed after explicit confirmation.
    var advice: ResourceAdvisor.Advice?
    var isAdvising = false
    @ObservationIgnored private var adviceTask: Task<Void, Never>?

    func generateAdvice() {
        guard !isAdvising else { return }
        isAdvising = true
        advice = nil
        let s = systemSampler
        let procs: [ResourceAdvisor.Proc] = s.processes.map {
            .init(pid: $0.id, name: $0.name, cpuPerCore: $0.cpuPerCore,
                  memMB: $0.memBytes / 1_048_576, managedDev: $0.isDevServer)
        }
        let cpu = s.systemCPU, mem = s.systemMemPercent, cores = s.coreCount
        let model = settings.analysisModel
        adviceTask = Task { [weak self] in
            let a = await ResourceAdvisor.advise(systemCPU: cpu, systemMemPercent: mem,
                                                 coreCount: cores, procs: procs, model: model)
            if Task.isCancelled { return }
            self?.advice = a
            self?.isAdvising = false
        }
    }

    func stopAdvice() { adviceTask?.cancel(); isAdvising = false }
    func resetAdvice() { stopAdvice(); advice = nil }

    func persistSettings() { settingsStore.save(settings) }

    // Doctor — Memory & RAM section: structured AI list of processes to close to free RAM.
    var memoryAdvice: ResourceAdvisor.Advice?
    var isGeneratingMemory = false
    @ObservationIgnored private var memoryTask: Task<Void, Never>?

    func stopMemory() { memoryTask?.cancel(); isGeneratingMemory = false }
    func resetMemory() { stopMemory(); memoryAdvice = nil }

    func generateMemory() {
        guard !isGeneratingMemory else { return }
        isGeneratingMemory = true
        memoryAdvice = nil
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
        memoryTask = Task { [weak self] in
            let a = await ResourceAdvisor.memoryAdvice(
                totalMemGB: totalGB, usedPercent: usedPct,
                swapUsedGB: swapUsedGB, swapTotalGB: swapTotalGB, procs: procs, model: model)
            if Task.isCancelled { return }
            self?.memoryAdvice = a
            self?.isGeneratingMemory = false
        }
    }

    /// Apply a recommendation. Foreign-process closes MUST already be confirmed by the caller.
    /// The recommendation is removed from the Doctor lists immediately so the row disappears.
    func apply(_ r: ResourceAdvisor.Recommendation) {
        switch r.action {
        case .stopDevServer:
            stopActive()
        case .closeProcess:
            if r.id > 0 { Self.killPid(r.id) }   // foreign — caller has confirmed
        case .keep, .investigate:
            break
        }
        advice?.recommendations.removeAll { $0.id == r.id }
        memoryAdvice?.recommendations.removeAll { $0.id == r.id }
    }

    /// Apply every closeable recommendation (the "Free memory" / close-all button). The caller
    /// confirms first; managed dev servers are stopped, foreign processes are SIGTERM→SIGKILLed.
    func applyAll(_ recs: [ResourceAdvisor.Recommendation]) {
        for r in recs where r.action == .closeProcess || r.action == .stopDevServer { apply(r) }
    }

    // Pressure-triggered kill suggestions (auto): when the machine is stuck, a fast Haiku eval
    // proposes processes to kill, shown above the server config with a red skull button.
    var killSuggestions: [ResourceAdvisor.Recommendation] = []
    var isEvaluatingPressure = false

    func evaluatePressure() {
        guard !isEvaluatingPressure else { return }
        isEvaluatingPressure = true
        let s = systemSampler

        // 1) Auto-close ORPHANED dev processes — a dev server (by its binary in argv) that isn't in
        //    our managed tree (managed/build trees are aggregated out of `processes`). Editor helpers
        //    and protected processes are excluded. Then notify what was closed. (Off-switchable.)
        let orphans = settings.autoCloseOrphans ? s.processes.filter { row in
            row.id > 0
                && !row.name.localizedCaseInsensitiveContains("Helper")
                && !ResourceAdvisor.isProtected(row.name)
                && ResourceAdvisor.looksLikeDevServer(argv: Self.argv(of: row.id))
        } : []
        if !orphans.isEmpty {
            orphans.forEach { Self.killPid($0.id) }
            let names = orphans.map(\.name).joined(separator: ", ")
            Notifier.shared.notify(
                title: "Closed orphaned dev process\(orphans.count > 1 ? "es" : "")",
                body: "Auto-closed \(orphans.count) to relieve pressure: \(names)")
            AppLog.shared.event("Pressure: auto-closed \(orphans.count) orphan(s): \(names)")
        }
        let orphanIDs = Set(orphans.map(\.id))

        // 2) Suggest the rest (heuristic instantly, refined by Haiku) for the manual skull button.
        let procs: [ResourceAdvisor.Proc] = s.processes
            .filter { !orphanIDs.contains($0.id) }
            .map { .init(pid: $0.id, name: $0.name, cpuPerCore: $0.cpuPerCore,
                         memMB: $0.memBytes / 1_048_576, managedDev: $0.isDevServer) }
        killSuggestions = ResourceAdvisor.heuristicKills(procs: procs)
        let cpu = s.systemCPU, mem = s.systemMemPercent, swap = s.systemSwapPercent, cores = s.coreCount
        let model = settings.analysisModel
        Task { [weak self] in
            let recs = await ResourceAdvisor.pressureKills(
                systemCPU: cpu, systemMemPercent: mem, systemSwapPercent: swap,
                coreCount: cores, procs: procs, model: model)
            if !recs.isEmpty { self?.killSuggestions = recs }
            self?.isEvaluatingPressure = false
        }
    }

    /// argv of a pid (joined), via KERN_PROCARGS2 — used for orphan dev-server detection.
    static func argv(of pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 8192)
        let n = Int(dm_proc_args(pid, &buf, 8192))
        return n > 0 ? String(cString: buf) : ""
    }

    /// SIGTERM a pid, escalating to SIGKILL if it's still alive shortly after.
    static func killPid(_ pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }   // signal 0 = "are you still there?"
        }
    }

    /// Kill a suggested process (red-skull button). The dev-server tree is stopped via the
    /// supervisor; a foreign process gets SIGTERM, escalating to SIGKILL if still alive.
    func killSuggestion(_ rec: ResourceAdvisor.Recommendation) {
        if rec.action == .stopDevServer || rec.id == -1 {
            stopActive()
        } else if rec.id > 0 {
            Self.killPid(rec.id)
        }
        killSuggestions.removeAll { $0.id == rec.id }
    }

    func persist() {
        store.save(projects)
    }
}
