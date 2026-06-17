import Foundation
import Observation
import Darwin

/// Supervises a single dev-server process tree: launches it via the C session shim,
/// streams its merged stdout/stderr, parses the port, and stops the whole tree.
@MainActor
@Observable
final class DevSession {
    let project: Project
    private(set) var state: SessionState = .idle
    private(set) var logLines: [String] = []
    private(set) var detectedPort: Int?
    private(set) var pid: pid_t = 0
    private(set) var startedAt: Date?

    private let maxLogLines = 2000
    private var lineBuffer = ""
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var graceTask: Task<Void, Never>?
    private var consumeTask: Task<Void, Never>?
    private var stopping = false

    /// Sendable events flowing from the background reader to the main-actor consumer.
    private enum Chunk: Sendable {
        case data(Data)
        case eof
        case exit(code: Int32)
    }

    init(project: Project) {
        self.project = project
    }

    var effectivePort: Int? { detectedPort ?? project.port }

    func start(memoryGB: Int) {
        guard !state.isActive else { return }
        state = .launching
        stopping = false
        logLines.removeAll()
        lineBuffer = ""
        detectedPort = nil
        startedAt = Date()

        // Silence Apple Terminal's zsh session save/restore lines in captured output.
        setenv("SHELL_SESSIONS_DISABLE", "1", 1)
        let baseCommand = project.devCommand ?? Detector.detect(path: project.path).devCommand
        // Prepend env inline so the login shell applies it; avoids a C env array.
        let command = "NODE_OPTIONS=--max-old-space-size=\(memoryGB * 1024) FORCE_COLOR=0 \(baseCommand)"
        append(line: "▶ \(command)  (cwd: \(project.path))")

        var fd: Int32 = -1
        let childPid = dm_spawn_session(command, project.path, &fd)
        guard childPid > 0, fd >= 0 else {
            state = .failed("spawn failed")
            return
        }
        pid = childPid

        // Background reader + exit watcher → AsyncStream → main-actor consumer.
        // The Dispatch handlers capture only Sendable values (fd, pid, continuation).
        let (stream, continuation) = AsyncStream<Chunk>.makeStream()
        let queue = DispatchQueue(label: "devsession.\(childPid)")

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                continuation.yield(.data(Data(buffer[0..<n])))
            } else {
                continuation.yield(.eof)
            }
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
                case .data(let data):
                    self.ingest(data)
                case .eof:
                    self.readSource?.cancel()
                    self.readSource = nil
                case .exit(let code):
                    self.handleExit(code: code)
                }
            }
        }

        // If no ready/port signal shows up in time, assume ready on the fallback port.
        graceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, case .launching = self.state else { return }
            self.state = .running(port: self.effectivePort ?? 3000)
        }
    }

    func stop() {
        stopping = true
        graceTask?.cancel()
        guard pid > 0 else {
            state = .stopped(code: 0)
            return
        }
        let target = pid
        append(line: "■ stopping (SIGTERM → killpg \(target))")
        killpg(target, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            killpg(target, SIGKILL)
        }
    }

    // MARK: - Output handling

    private func ingest(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lineBuffer += text
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
            lineBuffer.removeSubrange(...nl)
            handle(line: line)
        }
    }

    private func handle(line: String) {
        // Drop shell session-management noise (belt & suspenders alongside SHELL_SESSIONS_DISABLE).
        if line.hasPrefix("Restored session:") || line.contains("Saving session...completed") { return }
        append(line: line)
        if detectedPort == nil,
           let match = line.firstMatch(of: /https?:\/\/[^\s:\/]+:(\d{2,5})/),
           let port = Int(match.1) {
            detectedPort = port
        }
        if case .launching = state {
            let ready = line.contains("Local:")
                || line.range(of: "ready in", options: .caseInsensitive) != nil
                || line.contains("started server")
            if ready {
                graceTask?.cancel()
                state = .running(port: effectivePort)
            }
        }
    }

    private func append(line: String) {
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    private func handleExit(code: Int32) {
        graceTask?.cancel()
        pid = 0
        readSource?.cancel()
        readSource = nil
        exitSource = nil
        switch state {
        case .running, .launching:
            if stopping {
                state = .stopped(code: 0)
            } else {
                state = code == 0 ? .stopped(code: 0) : .failed("exited with code \(code)")
            }
        default:
            break
        }
        append(line: "■ process exited (code \(code))")
    }
}
