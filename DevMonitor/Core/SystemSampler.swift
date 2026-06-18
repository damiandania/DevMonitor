import Foundation
import Observation

/// One row in the system process table.
struct ProcessRow: Identifiable, Sendable {
    let id: Int32          // pid (-1 = aggregated dev-server row, -2 = aggregated build row)
    let name: String
    let cpuPerCore: Double // per-core % (can exceed 100)
    let memBytes: Double
    var isDevServer = false
    var isBuild = false
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
    private(set) var systemSwapUsed: Double = 0   // bytes
    private(set) var systemSwapTotal: Double = 0  // bytes
    var systemSwapPercent: Double { systemSwapTotal > 0 ? systemSwapUsed / systemSwapTotal * 100 : 0 }

    // Pressure detection: the machine is "stuck" when CPU stays pinned, or memory is full and
    // actively swapping, for a sustained window. Drives the auto kill-suggestions panel.
    enum Pressure: Sendable { case normal, stuck }
    private(set) var pressure: Pressure = .normal
    private(set) var pressureReason = ""
    /// Fired once when entering the stuck state (normal → stuck).
    var onStuck: (() -> Void)?
    private var hotSince: UInt64?
    private let sustainSeconds = 8.0

    private var prev: [Int32: (cpu: Int64, wall: UInt64)] = [:]
    private var nameCache: [Int32: String] = [:]
    private var richNameCache: [Int32: String] = [:]
    private var prevSysTicks: dm_cpu_ticks?
    private var task: Task<Void, Never>?
    private let topN = 40

    /// Supplies the active dev-server's pids + a readable label, so its whole tree shows as
    /// one clear, highlighted row (e.g. "MiddleSpace :3000") instead of a bare "node".
    var devServerInfo: (@MainActor () -> (pids: Set<Int32>, label: String)?)?
    /// Same, for an in-progress build — its tree shows as one identified row (like the server).
    var buildInfo: (@MainActor () -> (pids: Set<Int32>, label: String)?)?

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
        var sysSwap = dm_mem_info()
        if dm_system_swap(&sysSwap) == 0 {
            systemSwapUsed = Double(sysSwap.used)
            systemSwapTotal = Double(sysSwap.total)
        }

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
        let build = buildInfo?()
        let buildPids = build?.pids ?? []
        var devCPU = 0.0, devMem = 0.0
        var buildCPU = 0.0, buildMem = 0.0
        var others: [ProcessRow] = []
        for row in rows {
            if !devPids.isEmpty, devPids.contains(row.id) {
                devCPU += row.cpuPerCore
                devMem += row.memBytes
            } else if !buildPids.isEmpty, buildPids.contains(row.id) {
                buildCPU += row.cpuPerCore
                buildMem += row.memBytes
            } else {
                others.append(row)
            }
        }

        var result: [ProcessRow] = []
        if let dev, !devPids.isEmpty {
            result.append(ProcessRow(id: -1, name: dev.label, cpuPerCore: devCPU, memBytes: devMem, isDevServer: true))
        }
        // The build always shows (like the server), even when momentarily idle.
        if let build, !buildPids.isEmpty {
            result.append(ProcessRow(id: -2, name: build.label, cpuPerCore: buildCPU, memBytes: buildMem, isBuild: true))
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

        updatePressure()
    }

    private func updatePressure() {
        let cpuHot = systemCPU >= 90
        let memHot = systemMemPercent >= 90 && systemSwapPercent >= 50
        let now = DispatchTime.now().uptimeNanoseconds
        if cpuHot || memHot {
            if hotSince == nil { hotSince = now }
            let elapsed = Double(now &- (hotSince ?? now)) / 1_000_000_000
            if pressure == .normal, elapsed >= sustainSeconds {
                pressure = .stuck
                pressureReason = cpuHot
                    ? "CPU pinned at \(Int(systemCPU))% for \(Int(elapsed))s"
                    : "Memory \(Int(systemMemPercent))% full, swapping (\(Int(systemSwapPercent))%)"
                onStuck?()
            }
        } else if systemCPU < 70, systemMemPercent < 85 {   // hysteresis: clear once it cools
            hotSince = nil
            pressure = .normal
        }
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

    private static func describe(comm: String, args: String) -> String {
        // VS Code / Cursor language servers run from an extension folder referenced in their argv.
        // Read that extension's own package.json so the name comes from the extension, never a
        // hardcoded list. Falls back to the folder name, then to the bare process name.
        guard let dir = extensionDir(inArgs: args) else { return comm }
        return extensionDisplayName(dir: dir) ?? extensionFolderName(dir) ?? comm
    }

    /// The `…/extensions/<publisher>.<name>-<version>` directory referenced by an argv token.
    private static func extensionDir(inArgs args: String) -> String? {
        for token in args.split(separator: " ") {
            guard let ext = token.range(of: "/extensions/"),
                  let pathStart = token.firstIndex(of: "/")           // strip any `--flag=` prefix
            else { continue }
            let afterFolder = token[ext.upperBound...]
            let folderEnd = afterFolder.firstIndex(of: "/") ?? token.endIndex
            return String(token[pathStart..<folderEnd])
        }
        return nil
    }

    /// `displayName` from the extension's package.json, resolving `%key%` via package.nls.json.
    private static func extensionDisplayName(dir: String) -> String? {
        let base = URL(fileURLWithPath: dir)
        guard let data = try? Data(contentsOf: base.appendingPathComponent("package.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var name = (obj["displayName"] as? String) ?? (obj["name"] as? String)
        if let n = name, n.hasPrefix("%"), n.hasSuffix("%"), n.count > 2 {
            let key = String(n.dropFirst().dropLast())
            if let nlsData = try? Data(contentsOf: base.appendingPathComponent("package.nls.json")),
               let nls = try? JSONSerialization.jsonObject(with: nlsData) as? [String: Any] {
                name = (nls[key] as? String) ?? ((nls[key] as? [String: Any])?["message"] as? String) ?? n
            }
        }
        guard let result = name, !result.isEmpty else { return nil }
        return result
    }

    /// Last-resort readable name from the folder `publisher.name-version` → `name`.
    private static func extensionFolderName(_ dir: String) -> String? {
        let folder = (dir as NSString).lastPathComponent
        let afterPublisher = folder.split(separator: ".").dropFirst().joined(separator: ".")
        let base = afterPublisher.isEmpty ? folder : afterPublisher
        // Drop a trailing -1.2.3 version.
        let parts = base.split(separator: "-")
        let nameParts = parts.prefix { !($0.first?.isNumber ?? false) }
        let name = nameParts.joined(separator: "-")
        return name.isEmpty ? nil : name
    }
}
