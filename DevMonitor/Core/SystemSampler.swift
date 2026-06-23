import Foundation
import Observation

/// One row in the system process table.
struct ProcessRow: Identifiable, Sendable {
    let id: Int32          // pid (negative = a synthetic aggregated row: -2 = build, else -pid)
    let name: String
    let cpuPerCore: Double // per-core % (can exceed 100)
    let memBytes: Double
    var isDevServer = false      // a server SUPERVISED by the app (managed tree)
    var isBuild = false
    var isWorker = false         // a background worker SUPERVISED by the app (managed tree)
    var isExternalDev = false    // a dev server running OUTSIDE the app (identified, not supervised)
    var isExtension = false      // a VS Code / Cursor extension language-server helper
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
    private(set) var loadAverage: Double = 0      // 1-minute load average
    /// The managed dev-server tree's aggregated CPU% (per-core) and memory, for optional bars.
    var devTreeCPU: Double { processes.first { $0.isDevServer }?.cpuPerCore ?? 0 }
    var devTreeMem: Double { processes.first { $0.isDevServer }?.memBytes ?? 0 }

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
    private var richNameCache: [Int32: (name: String, ext: Bool, isExtension: Bool)] = [:]
    private var prevSysTicks: dm_cpu_ticks?
    private var task: Task<Void, Never>?
    private let topN = 40

    /// Supplies one entry PER supervised dev server (id + pids + readable label), so each shows as
    /// its own highlighted row (e.g. "MiddleSpace :3000") instead of a bare "node" or one merged row.
    var devServerInfo: (@MainActor () -> [(id: Int32, pids: Set<Int32>, label: String)])?
    /// Same, for an in-progress build — its tree shows as one identified row (like the server).
    var buildInfo: (@MainActor () -> (pids: Set<Int32>, label: String)?)?
    /// One entry PER running background worker, so each shows as its own highlighted row
    /// (e.g. "MiddleSpace · worker"), like a supervised server.
    var workerInfo: (@MainActor () -> [(id: Int32, pids: Set<Int32>, label: String)])?

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
        loadAverage = dm_load_avg()

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

        // Aggregate the dev-server and build trees into single identified rows; otherwise surface
        // only processes with a real performance impact. (Pure + testable — see SystemSampler.aggregate.)
        let result = Self.aggregate(rows: rows, devs: devServerInfo?() ?? [], build: buildInfo?(),
                                    workers: workerInfo?() ?? [],
                                    coreCount: coreCount, totalMem: totalMem, topN: topN)

        // Give generic helpers (VS Code language servers, bare "node", …) a readable name
        // derived from their argv — only for the few shown rows, and cached per pid.
        processes = result.map { row in
            guard row.id > 0, Self.isGeneric(row.name) else { return row }
            let e = self.enrichedName(pid: row.id, comm: row.name)
            if !e.ext && !e.isExtension && e.name == row.name { return row }
            return ProcessRow(id: row.id, name: e.name, cpuPerCore: row.cpuPerCore,
                              memBytes: row.memBytes, isDevServer: row.isDevServer,
                              isBuild: row.isBuild, isExternalDev: e.ext,
                              isExtension: e.isExtension)
        }
        let liveIDs = Set(result.map { $0.id })
        richNameCache = richNameCache.filter { liveIDs.contains($0.key) }

        updatePressure()
    }

    private func updatePressure() {
        let now = DispatchTime.now().uptimeNanoseconds
        let r = Self.evaluatePressure(cpu: systemCPU, memPercent: systemMemPercent,
                                      swapPercent: systemSwapPercent, hotSince: hotSince,
                                      now: now, sustainSeconds: sustainSeconds, current: pressure)
        hotSince = r.hotSince
        pressure = r.pressure
        if r.justStuck {
            pressureReason = r.reason
            onStuck?()
        }
    }

    // MARK: - Pure logic (testable without the C metrics or the run loop)

    /// Aggregates each dev-server tree into its OWN identified row, the build tree into one row
    /// (id -2), and keeps only other processes with real impact (heavy CPU or memory), ranked,
    /// capped at `topN`.
    nonisolated static func aggregate(
        rows: [ProcessRow],
        devs: [(id: Int32, pids: Set<Int32>, label: String)],
        build: (pids: Set<Int32>, label: String)?,
        workers: [(id: Int32, pids: Set<Int32>, label: String)] = [],
        coreCount: Int, totalMem: Double, topN: Int
    ) -> [ProcessRow] {
        let cores = Double(coreCount)
        let heavyMem = 600.0 * 1_048_576   // 600 MB
        let busyCPUPerCore = 25.0          // ~a quarter of a core or more
        func impact(_ row: ProcessRow) -> Double {
            row.cpuPerCore / cores + (totalMem > 0 ? row.memBytes / totalMem * 100 : 0)
        }
        // Map each pid to its dev-server / worker index so trees are summed PER process, not together.
        var devIndexByPid: [Int32: Int] = [:]
        for (i, d) in devs.enumerated() { for p in d.pids { devIndexByPid[p] = i } }
        var workerIndexByPid: [Int32: Int] = [:]
        for (i, w) in workers.enumerated() { for p in w.pids { workerIndexByPid[p] = i } }
        let buildPids = build?.pids ?? []

        var devCPU = [Double](repeating: 0, count: devs.count)
        var devMem = [Double](repeating: 0, count: devs.count)
        var workerCPU = [Double](repeating: 0, count: workers.count)
        var workerMem = [Double](repeating: 0, count: workers.count)
        var buildCPU = 0.0, buildMem = 0.0
        var others: [ProcessRow] = []
        for row in rows {
            if let gi = devIndexByPid[row.id] {
                devCPU[gi] += row.cpuPerCore; devMem[gi] += row.memBytes
            } else if let wi = workerIndexByPid[row.id] {
                workerCPU[wi] += row.cpuPerCore; workerMem[wi] += row.memBytes
            } else if !buildPids.isEmpty, buildPids.contains(row.id) {
                buildCPU += row.cpuPerCore; buildMem += row.memBytes
            } else {
                others.append(row)
            }
        }
        var result: [ProcessRow] = []
        // One row per supervised server (always shown, even when momentarily idle).
        for (i, d) in devs.enumerated() {
            result.append(ProcessRow(id: d.id, name: d.label, cpuPerCore: devCPU[i],
                                     memBytes: devMem[i], isDevServer: true))
        }
        // One row per running worker.
        for (i, w) in workers.enumerated() {
            result.append(ProcessRow(id: w.id, name: w.label, cpuPerCore: workerCPU[i],
                                     memBytes: workerMem[i], isWorker: true))
        }
        if let build, !buildPids.isEmpty {
            result.append(ProcessRow(id: -2, name: build.label, cpuPerCore: buildCPU, memBytes: buildMem, isBuild: true))
        }
        result.append(contentsOf: others
            .filter { $0.cpuPerCore >= busyCPUPerCore || $0.memBytes >= heavyMem }
            .sorted { impact($0) > impact($1) }
            .prefix(topN))
        return result
    }

    /// Pure pressure state machine: stuck when CPU is pinned, or memory is full while swapping, for
    /// a sustained window; clears with hysteresis. `justStuck` marks the normal → stuck transition.
    nonisolated static func evaluatePressure(
        cpu: Double, memPercent: Double, swapPercent: Double,
        hotSince: UInt64?, now: UInt64, sustainSeconds: Double, current: Pressure
    ) -> (pressure: Pressure, reason: String, hotSince: UInt64?, justStuck: Bool) {
        let cpuHot = cpu >= 90
        let memHot = memPercent >= 90 && swapPercent >= 50
        if cpuHot || memHot {
            let since = hotSince ?? now
            let elapsed = Double(now &- since) / 1_000_000_000
            if current == .normal, elapsed >= sustainSeconds {
                let reason = cpuHot
                    ? "CPU pinned at \(Int(cpu))% for \(Int(elapsed))s"
                    : "Memory \(Int(memPercent))% full, swapping (\(Int(swapPercent))%)"
                return (.stuck, reason, since, true)
            }
            return (current, "", since, false)
        } else if cpu < 70, memPercent < 85 {   // hysteresis: clear once it cools
            return (.normal, "", nil, false)
        }
        return (current, "", hotSince, false)
    }

    private static func isGeneric(_ name: String) -> Bool {
        name.contains("Helper") || name == "node" || name == "Electron"
            || (name.first?.isNumber ?? false)                       // version-like ("2.1.179")
            || name.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
    }

    private func enrichedName(pid: Int32, comm: String) -> (name: String, ext: Bool, isExtension: Bool) {
        if let cached = richNameCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 8192)
        let n = Int(dm_proc_args(pid, &buffer, 8192))
        let args = n > 0 ? String(cString: buffer) : ""
        // A dev server started OUTSIDE the app: identify it like the managed one
        // ("MiddleSpace :3001") instead of a bare "node", and flag it external so the table can
        // give it the same format in a different colour. It stays unsupervised (no probe/recycle).
        if ResourceAdvisor.looksLikeDevServer(argv: args) {
            let project = Self.projectName(fromArgs: args) ?? comm
            let port = Int(dm_proc_listen_port(pid))
            let entry = (name: project + (port > 0 ? " :\(port)" : ""), ext: true, isExtension: false)
            if port > 0 { richNameCache[pid] = entry }   // cache once the port binds (it can be late)
            return entry
        }
        let d = Self.describe(comm: comm, args: args)
        let entry = (name: d.name, ext: false, isExtension: d.isExtension)
        richNameCache[pid] = entry
        return entry
    }

    /// The project folder name from a dev-server argv: the directory just before `/node_modules/`
    /// (e.g. ".../MiddleSpace/node_modules/.bin/nuxt" → "MiddleSpace"). nil if not derivable.
    nonisolated static func projectName(fromArgs args: String) -> String? {
        guard let r = args.range(of: "/node_modules/") else { return nil }
        let before = args[..<r.lowerBound]
        guard let slash = before.lastIndex(of: "/") else { return nil }
        let name = String(before[before.index(after: slash)...])
        return name.isEmpty ? nil : name
    }

    private static func describe(comm: String, args: String) -> (name: String, isExtension: Bool) {
        // VS Code / Cursor language servers run from an extension folder referenced in their argv.
        // Read that extension's own package.json so the name comes from the extension, never a
        // hardcoded list. Falls back to the folder name, then the .app bundle, then the bare name.
        if let dir = extensionDir(inArgs: args),
           let name = extensionDisplayName(dir: dir) ?? extensionFolderName(dir) {
            return (name, true)
        }
        // Otherwise identify the owning app from the bundle path in argv
        // (e.g. ".../Claude.app/Contents/Helpers/.../2.1.179" → "Claude").
        return (appBundleName(inArgs: args) ?? comm, false)
    }

    /// The `<Name>` of the first `…/<Name>.app/…` bundle referenced in argv.
    private static func appBundleName(inArgs args: String) -> String? {
        guard let r = args.range(of: ".app/") else { return nil }
        let before = args[..<r.lowerBound]
        guard let slash = before.lastIndex(of: "/") else { return nil }
        let name = String(before[before.index(after: slash)...])
        return name.isEmpty ? nil : name
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
