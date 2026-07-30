import Foundation
import Darwin

/// A child process launched through the `dm_spawn_session` C shim (a login, non-interactive
/// `zsh -lc` whose `exec`'d command becomes the session leader, so the whole tree is enumerable and
/// killable by group). Exposes the merged stdout/stderr as an `AsyncStream<Chunk>` and delivers the
/// final exit as a `.exit(code:)`. Owns the two `DispatchSource`s that drive it.
///
/// This is the single place the spawn → `DispatchSource` (read + exit) → `AsyncStream` plumbing
/// lives; `DevSession` and `BuildRunner` consume the stream and layer their own policy on top
/// (port detection / health for the server, nothing extra for a build). All members are touched
/// only on the owner's actor (`@MainActor`); the `@Sendable` source handlers capture just value
/// types (the fd, pid and the `Sendable` continuation), never `self`.
final class SpawnedProcess {
    enum Chunk: Sendable {
        case data(Data)
        case eof
        case exit(code: Int32)
    }

    /// 64 KB — one read per wakeup of the pipe's read source.
    private static let readBufferSize = 1 << 16

    let pid: pid_t
    /// Write end of the child's stdin, or `-1` when no stdin pipe was requested. The consumer owns
    /// closing it (e.g. `DevSession.closeStdin`).
    let stdinFD: Int32
    /// Merged stdout/stderr as it arrives, terminated by a single `.exit(code:)`.
    let chunks: AsyncStream<Chunk>

    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    private init(pid: pid_t, stdinFD: Int32, chunks: AsyncStream<Chunk>,
                 readSource: DispatchSourceRead, exitSource: DispatchSourceProcess) {
        self.pid = pid
        self.stdinFD = stdinFD
        self.chunks = chunks
        self.readSource = readSource
        self.exitSource = exitSource
    }

    /// Spawn `command` in `cwd`. `wantsStdin` opens a stdin pipe (`stdinFD`); otherwise it's `-1`.
    /// Returns `nil` if the spawn fails or no readable output pipe came back.
    static func spawn(command: String, cwd: String, wantsStdin: Bool) -> SpawnedProcess? {
        var fd: Int32 = -1
        var inFD: Int32 = -1
        let childPid = wantsStdin
            ? dm_spawn_session(command, cwd, &fd, &inFD)
            : dm_spawn_session(command, cwd, &fd, nil)
        guard childPid > 0, fd >= 0 else { return nil }
        let pipeFD = fd   // immutable copy for the @Sendable Dispatch handlers
        let (stream, continuation) = AsyncStream<Chunk>.makeStream()
        let queue = DispatchQueue(label: "spawned.\(childPid)")

        let reader = DispatchSource.makeReadSource(fileDescriptor: pipeFD, queue: queue)
        reader.setEventHandler { @Sendable in
            var buffer = [UInt8](repeating: 0, count: SpawnedProcess.readBufferSize)
            let n = read(pipeFD, &buffer, buffer.count)
            continuation.yield(n > 0 ? .data(Data(buffer[0..<n])) : .eof)
        }
        reader.setCancelHandler { @Sendable in close(pipeFD) }
        reader.resume()

        let watcher = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: queue)
        watcher.setEventHandler { @Sendable in
            var status: Int32 = 0
            waitpid(childPid, &status, 0)
            continuation.yield(.exit(code: ProcessSupport.decodeExitCode(status)))
        }
        watcher.resume()

        return SpawnedProcess(pid: childPid, stdinFD: wantsStdin ? inFD : -1, chunks: stream,
                              readSource: reader, exitSource: watcher)
    }

    /// Stop streaming output (cancels the read source, which closes the pipe fd). Idempotent.
    /// Used on `.eof`, when the child has closed its output but not yet exited.
    func cancelReader() {
        readSource?.cancel()
        readSource = nil
    }

    /// Tear down after the process has exited: cancel the reader and drop both sources (the exit
    /// watcher is one-shot and has already fired). Releasing the sources frees their handlers, which
    /// hold the stream's continuation, so the `chunks` stream finishes.
    func release() {
        readSource?.cancel()
        readSource = nil
        exitSource = nil
    }
}
