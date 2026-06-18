import Foundation

/// Runs the already-logged-in `claude` CLI to produce a READ-ONLY diagnostic report about Dev
/// Monitor itself — it never edits files. Points claude at the app's own source tree and feeds
/// the internal log on stdin.
enum ClaudeRunner {
    struct Report: Sendable {
        var text: String
        var isError: Bool
        var costUSD: Double?
    }

    /// Dev Monitor's own source tree (where the app is developed).
    static let sourcePath = NSHomeDirectory() + "/dev/DevMonitor"

    static func diagnose(internalLog: String) async -> Report {
        let prompt = """
        You are diagnosing **Dev Monitor**, a native macOS SwiftUI app whose source is the current
        working directory. Below is a tail of its internal event log. Identify the most likely root
        cause of any error or anomaly, name the file/function involved, and suggest a concrete fix.
        Be concise (a short report). DO NOT modify any files.

        --- Dev Monitor internal log ---
        \(internalLog)
        """
        return await run(prompt: prompt, cwd: sourcePath)
    }

    /// Runs `claude -p` read-only with `prompt` on stdin, in `cwd`, and parses the JSON result.
    /// Read-only by construction: `--permission-mode plan` + disallowed write tools. An optional
    /// `model` (e.g. "claude-haiku-4-5") selects a faster/cheaper model for quick evaluations.
    static func run(prompt: String, cwd: String, model: String? = nil) async -> Report {
        await withCheckedContinuation { (continuation: CheckedContinuation<Report, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                let modelFlag = model.map { " --model \($0)" } ?? ""
                process.arguments = ["-lc",
                    "claude -p --output-format json --permission-mode plan\(modelFlag) "
                    + "--disallowed-tools 'Edit Write MultiEdit NotebookEdit' --no-session-persistence"]
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)

                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Report(
                        text: "Could not launch claude: \(error.localizedDescription)",
                        isError: true, costUSD: nil))
                    return
                }

                if let data = prompt.data(using: .utf8) {
                    stdin.fileHandleForWriting.write(data)
                }
                try? stdin.fileHandleForWriting.close()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if let object = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                   let result = object["result"] as? String {
                    continuation.resume(returning: Report(
                        text: result,
                        isError: (object["is_error"] as? Bool) ?? false,
                        costUSD: object["total_cost_usd"] as? Double))
                } else {
                    let raw = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(returning: Report(
                        text: raw.isEmpty ? "claude produced no output." : raw,
                        isError: true, costUSD: nil))
                }
            }
        }
    }
}
