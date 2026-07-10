import Foundation
import Observation

/// Claude subscription usage for the notch HUD / mascot. `claude -p "/usage"` is the one reliable
/// local source: the statusline only carries `rate_limits` while an interactive session happens to be
/// rendering it (not guaranteed, and absent in IDE/SDK contexts). We run it off-main on a slow cadence
/// and parse the two headline percentages — the rolling 5-hour window ("Current session") and the
/// 7-day window ("Current week (all models)").
@MainActor
@Observable
final class ClaudeQuotaMonitor {
    private(set) var fiveHour: Int?
    private(set) var sevenDay: Int?
    private(set) var updatedAt: Date?

    /// Refreshed every ~15 min; treat a reading older than 20 min as stale (a poll failed).
    var isStale: Bool {
        guard let updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > 20 * 60
    }

    /// True once we've ever parsed a reading — lets the HUD stay bare until the first result lands.
    var hasData: Bool { fiveHour != nil || sevenDay != nil }

    private var timer: Timer?

    init() {
        refresh()
        // Each poll spawns a `claude` process (a few seconds), so keep the cadence slow — the 5h/7d
        // windows move slowly, so ~15-min granularity is plenty.
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Fetch + parse off the main actor, then publish on it.
    func refresh() {
        Task.detached(priority: .utility) {
            guard let text = Self.fetchUsage() else { return }
            let five = Self.percent(after: "Current session:", in: text)
            let seven = Self.percent(after: "Current week (all models):", in: text)
            guard five != nil || seven != nil else { return }
            await MainActor.run {
                if let five { self.fiveHour = five }
                if let seven { self.sevenDay = seven }
                self.updatedAt = Date()
            }
        }
    }

    /// Runs `claude -p "/usage"` through a login shell (so `claude` resolves on PATH, as ClaudeRunner
    /// does) and returns its stdout. Blocking — only call off the main actor.
    ///
    /// Kept deliberately low-footprint, because this child is launched by Dev Monitor and macOS
    /// attributes anything it touches back to Dev Monitor (TCC prompts for Downloads/Music/Desktop/…):
    ///   • runs in an EMPTY cwd — claude treats its cwd as the project, and the app's inherited cwd is
    ///     `/`, so it would walk down into the protected `~/Desktop`, `~/Documents`, `~/Downloads`, …;
    ///     an empty scratch dir gives it nothing to scan.
    ///   • `--strict-mcp-config` loads NO MCP servers — `/usage` needs none, and a server starting up is
    ///     another thing that can reach into guarded folders (and it drags the poll out).
    ///   • stdin is `/dev/null` so claude doesn't stall ~3s waiting for piped input.
    nonisolated private static func fetchUsage() -> String? {
        let probeDir = FileManager.default.temporaryDirectory.appendingPathComponent("dm-quota-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "claude -p '/usage' --strict-mcp-config"]
        process.currentDirectoryURL = probeDir
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// The integer just before the first `%` following `label` — e.g. `label` "Current session:" in
    /// "Current session: 5% used" yields 5.
    nonisolated private static func percent(after label: String, in text: String) -> Int? {
        guard let start = text.range(of: label) else { return nil }
        var digits = ""
        for ch in text[start.upperBound...] {
            if ch.isNumber { digits.append(ch) }
            else if ch == "%" { return Int(digits) }
            else if !digits.isEmpty { return nil }   // a non-digit split the number off from its %
        }
        return nil
    }
}
