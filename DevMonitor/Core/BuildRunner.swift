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
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var consumeTask: Task<Void, Never>?
    private var lineBuffer = ""
    private let maxLogLines = 4000

    var onEvent: (@MainActor (SupervisionEvent) -> Void)?
    /// Fired once when the build process exits. `success` is true on exit code 0.
    /// Used by the orchestrator to relaunch a server that was stopped for the build.
    var onFinish: (@MainActor (Bool) -> Void)?

    private enum Chunk: Sendable { case data(Data); case exit(code: Int32) }

    init(project: Project) { self.project = project }

    var buildCommand: String {
        project.buildCommand ?? "\(project.packageManager.runScriptPrefix) build"
    }

    func start() {
        guard !isRunning else { return }
        let command = "FORCE_COLOR=0 exec \(buildCommand)"
        logLines = ["$ \(command)  (cwd: \(project.path))"]
        lineBuffer = ""
        result = nil
        isRunning = true

        var fd: Int32 = -1
        let childPid = dm_spawn_session(command, project.path, &fd, nil)
        guard childPid > 0, fd >= 0 else {
            isRunning = false
            result = -1
            logLines.append("build: failed to spawn")
            return
        }
        pid = childPid
        let pipeFD = fd  // immutable copy for the @Sendable Dispatch handlers

        let (stream, continuation) = AsyncStream<Chunk>.makeStream()
        let queue = DispatchQueue(label: "build.\(childPid)")

        let reader = DispatchSource.makeReadSource(fileDescriptor: pipeFD, queue: queue)
        reader.setEventHandler { @Sendable in
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            let n = read(pipeFD, &buffer, buffer.count)
            if n > 0 { continuation.yield(.data(Data(buffer[0..<n]))) }
        }
        reader.setCancelHandler { @Sendable in close(pipeFD) }
        reader.resume()
        readSource = reader

        let watcher = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: queue)
        watcher.setEventHandler { @Sendable in
            var status: Int32 = 0
            waitpid(childPid, &status, 0)
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : status
            continuation.yield(.exit(code: code))
        }
        watcher.resume()
        exitSource = watcher

        consumeTask = Task { @MainActor [weak self] in
            for await chunk in stream {
                guard let self else { continue }
                switch chunk {
                case .data(let data): self.ingest(data)
                case .exit(let code): self.finish(code: code)
                }
            }
        }
    }

    func stop() {
        guard pid > 0 else { return }
        let target = pid
        killpg(target, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            killpg(target, SIGKILL)
        }
    }

    private func ingest(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lineBuffer += text
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
            lineBuffer.removeSubrange(...nl)
            if line.hasPrefix("Restored session:") || line.contains("Saving session...completed") { continue }
            logLines.append(line)
            if logLines.count > maxLogLines { logLines.removeFirst(logLines.count - maxLogLines) }
        }
    }

    private func finish(code: Int32) {
        readSource?.cancel()
        readSource = nil
        exitSource = nil
        pid = 0
        isRunning = false
        result = code
        logLines.append("build finished (code \(code))")
        onEvent?(.buildFinished(project: project.name, success: code == 0))
        onFinish?(code == 0)
    }
}
