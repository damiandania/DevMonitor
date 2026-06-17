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

    func setPort(_ port: Int?, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].port = (port ?? 0) > 0 ? port : nil
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

    func persist() {
        store.save(projects)
    }
}
