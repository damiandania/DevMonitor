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
        systemSampler.onStuck = { [weak self] in self?.evaluatePressure() }
        // Refresh the pressure suggestions every 30s: prune dead processes, clear once the machine
        // recovers (the yellow tab disappears), or re-evaluate while still stuck.
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.tickPressure()
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
        if NotificationThrottle.shouldSuppress(key: key, now: item.date, last: lastNotified[key], window: 15) { return }
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

    /// Add (or focus, if already present) a project. Returns the project, or `nil` when `path` is not
    /// a launchable project folder — in which case nothing is created or persisted.
    @discardableResult
    func addProject(path: String) -> Project? {
        if let existing = projects.first(where: { $0.path == path }) {
            selectedProjectID = existing.id
            return existing
        }
        guard Detector.isProject(path: path) else { return nil }
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
        return project
    }

    func removeProject(_ id: Project.ID) {
        sessions[id]?.stop(); sessions[id] = nil
        builds[id]?.stop(); builds[id] = nil
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

    func setBuildMemoryGB(_ gb: Int, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].buildMemoryGB = max(1, gb)
        persist()
    }

    func setBuildMemoryAuto(_ auto: Bool, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].buildMemoryAuto = auto
        persist()
    }

    /// Persist the dev-server heap level learned by the OOM autoscaler (AUTO mode), so the next
    /// launch starts there instead of replaying 4→6→8.
    func setAutoHeapGB(_ gb: Int, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].autoHeapGB = gb
        persist()
    }

    /// Persist the build heap level learned by the OOM autoscaler (AUTO mode).
    func setBuildAutoHeapGB(_ gb: Int, for id: Project.ID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].buildAutoHeapGB = gb
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

    /// Build a project, **pausing its dev server while the build runs** to free RAM (relaunched
    /// after), adding a build tab to the global terminal and selecting it.
    func runBuild(_ project: Project) {
        guard builds[project.id]?.isRunning != true else { return }
        // Reuse the autoscaling build loop so a UI-triggered build also retries 4→6→8 on OOM. The
        // build tab follows each attempt as `builds[project.id]` is replaced.
        Task { @MainActor in _ = await runBuildAndWait(project) }
    }

    /// Build a project and WAIT for completion, returning the finished BuildRunner. Backs the
    /// synchronous `build` IPC command so the CLI can report exit code + output instead of
    /// returning immediately. Pauses the project's dev server while building (to free RAM) and
    /// relaunches it after.
    ///
    /// OOM autoscaler: starts at the build's effective heap and, in AUTO mode, retries with the next
    /// step (4→6→8) on an out-of-memory failure, persisting the learned level (`buildAutoHeapGB`) so
    /// the next build starts there. Returns the LAST BuildRunner (success, or the final failure).
    func runBuildAndWait(_ project: Project) async -> BuildRunner {
        selectedTerminalID = "b:\(project.id)"
        // Already building this project → attach to it and await the same completion.
        if let existing = builds[project.id], existing.isRunning {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let previous = existing.onFinish
                existing.onFinish = { success in
                    previous?(success)
                    cont.resume()
                }
            }
            return existing
        }
        // Free the most RAM for the build by pausing ALL active dev servers (not just this project's)
        // — on a RAM-starved Mac even another project's server can starve the build into a kernel
        // SIGKILL (not a clean V8 OOM), which fails the build and defeats the autoscaler. Relaunch
        // them all after, deferred via a Task with a short settle delay and re-read from the store,
        // so it doesn't race the just-paused sessions' state transitions (which left one Idle).
        let pausedServerIDs = sessions.compactMap { $0.value.state.isActive ? $0.key : nil }
        for id in pausedServerIDs { sessions[id]?.stop() }
        if !pausedServerIDs.isEmpty {
            AppLog.shared.event("Build \(project.name): paused \(pausedServerIDs.count) dev server(s) to free RAM")
        }
        defer {
            if !pausedServerIDs.isEmpty {
                let ids = pausedServerIDs
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    for id in ids where self.sessions[id]?.state.isActive != true {
                        if let p = self.projects.first(where: { $0.id == id }) { self.launch(p) }
                    }
                }
            }
        }

        // RAM relief for the build — the whole point of this app on small Macs. (1) purge inactive/
        // cached system memory, (2) surface the resource advisor so heavy non-essential apps can be
        // closed (user-confirmed), (3) keep relieving pressure during the build so we act BEFORE the
        // kernel jetsams it (SIGKILL) once swap fills up.
        await Task.detached { Self.purgeSystemMemory() }.value
        evaluatePressure(focusTab: false)
        let pressureWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.systemSampler.systemMemPercent > 85 else { continue }
                await Task.detached { Self.purgeSystemMemory() }.value
                self.evaluatePressure(focusTab: false)
            }
        }
        defer { pressureWatch.cancel() }

        var heapGB = effectiveBuildMemoryGB(for: project)
        while true {
            let build = BuildRunner(project: project)
            build.onEvent = { [weak self] event in
                self?.route(NotificationPolicy.make(from: event, projectID: project.id))
            }
            builds[project.id] = build
            // Set onFinish BEFORE start() so the exit can't race ahead of our continuation.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                build.onFinish = { _ in cont.resume() }
                build.start(memoryGB: heapGB)
            }
            let code = build.result ?? -1
            let isAuto = projects.first(where: { $0.id == project.id })?.buildMemoryAuto ?? false
            guard code != 0, isAuto,
                  HeapScaling.looksLikeOOM(logLines: build.logLines, exitCode: code),
                  let next = HeapScaling.next(after: heapGB, systemGB: systemRAMGB)
            else { return build }
            setBuildAutoHeapGB(next, for: project.id)   // persist the learned level before retrying
            heapGB = next
            AppLog.shared.event("Build \(project.name) OOM (exit \(code)) — retrying with \(next) GB")
        }
    }

    /// The active build if it belongs to `project`, else nil.
    func build(for project: Project) -> BuildRunner? { builds[project.id] }

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
            stopAllSessions()
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
    /// Set when the user closes (✕) the pressure tab — hides it until the machine recovers and the
    /// pressure re-triggers, so a manual dismiss isn't undone every refresh.
    var pressureDismissed = false
    /// True for the duration of one stuck episode — so the "under pressure" notification fires once
    /// (not every refresh) and "recovered" only fires if we actually warned.
    @ObservationIgnored private var pressureNotified = false

    /// True while the machine is stuck / being evaluated / has kill suggestions — drives the yellow
    /// "System pressure" tab in the global terminal.
    var systemUnderPressure: Bool {
        if pressureDismissed { return false }
        return isEvaluatingPressure || !killSuggestions.isEmpty || systemSampler.pressure == .stuck
    }

    /// User closed the pressure tab — clear it and keep it hidden until pressure re-triggers.
    func dismissPressure() {
        pressureDismissed = true
        killSuggestions.removeAll()
    }

    /// Runs every ~1 min while a pressure tab is/was showing: prunes suggestions whose process has
    /// exited, clears everything once the machine recovers (so the tab disappears), and otherwise
    /// refreshes the suggestions while still stuck — without stealing the user's tab selection.
    func tickPressure() {
        // Drop suggestions whose process is gone (signal 0 = "are you still there?").
        if !killSuggestions.isEmpty {
            killSuggestions.removeAll { $0.id > 0 && kill($0.id, 0) != 0 }
        }
        if systemSampler.pressure == .stuck {
            // Refresh the SUGGESTIONS only — do NOT re-run the orphan auto-close every tick.
            if !pressureDismissed { refreshKillSuggestions() }
        } else {
            // Recovered: notify (if we warned), clear suggestions, and re-arm for the next event.
            if pressureNotified {
                route(NotificationItem(title: "System pressure cleared",
                                       body: "The machine is no longer under pressure.",
                                       category: .pressure, severity: .passive, projectID: nil, action: .open))
                pressureNotified = false
            }
            killSuggestions.removeAll()
            pressureDismissed = false
        }
    }

    /// Every managed session's leader pid and its whole tree — never auto-close any of these, even a
    /// server still launching (whose tree isn't enumerable yet, so it isn't aggregated out and would
    /// otherwise look like an orphan dev server and get SIGKILLed mid-launch).
    private var managedPids: Set<Int32> {
        Set(sessions.values.flatMap { [$0.pid] + ProcessTree.sessionMembers(of: $0.pid) }.filter { $0 > 0 })
    }

    /// Called once on a genuine normal→stuck transition: focuses the pressure tab, auto-closes
    /// orphaned dev processes (one-shot), then computes the kill suggestions.
    func evaluatePressure(focusTab: Bool = true) {
        if focusTab {
            pressureDismissed = false           // a fresh pressure event un-dismisses the tab
            selectedTerminalID = "pressure"     // focus it so the suggestions are seen
            if !pressureNotified {              // once per stuck episode
                pressureNotified = true
                let reason = systemSampler.pressureReason
                route(NotificationItem(title: "Machine under pressure",
                                       body: reason.isEmpty ? "The machine is stuck." : reason,
                                       category: .pressure, severity: .urgent, projectID: nil, action: .open))
            }
        }
        autoCloseOrphans()
        refreshKillSuggestions()
    }

    /// Auto-close ORPHANED dev processes — a dev server (by its binary in argv) that isn't part of a
    /// managed session. Managed servers (incl. one still launching), editor helpers and protected
    /// processes are excluded; what was closed is notified. (Off-switchable.)
    private func autoCloseOrphans() {
        guard settings.autoCloseOrphans else { return }
        let managed = managedPids
        let orphans = systemSampler.processes.filter { row in
            row.id > 0
                && !managed.contains(row.id)
                && !row.name.localizedCaseInsensitiveContains("Helper")
                && !ResourceAdvisor.isProtected(row.name)
                && ResourceAdvisor.looksLikeDevServer(argv: Self.argv(of: row.id))
        }
        guard !orphans.isEmpty else { return }
        orphans.forEach { Self.killPid($0.id) }
        let names = orphans.map(\.name).joined(separator: ", ")
        route(NotificationItem(
            title: "Closed orphaned dev process\(orphans.count > 1 ? "es" : "")",
            body: "Auto-closed \(orphans.count) to relieve pressure: \(names)",
            category: .pressure, severity: .passive, projectID: nil, action: .none))
        AppLog.shared.event("Pressure: auto-closed \(orphans.count) orphan(s): \(names)")
    }

    /// (Re)compute the kill suggestions: heuristic instantly, refined by Haiku. Managed servers are
    /// kept in the snapshot so a runaway one can be suggested by name. Safe to call on a refresh.
    func refreshKillSuggestions() {
        guard !isEvaluatingPressure else { return }
        isEvaluatingPressure = true
        let s = systemSampler
        let procs: [ResourceAdvisor.Proc] = s.processes
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

    /// Kill a suggested process (red-skull button). The dev-server tree is stopped via the
    /// supervisor; a foreign process gets SIGTERM, escalating to SIGKILL if still alive.
    func killSuggestion(_ rec: ResourceAdvisor.Recommendation) {
        if rec.action == .stopDevServer || rec.id == -1 {
            // The suggestion's id is the server's synthetic id (-pid) — stop THAT server; if it
            // doesn't map to a live session, fall back to stopping all.
            if let s = sessions.values.first(where: { $0.pid == -rec.id }) { s.stop() }
            else { stopAllSessions() }
        } else if rec.id > 0 {
            Self.killPid(rec.id)
        }
        killSuggestions.removeAll { $0.id == rec.id }
    }

    func persist() {
        store.save(projects)
    }
}
