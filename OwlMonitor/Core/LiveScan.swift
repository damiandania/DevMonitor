import Foundation
import Observation

/// The Doctor's "Live Scan": instead of a one-shot log snapshot, it WATCHES Owl Monitor and the
/// machine for a chosen window (a couple of minutes), sampling the process table, the supervised
/// sessions/builds/workers, machine pressure and the app's own internal event log on a ~2 s tick.
/// It assembles that timeline into a transcript and hands it to Claude, which returns a structured,
/// copyable report: what each process is and who it belongs to, what happened over the window, any
/// errors/bugs, and concrete improvement points. Read-only throughout. Owned by AppState (unowned
/// back-reference, like PressureManager) so the manager can read live state on each tick.
@MainActor
@Observable
final class LiveScan {
    enum Phase: Sendable { case idle, observing, analyzing }

    private(set) var phase: Phase = .idle
    /// 0…1 across the observation window — drives the determinate progress bar in the Doctor.
    private(set) var progress: Double = 0
    /// Seconds observed so far (for the "12s / 120s" readout).
    private(set) var elapsed: Int = 0
    /// The finished report — nil until Claude answers; kept if a later scan is cancelled.
    private(set) var report: ClaudeRunner.Report?
    /// How long to observe, in seconds — set from the Doctor's duration picker before starting.
    var duration: Int = 120

    var isRunning: Bool { phase != .idle }

    @ObservationIgnored private unowned let app: AppState
    @ObservationIgnored private var task: Task<Void, Never>?

    /// One tick every 2 s: fine enough to catch short-lived activity, coarse enough to stay bounded.
    private let tickMs = 2_000

    init(app: AppState) { self.app = app }

    /// Begin a scan: observe for `duration` seconds (progress bar), then ask Claude for the report.
    /// No-op if one is already running. Cancellable via `stop()` (the Doctor's red Stop button).
    func start() {
        guard !isRunning else { return }
        report = nil
        progress = 0
        elapsed = 0
        phase = .observing
        let seconds = max(10, duration)
        let language = app.reportLanguageHint
        let model = app.settings.analysisModel
        task = Task { [weak self] in
            guard let self else { return }
            let transcript = await self.observe(seconds: seconds)
            if Task.isCancelled { self.phase = .idle; return }
            self.phase = .analyzing
            let result = await ClaudeRunner.liveScan(transcript: transcript, language: language, model: model)
            if Task.isCancelled { self.phase = .idle; return }
            self.report = result
            self.phase = .idle
        }
    }

    func stop() { task?.cancel(); task = nil; phase = .idle }
    func reset() { stop(); report = nil }

    // MARK: - Observation

    /// Sample the app + machine every `tickMs` for `seconds`, returning a plain-text timeline. Drains
    /// Owl Monitor's internal log every tick (the primary error/bug signal) and takes a few full
    /// process snapshots across the window (bounded, since each carries argv for attribution).
    private func observe(seconds: Int) async -> String {
        let steps = max(1, seconds * 1000 / tickMs)
        let detailEvery = max(1, steps / 3)          // ~3–4 full process snapshots across the window
        var lines: [String] = [header()]
        // Capture the internal-log backlog up-front (what led to this moment), then stream new lines.
        let backlog = AppLog.shared.entries
        lines.append("--- internal log backlog (last \(min(80, backlog.count)) of \(backlog.count) lines) ---")
        lines.append(contentsOf: backlog.suffix(80))
        lines.append("--- live timeline ---")
        var seenLog = backlog.count

        for step in 0..<steps {
            if Task.isCancelled { break }
            let t = step * tickMs / 1000
            lines.append(systemLine(t: t))
            let entries = AppLog.shared.entries
            if entries.count > seenLog {
                for e in entries[seenLog...] { lines.append("[t=\(t)s] LOG: \(e)") }
                seenLog = entries.count
            }
            if step % detailEvery == 0 { lines.append(contentsOf: processDetail(t: t)) }
            elapsed = t
            progress = Double(step + 1) / Double(steps)
            try? await Task.sleep(nanoseconds: UInt64(tickMs) * 1_000_000)
        }
        // A final snapshot so the report always reflects the end state, then pin progress to 100%.
        if !Task.isCancelled { lines.append(contentsOf: processDetail(t: seconds)) }
        elapsed = seconds
        progress = 1
        return lines.joined(separator: "\n")
    }

    /// One-time context: machine size, relevant settings, and the registered projects.
    private func header() -> String {
        let s = app.systemSampler
        let gb = 1_073_741_824.0
        var out = ["=== Owl Monitor live scan — \(duration)s window ==="]
        out.append(String(format: "machine: %d cores, %.0f GB RAM", s.coreCount, s.totalMem / gb))
        out.append("settings: model=\(app.settings.analysisModel), autoCloseOrphans=\(app.settings.autoCloseOrphans), defaultHeap=\(app.settings.defaultMemoryGB)GB")
        out.append("registered projects (\(app.projects.count)):")
        for p in app.projects {
            let active = app.sessions[p.id]?.state.isActive == true ? " [server ACTIVE]" : ""
            out.append("  - \(p.name) — \(p.framework.displayName)/\(p.packageManager.rawValue) — \(p.path)\(active)")
        }
        return out.joined(separator: "\n")
    }

    /// Compact per-tick machine line: meters + pressure state.
    private func systemLine(t: Int) -> String {
        let s = app.systemSampler
        let temp = s.cpuTemperature > 0 ? String(format: " temp=%.0f°C", s.cpuTemperature) : ""
        let pressure = s.pressure == .stuck ? " pressure=STUCK(\(s.pressureReason))" : ""
        return String(format: "[t=%ds] cpu=%.0f%% mem=%.0f%% swap=%.0f%% load=%.2f%@%@",
                      t, s.systemCPU, s.systemMemPercent, s.systemSwapPercent, s.loadAverage, temp, pressure)
    }

    /// Full process snapshot: every table row with its kind, plus argv for the real-pid rows so the
    /// report can attribute each process to the app/project/tool that owns it.
    private func processDetail(t: Int) -> [String] {
        let s = app.systemSampler
        var out = ["[t=\(t)s] --- processes (\(s.processes.count) rows) ---"]
        for row in s.processes {
            let mem = row.memBytes / 1_048_576
            var line = String(format: "  %@ | cpu=%.0f%%/core mem=%.0fMB | %@",
                              row.name, row.cpuPerCore, mem, Self.kind(of: row))
            // argv only for real pids — supervised/build/worker rows are synthetic (id < 0).
            if row.id > 0 {
                let argv = AppState.argv(of: row.id)
                if !argv.isEmpty { line += "\n      argv: \(argv.prefix(220))" }
            }
            out.append(line)
        }
        for (id, sess) in app.sessions {
            let name = app.projects.first { $0.id == id }?.name ?? "?"
            out.append("  session[\(name)]: state=\(sess.state.label) pid=\(sess.pid) port=\(sess.effectivePort.map(String.init) ?? "—") recycles=\(sess.recycleCount) lastExit=\(sess.lastExitCode.map(String.init) ?? "—")")
            if let e = sess.lastError { out.append("      lastError: \(e)") }
        }
        for (id, b) in app.builds where b.isRunning || b.result != nil {
            let name = app.projects.first { $0.id == id }?.name ?? "?"
            out.append("  build[\(name)]: running=\(b.isRunning) result=\(b.result.map(String.init) ?? "—")")
        }
        for (id, w) in app.workers where w.isRunning || w.didCrash {
            let name = app.projects.first { $0.id == id }?.name ?? "?"
            out.append("  worker[\(name)]: running=\(w.isRunning) crashed=\(w.didCrash) lastExit=\(w.lastExitCode.map(String.init) ?? "—")")
        }
        if app.systemUnderPressure {
            let kills = app.killSuggestions.map(\.name).joined(separator: ", ")
            out.append("  PRESSURE ACTIVE — kill suggestions: \(kills.isEmpty ? "none yet" : kills)")
        }
        return out
    }

    /// Human label for a process row's category (mirrors the Activity table's own classification).
    private static func kind(of row: ProcessRow) -> String {
        if row.isPreview { return "supervised preview server" }
        if row.isDevServer { return "supervised dev server" }
        if row.isWorker { return "supervised worker" }
        if row.isBuild { return "build" }
        if row.isExternalDev { return "EXTERNAL dev server (unsupervised)" }
        if row.isExternalBuild { return "EXTERNAL build (unsupervised)" }
        if row.isClaude { return "Claude Code shell" }
        if row.isExtension { return "editor extension" }
        return "other"
    }
}
