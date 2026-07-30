import Foundation
import Observation

/// A single cancellable async job that holds its latest result and a running flag, and guarantees
/// only one runs at a time. Backs the Doctor's three AI analyses (diagnostic report, resource
/// advice, memory advice), which each used to reimplement the same guard → flag → `Task` → cancel
/// dance. `@Observable`, so SwiftUI tracks `output`/`isRunning` even when the job is held by another
/// `@Observable` (e.g. `AppState`).
@MainActor
@Observable
final class AsyncJob<Output> {
    private(set) var output: Output?
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Start `operation` unless one is already running. Clears the previous `output` first; the
    /// result is stored when it finishes (ignored if the job was cancelled meanwhile).
    func run(_ operation: @escaping @MainActor () async -> Output?) {
        guard !isRunning else { return }
        isRunning = true
        output = nil
        task = Task { [weak self] in
            let result = await operation()
            guard let self, !Task.isCancelled else { return }
            self.output = result
            self.isRunning = false
        }
    }

    /// In-place edit of the current result (no-op if there's none) — e.g. removing one row from a
    /// list of recommendations without restarting the job.
    func update(_ transform: (inout Output) -> Void) {
        guard var value = output else { return }
        transform(&value)
        output = value
    }

    /// Cancel the in-flight job, keeping any result already produced.
    func stop() { task?.cancel(); isRunning = false }

    /// Cancel and clear the result.
    func reset() { stop(); output = nil }
}
