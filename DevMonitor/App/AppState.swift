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

    @ObservationIgnored private let store = ProjectStore()
    @ObservationIgnored private let ipcServer = IPCServer()
    let systemSampler = SystemSampler()

    init() {
        projects = store.load()
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
            memoryGB: Detector.defaultMemoryGB(for: d.framework),
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
        session.start(memoryGB: project.effectiveMemoryGB)
    }

    func stopActive() {
        activeSession?.stop()
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
    var showReport = false

    func generateReport() {
        showReport = true
        guard !isGeneratingReport else { return }
        isGeneratingReport = true
        diagnosticReport = nil
        let log = AppLog.shared.recent()
        Task { [weak self] in
            let report = await ClaudeRunner.diagnose(internalLog: log)
            self?.diagnosticReport = report
            self?.isGeneratingReport = false
        }
    }

    // Resource advisor (P9): Claude recommends actions on heavy processes. Managed dev processes
    // may be stopped automatically; foreign processes are only closed after explicit confirmation.
    var advice: ResourceAdvisor.Advice?
    var isAdvising = false
    var showAdvisor = false

    func generateAdvice() {
        showAdvisor = true
        guard !isAdvising else { return }
        isAdvising = true
        advice = nil
        let s = systemSampler
        let procs: [ResourceAdvisor.Proc] = s.processes.map {
            .init(pid: $0.id, name: $0.name, cpuPerCore: $0.cpuPerCore,
                  memMB: $0.memBytes / 1_048_576, managedDev: $0.isDevServer)
        }
        let cpu = s.systemCPU, mem = s.systemMemPercent, cores = s.coreCount
        Task { [weak self] in
            let a = await ResourceAdvisor.advise(systemCPU: cpu, systemMemPercent: mem,
                                                 coreCount: cores, procs: procs)
            self?.advice = a
            self?.isAdvising = false
        }
    }

    /// Apply a recommendation. Foreign-process closes MUST already be confirmed by the caller.
    func apply(_ r: ResourceAdvisor.Recommendation) {
        switch r.action {
        case .stopDevServer:
            stopActive()
        case .closeProcess:
            if r.id > 0 { kill(r.id, SIGTERM) }   // foreign — caller has confirmed
        case .keep, .investigate:
            break
        }
    }

    // Pressure-triggered kill suggestions (auto): when the machine is stuck, a fast Haiku eval
    // proposes processes to kill, shown above the server config with a red skull button.
    var killSuggestions: [ResourceAdvisor.Recommendation] = []
    var isEvaluatingPressure = false

    func evaluatePressure() {
        guard !isEvaluatingPressure else { return }
        isEvaluatingPressure = true
        let s = systemSampler
        let procs: [ResourceAdvisor.Proc] = s.processes.map {
            .init(pid: $0.id, name: $0.name, cpuPerCore: $0.cpuPerCore,
                  memMB: $0.memBytes / 1_048_576, managedDev: $0.isDevServer)
        }
        // Show heuristic candidates instantly; refine with Haiku when it returns.
        killSuggestions = ResourceAdvisor.heuristicKills(procs: procs)
        let cpu = s.systemCPU, mem = s.systemMemPercent, swap = s.systemSwapPercent, cores = s.coreCount
        Task { [weak self] in
            let recs = await ResourceAdvisor.pressureKills(
                systemCPU: cpu, systemMemPercent: mem, systemSwapPercent: swap,
                coreCount: cores, procs: procs)
            if !recs.isEmpty { self?.killSuggestions = recs }
            self?.isEvaluatingPressure = false
        }
    }

    /// Kill a suggested process (red-skull button). The dev-server tree is stopped via the
    /// supervisor; a foreign process gets SIGTERM, escalating to SIGKILL if still alive.
    func killSuggestion(_ rec: ResourceAdvisor.Recommendation) {
        if rec.action == .stopDevServer || rec.id == -1 {
            stopActive()
        } else if rec.id > 0 {
            let pid = rec.id
            kill(pid, SIGTERM)
            Task {
                try? await Task.sleep(for: .seconds(2))
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }   // signal 0 = "are you still there?"
            }
        }
        killSuggestions.removeAll { $0.id == rec.id }
    }

    func persist() {
        store.save(projects)
    }
}
