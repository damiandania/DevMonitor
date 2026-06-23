import Foundation
import Observation
import AppKit
import Darwin

/// Root observable app state. Owns the project list, selection and the active session.
@MainActor
@Observable
final class AppState {
    var projects: [Project] = []
    var selectedProjectID: Project.ID?
    /// One supervised server PER PROJECT, keyed by project id. Several projects can run at once.
    var sessions: [Project.ID: DevSession] = [:]
    /// One build per project, keyed by project id.
    var builds: [Project.ID: BuildRunner] = [:]
    /// Selected tab in the GLOBAL terminal panel: "s:<projectID>" (server) or "b:<projectID>" (build).
    var selectedTerminalID: String?

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
        // The IPC hub writes responses to `dev-monitor` clients that may have already closed the
        // socket (a CLI reads its reply and exits). Without ignoring SIGPIPE, that write delivers
        // the signal whose default action TERMINATES the whole app — which is exactly why the app
        // appeared to "die" right after handling an `up`/`status` command (the dev server it had
        // already spawned survives, since it runs in its own session). The CLI guards against this;
        // the hub side must too. Set before IPCServer.start() below begins accepting/writing.
        signal(SIGPIPE, SIG_IGN)
        settings = settingsStore.load()
        // Apply the saved theme once the run loop is up — NSApp is nil during SwiftUI App.init.
        let theme = settings.theme
        Task { @MainActor in AppSettings.applyAppearance(theme) }
        projects = store.load()
        // Drop entries whose folder no longer exists (stale/junk paths) so `status`, the sidebar
        // and projects.json stay in sync with reality. Missing folders can never be launched anyway.
        let onDisk = projects.filter { FileManager.default.fileExists(atPath: $0.path) }
        if onDisk.count != projects.count {
            AppLog.shared.event("Startup: pruned \(projects.count - onDisk.count) project(s) with a missing folder")
            projects = onDisk
            store.save(projects)
        }
        installedBrowsers = BrowserList.installed()
        installedEditors = EditorList.installed()
        selectedProjectID = projects.first?.id
        ipcServer.start(app: self)
        systemSampler.start()
        systemSampler.devServerInfo = { [weak self] in
            guard let self else { return [] }
            // One entry PER supervised server (each gets its own table row, not aggregated).
            // id = -pid so the synthetic row never collides with a real pid and skips enrichment.
            return self.sessions.values
                .filter { $0.pid > 0 }
                .map { s -> (id: Int32, pids: Set<Int32>, label: String) in
                    let pids = Set(ProcessTree.sessionMembers(of: s.pid))
                    let label = s.project.name + (s.effectivePort.map { " :\($0)" } ?? "")
                    return (id: -s.pid, pids: pids, label: label)
                }
                .filter { !$0.pids.isEmpty }
        }
        systemSampler.buildInfo = { [weak self] in
            guard let self else { return nil }
            let live = self.builds.values.filter { $0.isRunning && $0.pid > 0 }
            guard !live.isEmpty else { return nil }
            var pids = Set<Int32>()
            for b in live { pids.formUnion(ProcessTree.sessionMembers(of: b.pid)) }
            guard !pids.isEmpty else { return nil }
            let label = live.count == 1 ? "Build · \(live.first?.project.name ?? "build")" : "\(live.count) builds"
            return (pids, label)
        }
        pressure = PressureManager(app: self)
        systemSampler.onStuck = { [weak self] in self?.pressure.evaluate() }
        // Refresh the pressure suggestions every 30s: prune dead processes, clear once the machine
        // recovers (the yellow tab disappears), or re-evaluate while still stuck.
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.pressure.tick()
            }
        }
        // Wire notifications: set the UN delegate (foreground presentation + action routing),
        // register actionable categories, and request authorization.
        Notifier.shared.attach(app: self)
        // Clean up on quit: stop every supervised server/build so none is left orphaned holding a
        // port — they run in their own session (SETSID) and would otherwise outlive the app.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    var selectedProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    /// Aggregate server health for the menu-bar status dot, by priority:
    /// red (any Failed) > orange (any Launching/Recycling/Degraded) > green (any Running) > idle (none).
    enum ServerHealth { case idle, green, orange, red }
    var serversHealth: ServerHealth {
        var orange = false, green = false
        for session in sessions.values {
            switch session.state {
            case .failed:                              return .red
            case .launching, .recycling, .degraded:    orange = true
            case .running:                             green = true
            case .idle, .stopped:                      break
            }
        }
        if orange { return .orange }
        if green { return .green }
        return .idle
    }

    /// Whether the selected project's build is currently running (drives the toolbar "Build Running"
    /// label shown to the left of the build button).
    var isSelectedBuildRunning: Bool {
        guard let p = selectedProject else { return false }
        return build(for: p)?.isRunning ?? false
    }

    // MARK: - Notifications

    /// The last 5 notifications (most-recent first) shown in the sidebar feed.
    var recentNotifications: [NotificationItem] = []
    /// Banner de-dup: last time a given key posted a system banner (the feed records everything).
    @ObservationIgnored private var lastNotified: [String: Date] = [:]

    /// Single funnel for every notification: record it in the in-app feed, then post a system banner
    /// if its category is enabled and it isn't a throttled repeat.
    func route(_ item: NotificationItem) {
        recentNotifications.insert(item, at: 0)
        if recentNotifications.count > 5 { recentNotifications.removeLast(recentNotifications.count - 5) }
        guard NotificationPolicy.shouldNotify(item.category, settings) else { return }
        let key = "\(item.category.rawValue)|\(item.projectID?.uuidString ?? "-")|\(item.title)"
        if NotificationThrottle.shouldSuppress(key: key, now: item.date, last: lastNotified[key],
                                               window: NotificationThrottle.defaultWindow) { return }
        lastNotified[key] = item.date
        Notifier.shared.post(item)
    }

    /// Notification action: relaunch the project's server and bring the window forward.
    func restartFromNotification(projectID: UUID?) {
        bringMainWindowToFront()
        guard let id = projectID, let p = projects.first(where: { $0.id == id }) else { return }
        selectedProjectID = id
        sessions[id]?.stop()
        launch(p)
    }

    /// Notification action: focus the app on the related project (or its build log / the pressure tab).
    func focusFromNotification(projectID: UUID?, showLogs: Bool) {
        bringMainWindowToFront()
        if let id = projectID {
            selectedProjectID = id
            selectedTerminalID = showLogs ? "b:\(id)" : "s:\(id)"
        } else {
            selectedTerminalID = "pressure"   // machine-wide (pressure) events
        }
    }

    /// Activate the app and bring the single main window to the front (no SwiftUI openWindow here).
    private func bringMainWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
    }

    /// Physical RAM in whole GB — the ceiling for any injected heap.
    var systemRAMGB: Int { max(1, Int((systemSampler.totalMem / 1_073_741_824).rounded())) }

    /// The dev-server heap (GB) that will actually be injected for `project`, capped at this machine's RAM.
    func effectiveMemoryGB(for project: Project) -> Int { project.effectiveMemoryGB(systemGB: systemRAMGB) }

    /// The build heap (GB) for `project` (independent from the dev server), capped at physical RAM.
    func effectiveBuildMemoryGB(for project: Project) -> Int { project.effectiveBuildMemoryGB(systemGB: systemRAMGB) }

    /// Free inactive/cached system memory (macOS `purge`). Best-effort, off the main thread — this
    /// app exists for RAM-constrained Macs, so we squeeze every page before/under a heavy build.
    nonisolated static func purgeSystemMemory() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/purge")
        try? p.run()
        p.waitUntilExit()
    }

    // Project CRUD + per-project settings live in AppState+Projects.swift (addProject, removeProject,
    // setMemoryGB/…, setPackageManager, …), all funneled through a single `mutate(_:_:)` helper.

    /// Launch (or no-op if already running) the supervised server for `project`, and select its
    /// tab in the global terminal. Idempotent; other projects' servers are left alone.
    func launch(_ project: Project) {
        selectedTerminalID = "s:\(project.id)"
        if let existing = sessions[project.id], existing.state.isActive { return }
        let session = DevSession(project: project)
        session.onEvent = { [weak self] event in
            self?.route(NotificationPolicy.make(from: event, projectID: project.id))
        }
        // Persist the heap level the OOM autoscaler learns (AUTO mode), so the next launch starts
        // there instead of replaying 4→6→8.
        session.onHeapEscalated = { [weak self] gb in self?.setAutoHeapGB(gb, for: project.id) }
        sessions[project.id] = session
        session.start(memoryGB: effectiveMemoryGB(for: project))
    }

    /// Stop the supervised server for one project.
    func stop(_ project: Project) { sessions[project.id]?.stop() }

    /// Stop every supervised server (pressure relief / Doctor "stop dev servers").
    func stopAllSessions() { for s in sessions.values { s.stop() } }

    /// Reap every supervised server and build process tree on app quit, so nothing is left orphaned
    /// holding a port (they run in their own session via SETSID and would otherwise survive). Runs
    /// synchronously since the process is terminating: SIGTERM each group, a short grace, then
    /// SIGKILL. A force-kill of the app can't run this — the next launch's `reapLeftovers` covers it.
    func shutdown() {
        let pgids = sessions.values.map(\.pid).filter { $0 > 0 }
                  + builds.values.map(\.pid).filter { $0 > 0 }
        guard !pgids.isEmpty else { return }
        for pg in pgids { killpg(pg, SIGTERM) }
        usleep(400_000)
        for pg in pgids { killpg(pg, SIGKILL) }
    }

    /// Close a server tab in the global terminal: stop the dev server and drop it.
    func closeServer(id: Project.ID) {
        sessions[id]?.stop()
        sessions[id] = nil
    }

    /// Close a build tab in the global terminal: stop the build if running and drop it.
    func closeBuild(id: Project.ID) {
        builds[id]?.stop()
        builds[id] = nil
    }

    /// The supervised session for `project`, if any.
    func session(for project: Project) -> DevSession? { sessions[project.id] }

    // Build orchestration (runBuild, runBuildAndWait + its pause/pressure/autoscale steps, build(for:))
    // lives in AppState+Builds.swift.

    // Doctor — three READ-ONLY AI analyses. The generate/stop/reset + apply/applyAll methods and the
    // `diagnosticReport`/`advice`/`memoryAdvice` read shims live in AppState+Doctor.swift; each is
    // backed by one of these jobs (which own the guard/flag/Task lifecycle they used to duplicate).
    let reportJob = AsyncJob<ClaudeRunner.Report>()
    let adviceJob = AsyncJob<ResourceAdvisor.Advice>()
    let memoryJob = AsyncJob<ResourceAdvisor.Advice>()

    func persistSettings() { settingsStore.save(settings) }

    // Machine-pressure subsystem (kill suggestions, orphan auto-close, the "under pressure" tab) lives
    // in PressureManager, created in init(). These shims keep the view-facing API on AppState so the
    // views are unchanged.
    @ObservationIgnored private(set) var pressure: PressureManager!
    var systemUnderPressure: Bool { pressure.systemUnderPressure }
    var isEvaluatingPressure: Bool { pressure.isEvaluating }
    var killSuggestions: [ResourceAdvisor.Recommendation] { pressure.killSuggestions }
    func dismissPressure() { pressure.dismiss() }
    func killSuggestion(_ rec: ResourceAdvisor.Recommendation) { pressure.killSuggestion(rec) }

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

    /// Kill the process behind a table row (the hover ✕ button). A managed server (synthetic
    /// id = -pid) is stopped through its supervisor; the aggregated build row stops every running
    /// build; any real process (external dev server, foreign helper) gets SIGTERM→SIGKILL.
    func killProcessRow(_ row: ProcessRow) {
        if row.isBuild {
            for b in builds.values where b.isRunning { b.stop() }
        } else if row.isDevServer {
            sessions.values.first { $0.pid == -row.id }?.stop()
        } else if row.id > 0 {
            Self.killPid(row.id)
        }
    }

    func persist() {
        store.save(projects)
    }
}
