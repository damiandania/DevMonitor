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

    private var prev: [Int32: (cpu: Int64, wall: UInt64)] = [:]
    private var nameCache: [Int32: String] = [:]
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
        processes = result
    }
}
