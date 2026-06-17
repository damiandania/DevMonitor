import Foundation
import Observation

/// One row in the system process table.
struct ProcessRow: Identifiable, Sendable {
    let id: Int32          // pid (-1 = aggregated dev-server row)
    let name: String
    let cpuPerCore: Double // per-core % (can exceed 100)
    let memBytes: Double
    var isDevServer = false
}

/// Samples ALL system processes (~2 Hz) and exposes the top consumers, like Activity Monitor.
@MainActor
@Observable
final class SystemSampler {
    private(set) var processes: [ProcessRow] = []
    let coreCount: Int
    private(set) var totalMem: Double = 0
    private(set) var systemCPU: Double = 0        // 0…100
    private(set) var systemMemUsed: Double = 0    // bytes
    var systemMemPercent: Double { totalMem > 0 ? systemMemUsed / totalMem * 100 : 0 }

    private var prev: [Int32: (cpu: Int64, wall: UInt64)] = [:]
    private var nameCache: [Int32: String] = [:]
    private var richNameCache: [Int32: String] = [:]
    private var prevSysTicks: dm_cpu_ticks?
    private var task: Task<Void, Never>?
    private let topN = 40

    /// Supplies the active dev-server's pids + a readable label, so its whole tree shows as
    /// one clear, highlighted row (e.g. "MiddleSpace :3000") instead of a bare "node".
    var devServerInfo: (@MainActor () -> (pids: Set<Int32>, label: String)?)?

    init() {
        coreCount = max(1, ProcessInfo.processInfo.processorCount)
        var mem = dm_mem_info()
        _ = dm_system_mem(&mem)
        totalMem = Double(mem.total)
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func sample() {
        // System-wide CPU (tick deltas) and memory for the top progress bars.
        var ticks = dm_cpu_ticks()
        _ = dm_system_cpu_ticks(&ticks)
        if let prevTicks = prevSysTicks {
            let dTotal = Double(ticks.total &- prevTicks.total)
            let dIdle = Double(ticks.idle &- prevTicks.idle)
            if dTotal > 0 { systemCPU = max(0, min(100, (1 - dIdle / dTotal) * 100)) }
        }
        prevSysTicks = ticks
        var sysMem = dm_mem_info()
        _ = dm_system_mem(&sysMem)
        systemMemUsed = Double(sysMem.used)

        let now = DispatchTime.now().uptimeNanoseconds
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(dm_all_pids(&pids, 8192))

        var rows: [ProcessRow] = []
        rows.reserveCapacity(count)
        var newPrev: [Int32: (cpu: Int64, wall: UInt64)] = [:]
        var seenNames: [Int32: String] = [:]
        var nameBuffer = [CChar](repeating: 0, count: 1024)

        for i in 0..<count {
            let pid = pids[i]
            if pid <= 0 { continue }
            let stat = dm_proc_stat_for(pid)
            if stat.valid != 1 { continue }

            newPrev[pid] = (stat.cpu_time_ns, now)
            var cpu = 0.0
            if let p = prev[pid], stat.cpu_time_ns >= p.cpu, now > p.wall {
                cpu = Double(stat.cpu_time_ns - p.cpu) / Double(now - p.wall) * 100
            }

            let name: String
            if let cached = nameCache[pid] {
                name = cached
            } else if Int(dm_proc_name(pid, &nameBuffer, 1024)) > 0 {
                name = String(cString: nameBuffer)
            } else {
                name = "pid \(pid)"
            }
            seenNames[pid] = name

            rows.append(ProcessRow(id: pid, name: name, cpuPerCore: cpu, memBytes: Double(stat.phys_footprint)))
        }

        prev = newPrev
        nameCache = seenNames  // drop dead pids

        // Group the active dev-server's whole tree into one clear, highlighted row; otherwise
        // surface only processes with a real performance impact (heavy CPU or heavy memory).
        let cores = Double(coreCount)
        let heavyMem = 600.0 * 1_048_576  // 600 MB
        let busyCPUPerCore = 25.0         // ~a quarter of a core or more
        func impact(_ row: ProcessRow) -> Double {
            row.cpuPerCore / cores + (totalMem > 0 ? row.memBytes / totalMem * 100 : 0)
        }

        let dev = devServerInfo?()
        let devPids = dev?.pids ?? []
        var devCPU = 0.0
        var devMem = 0.0
        var others: [ProcessRow] = []
        for row in rows {
            if !devPids.isEmpty, devPids.contains(row.id) {
                devCPU += row.cpuPerCore
                devMem += row.memBytes
            } else {
                others.append(row)
            }
        }

        var result: [ProcessRow] = []
        if let dev, !devPids.isEmpty {
            result.append(ProcessRow(id: -1, name: dev.label, cpuPerCore: devCPU, memBytes: devMem, isDevServer: true))
        }
        result.append(contentsOf: others
            .filter { $0.cpuPerCore >= busyCPUPerCore || $0.memBytes >= heavyMem }
            .sorted { impact($0) > impact($1) }
            .prefix(topN))

        // Give generic helpers (VS Code language servers, bare "node", …) a readable name
        // derived from their argv — only for the few shown rows, and cached per pid.
        processes = result.map { row in
            guard row.id > 0, Self.isGeneric(row.name) else { return row }
            let better = self.enrichedName(pid: row.id, comm: row.name)
            return better == row.name ? row
                : ProcessRow(id: row.id, name: better, cpuPerCore: row.cpuPerCore,
                             memBytes: row.memBytes, isDevServer: row.isDevServer)
        }
        let liveIDs = Set(result.map { $0.id })
        richNameCache = richNameCache.filter { liveIDs.contains($0.key) }
    }

    private static func isGeneric(_ name: String) -> Bool {
        name.contains("Helper") || name == "node" || name == "Electron"
    }

    private func enrichedName(pid: Int32, comm: String) -> String {
        if let cached = richNameCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 8192)
        let n = Int(dm_proc_args(pid, &buffer, 8192))
        let args = n > 0 ? String(cString: buffer) : ""
        let result = Self.describe(comm: comm, args: args)
        richNameCache[pid] = result
        return result
    }

    private static let hints: [(String, String)] = [
        ("tailwindserver", "Tailwind CSS"), ("vscode-tailwindcss", "Tailwind CSS"),
        ("eslintserver", "ESLint"), ("vscode-eslint", "ESLint"),
        ("volar", "Volar (Vue)"), ("vue-language", "Volar (Vue)"),
        ("tsserver", "TypeScript"), ("typescript-language", "TypeScript"),
        ("jsonservermain", "JSON LS"), ("cssservermain", "CSS LS"),
        ("html-language", "HTML LS"), ("copilot", "Copilot"),
        ("intelephense", "Intelephense (PHP)"), ("pylance", "Pylance"), ("pyright", "Pyright"),
        ("rust-analyzer", "rust-analyzer"), ("gopls", "gopls"),
        ("prettier", "Prettier"), ("emmet", "Emmet"), ("graphql", "GraphQL"),
        ("astro", "Astro LS"), ("svelte", "Svelte LS"), ("markdown", "Markdown LS"),
        ("github-actions", "GitHub Actions"), ("docker", "Docker"), ("prisma", "Prisma"),
    ]

    private static func describe(comm: String, args: String) -> String {
        let lower = args.lowercased()
        for (needle, name) in hints where lower.contains(needle) {
            return "\(name) — \(comm)"
        }
        // Fallback: VS Code extension folder like ".../extensions/publisher.name-1.2.3/..."
        if let range = lower.range(of: "/extensions/") {
            let rest = lower[range.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                let folder = String(rest[..<slash])
                if let dot = folder.firstIndex(of: ".") {
                    let after = folder[folder.index(after: dot)...]
                    let ext = after.split(separator: "-").first.map(String.init) ?? folder
                    if !ext.isEmpty { return "\(ext) — \(comm)" }
                }
            }
        }
        return comm
    }
}
