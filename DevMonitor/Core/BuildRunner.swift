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

    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var consumeTask: Task<Void, Never>?
    private var lineBuffer = ""
    private let maxLogLines = 4000

    var onEvent: (@MainActor (SupervisionEvent) -> Void)?

    private enum Chunk: Sendable { case data(Data); case exit(code: Int32) }

    init(project: Project) { self.project = project }

    var buildCommand: String {
        project.buildCommand ?? "\(project.packageManager.runScriptPrefix) build"
    }

    func start() {
        guard !isRunning else { return }
        let command = "FORCE_COLOR=0 exec \(buildCommand)"
        logLines = ["▶ \(command)  (cwd: \(project.path))"]
        lineBuffer = ""
        result = nil
        isRunning = true

        var fd: Int32 = -1
        let childPid = dm_spawn_session(command, project.path, &fd)
        guard childPid > 0, fd >= 0 else {
            isRunning = false
            result = -1
            logLines.append("■ failed to spawn build")
            return
        }
        pid = childPid

        let (stream, continuation) = AsyncStream<Chunk>.makeStream()
        let queue = DispatchQueue(label: "build.\(childPid)")

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { continuation.yield(.data(Data(buffer[0..<n]))) }
        }
        reader.setCancelHandler { close(fd) }
        reader.resume()
        readSource = reader

        let watcher = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: queue)
        watcher.setEventHandler {
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
        logLines.append("■ build finished (code \(code))")
        onEvent?(.buildFinished(project: project.name, success: code == 0))
    }
}
