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

    @ObservationIgnored private let store = ProjectStore()

    init() {
        projects = store.load()
        selectedProjectID = projects.first?.id
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

    func launch(_ project: Project) {
        if let s = activeSession, s.project.id != project.id { s.stop() }
        let session = DevSession(project: project)
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

    func persist() {
        store.save(projects)
    }
}
