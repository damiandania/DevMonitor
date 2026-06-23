import Foundation
import Observation
import Darwin

/// Runs the project's build script as a tracked one-shot process, separate from the
/// dev server. Streams its log and reports success/failure.
@MainActor
@Observable
final class BuildRunner {
    let project: Project
    private(set) var isRunning = false
    private(set) var logLines: [String] = []
    private(set) var result: Int32?   // nil while running; 0 = success, else failure

    private(set) var pid: pid_t = 0
    private var process: SpawnedProcess?
    private var consumeTask: Task<Void, Never>?
    private var lineBuffer = LineBuffer()
    private let maxLogLines = 4000
    /// Set when `stop()` is called so the signal-killed exit isn't reported as a build *failure*.
    private var wasStopped = false

    var onEvent: (@MainActor (SupervisionEvent) -> Void)?
    /// Fired once when the build process exits. `success` is true on exit code 0.
    /// Used by the orchestrator to relaunch a server that was stopped for the build.
    var onFinish: (@MainActor (Bool) -> Void)?

    init(project: Project) { self.project = project }

    var buildCommand: String {
        project.buildCommand ?? "\(project.packageManager.runScriptPrefix) build"
    }

    func start(memoryGB: Int) {
        guard !isRunning else { return }
        // Inject the same heap as the dev server (--max-old-space-size) so a large build doesn't OOM
        // where a bare `npm run build` would. NOTE: only NODE_OPTIONS-allowlisted flags work here —
        // V8 flags like --optimize-for-size are REJECTED ("not allowed in NODE_OPTIONS") and make
        // node exit immediately (code 9), failing every build. Keep it to --max-old-space-size.
        let nodeOpts = ProcessSupport.nodeHeapFlag(memoryGB: memoryGB)
        let command = "NODE_OPTIONS='\(nodeOpts)' FORCE_COLOR=0 exec \(buildCommand)"
        logLines = ["$ \(command)  (cwd: \(project.path))"]
        lineBuffer.reset()
        result = nil
        wasStopped = false
        isRunning = true

        guard let proc = SpawnedProcess.spawn(command: command, cwd: project.path, wantsStdin: false) else {
            isRunning = false
            result = -1
            logLines.append("build: failed to spawn")
            return
        }
        pid = proc.pid
        process = proc

        let stream = proc.chunks   // captured by the consume task; does NOT retain `proc`
        consumeTask = Task { @MainActor [weak self] in
            for await chunk in stream {
                guard let self else { continue }
                switch chunk {
                case .data(let data): self.ingest(data)
                case .eof: self.process?.cancelReader()
                case .exit(let code): self.finish(code: code)
                }
            }
        }
    }

    func stop() {
        guard pid > 0 else { return }
        wasStopped = true
        ProcessSupport.gracefulKillGroup(pid)
    }

    private func ingest(_ data: Data) {
        for line in lineBuffer.ingest(data) {
            if LogNoise.isShellNoise(line) { continue }
            logLines.append(line)
            if logLines.count > maxLogLines { logLines.removeFirst(logLines.count - maxLogLines) }
        }
    }

    private func finish(code: Int32) {
        process?.release()
        pid = 0
        isRunning = false
        result = code
        // A user-initiated stop() kills the process with a signal (non-zero exit); don't post a
        // "Build failed" banner for a build the user deliberately cancelled. The feed/onFinish still
        // fire so the orchestrator can relaunch the paused dev server.
        if wasStopped {
            logLines.append("build stopped")
        } else {
            logLines.append("build finished (code \(code))")
            onEvent?(.buildFinished(project: project.name, success: code == 0))
        }
        onFinish?(code == 0)
    }
}
