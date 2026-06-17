import Foundation

/// P9 — asks the logged-in `claude` (READ-ONLY) what to do about the machine's heavy processes,
/// then hands back ranked recommendations. Execution policy is enforced by the caller:
/// managed dev-server processes may be stopped automatically; any *foreign* process (editors,
/// browsers, daemons) is only ever closed after an explicit user confirmation — never auto-killed.
enum ResourceAdvisor {
    enum Action: String, Sendable {
        case keep, investigate
        case stopDevServer = "stop_dev_server"
        case closeProcess = "close_process"
    }

    enum Severity: String, Sendable, Comparable {
        case low, medium, high
        private var rank: Int { self == .high ? 2 : (self == .medium ? 1 : 0) }
        static func < (l: Severity, r: Severity) -> Bool { l.rank < r.rank }
    }

    struct Recommendation: Sendable, Identifiable {
        let id: Int32          // pid; -1 = the aggregated managed dev-server tree
        let name: String
        let action: Action
        let severity: Severity
        let reason: String
        /// Managed dev process (our session tree) → safe to stop automatically.
        /// Foreign process → must be confirmed by the user before closing.
        var managed: Bool { action == .stopDevServer || id == -1 }
    }

    struct Advice: Sendable {
        var summary: String
        var recommendations: [Recommendation]
        var isError: Bool
        var costUSD: Double?
    }

    /// One process as fed to the model. `managedDev` flags the supervised dev-server tree.
    struct Proc: Sendable {
        let pid: Int32
        let name: String
        let cpuPerCore: Double
        let memMB: Double
        let managedDev: Bool
    }

    /// Human/model-readable snapshot of the current pressure + heavy processes.
    static func snapshotText(systemCPU: Double, systemMemPercent: Double,
                             coreCount: Int, procs: [Proc]) -> String {
        var lines = [
            "System CPU: \(Int(systemCPU))% of \(coreCount) cores",
            "System memory: \(Int(systemMemPercent))% used",
            "",
            "Heavy processes (cpu is per-core %, can exceed 100):",
        ]
        if procs.isEmpty {
            lines.append("  (none above the impact threshold)")
        }
        for p in procs {
            let tag = p.managedDev ? "[DEV SERVER — managed by Dev Monitor]" : "[foreign]"
            let pidStr = p.pid >= 0 ? "pid \(p.pid)" : "tree"
            lines.append(String(format: "  %@  %@  cpu %.0f%%  mem %.0f MB  %@",
                                pidStr, p.name, p.cpuPerCore, p.memMB, tag))
        }
        return lines.joined(separator: "\n")
    }

    static func advise(systemCPU: Double, systemMemPercent: Double,
                       coreCount: Int, procs: [Proc]) async -> Advice {
        let snapshot = snapshotText(systemCPU: systemCPU, systemMemPercent: systemMemPercent,
                                    coreCount: coreCount, procs: procs)
        let prompt = """
        You are the resource advisor inside **Dev Monitor** on a Mac with \(coreCount) CPU cores.
        Below is a live snapshot of system pressure and the heaviest processes. Decide what the user
        should do to keep the machine responsive.

        Rules:
        - A process tagged [DEV SERVER — managed by Dev Monitor] can be stopped safely → action
          "stop_dev_server" (the app will do it automatically).
        - A [foreign] process (code editors, browsers, language servers, system daemons) must NEVER
          be killed automatically. Only recommend "close_process" when it is clearly a runaway, and
          know the user will be asked to confirm before anything is closed.
        - Otherwise use "keep" (fine as-is) or "investigate" (worth a look, no action).
        - Be conservative: prefer "keep"/"investigate" over closing things.

        Reply with ONLY a JSON object, no prose:
        {
          "summary": "one sentence on overall machine health",
          "recommendations": [
            {"pid": <int, -1 for the dev-server tree>, "action": "keep|investigate|stop_dev_server|close_process",
             "severity": "low|medium|high", "reason": "short, specific"}
          ]
        }

        --- snapshot ---
        \(snapshot)
        """

        let report = await ClaudeRunner.run(prompt: prompt, cwd: NSHomeDirectory())
        let names = Dictionary(procs.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
        let parsed = parse(report.text, names: names)
        return Advice(summary: parsed.summary, recommendations: parsed.recs,
                      isError: report.isError, costUSD: report.costUSD)
    }

    /// Tolerant JSON extraction: claude may wrap the object in prose or code fences.
    static func parse(_ text: String, names: [Int32: String]) -> (summary: String, recs: [Recommendation]) {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (text.isEmpty ? "No advice." : text, []) }

        let summary = obj["summary"] as? String ?? ""
        let rawRecs = obj["recommendations"] as? [[String: Any]] ?? []
        let recs: [Recommendation] = rawRecs.compactMap { r in
            let pid = Int32((r["pid"] as? Int) ?? -1)
            guard let action = Action(rawValue: (r["action"] as? String) ?? "keep") else { return nil }
            let severity = Severity(rawValue: (r["severity"] as? String) ?? "low") ?? .low
            let reason = r["reason"] as? String ?? ""
            let name = names[pid] ?? (pid == -1 ? "Dev server" : "pid \(pid)")
            return Recommendation(id: pid, name: name, action: action, severity: severity, reason: reason)
        }
        .sorted { $0.severity > $1.severity }
        return (summary, recs)
    }
}
