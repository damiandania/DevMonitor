import Foundation

/// JS/TS package manager, detected from the project's lockfile.
enum PackageManager: String, Codable, Sendable, CaseIterable {
    case npm, pnpm, yarn, bun, deno

    /// The run prefix for a script (e.g. `npm run`, `pnpm`).
    var runScriptPrefix: String {
        switch self {
        case .npm: return "npm run"
        case .pnpm: return "pnpm"
        case .yarn: return "yarn"
        case .bun: return "bun run"
        case .deno: return "deno task"
        }
    }
}

/// Detected web framework, drives the default dev command, port and ready-signal.
enum Framework: String, Codable, Sendable, CaseIterable {
    case nuxt, next, astro, sveltekit, remix, solid, angular, qwik, vite, express, node, unknown

    var displayName: String {
        switch self {
        case .nuxt: return "Nuxt"
        case .next: return "Next.js"
        case .astro: return "Astro"
        case .sveltekit: return "SvelteKit"
        case .remix: return "Remix"
        case .solid: return "SolidStart"
        case .angular: return "Angular"
        case .qwik: return "Qwik"
        case .vite: return "Vite"
        case .express: return "Express"
        case .node: return "Node"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .nuxt, .next, .astro, .sveltekit, .remix, .solid, .angular, .qwik, .vite: return "globe"
        case .express, .node: return "server.rack"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// A supervised project. Persisted to Application Support.
struct Project: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Absolute path to the project root.
    var path: String
    var packageManager: PackageManager
    var framework: Framework
    /// Optional override for the dev command; `nil` = auto-derived.
    var devCommand: String?
    /// Optional override for the build command; `nil` = auto-derived.
    var buildCommand: String?
    /// Heap size in GB injected as `--max-old-space-size` (used when `memoryAuto` is false).
    var memoryGB: Int
    /// When true, the heap follows the framework default instead of `memoryGB`.
    var memoryAuto: Bool
    /// Optional port override; `nil` = parse from stdout, fallback 3000 (i.e. "auto").
    var port: Int?
    /// When true, the package manager / dev command follow detection instead of `packageManager`.
    var packageManagerAuto: Bool
    /// Dev-server heap (GB) used when `memoryAuto` is on: the level last learned by the OOM
    /// autoscaler — starts at 4, climbs 4→6→8 on OOM and is persisted — instead of a fixed
    /// framework default. The dev server and the build keep SEPARATE learned levels.
    var autoHeapGB: Int
    /// Build heap (GB) used when `buildMemoryAuto` is off — independent from the dev server's heap
    /// (a production build is usually heavier than the dev server).
    var buildMemoryGB: Int
    /// When true, the build heap follows the OOM autoscaler (`buildAutoHeapGB`) instead of `buildMemoryGB`.
    var buildMemoryAuto: Bool
    /// Build heap (GB) used when `buildMemoryAuto` is on: the level last learned by the build OOM
    /// autoscaler — starts at 4, climbs 4→6→8 on OOM, persisted.
    var buildAutoHeapGB: Int

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        packageManager: PackageManager = .npm,
        framework: Framework = .unknown,
        devCommand: String? = nil,
        buildCommand: String? = nil,
        memoryGB: Int = 4,
        memoryAuto: Bool = true,
        port: Int? = nil,
        packageManagerAuto: Bool = true,
        autoHeapGB: Int = HeapScaling.firstGB,
        buildMemoryGB: Int = 4,
        buildMemoryAuto: Bool = true,
        buildAutoHeapGB: Int = HeapScaling.firstGB
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.packageManager = packageManager
        self.framework = framework
        self.devCommand = devCommand
        self.buildCommand = buildCommand
        self.memoryGB = memoryGB
        self.memoryAuto = memoryAuto
        self.port = port
        self.packageManagerAuto = packageManagerAuto
        self.autoHeapGB = autoHeapGB
        self.buildMemoryGB = buildMemoryGB
        self.buildMemoryAuto = buildMemoryAuto
        self.buildAutoHeapGB = buildAutoHeapGB
    }

    // Custom decoding so projects.json written before these fields still loads. New build-heap
    // fields default by INHERITING the dev-server config (so an existing project keeps the heap the
    // user already set, for the build too), and the learned autoscaler levels start at firstGB.
    enum CodingKeys: String, CodingKey {
        case id, name, path, packageManager, framework, devCommand, buildCommand
        case memoryGB, memoryAuto, port, packageManagerAuto
        case autoHeapGB, buildMemoryGB, buildMemoryAuto, buildAutoHeapGB
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        packageManager = try c.decode(PackageManager.self, forKey: .packageManager)
        framework = try c.decode(Framework.self, forKey: .framework)
        devCommand = try c.decodeIfPresent(String.self, forKey: .devCommand)
        buildCommand = try c.decodeIfPresent(String.self, forKey: .buildCommand)
        memoryGB = try c.decode(Int.self, forKey: .memoryGB)
        memoryAuto = try c.decodeIfPresent(Bool.self, forKey: .memoryAuto) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        packageManagerAuto = try c.decodeIfPresent(Bool.self, forKey: .packageManagerAuto) ?? true
        autoHeapGB = try c.decodeIfPresent(Int.self, forKey: .autoHeapGB) ?? HeapScaling.firstGB
        // Build heap defaults to the dev config of an existing project (decoded just above).
        buildMemoryGB = try c.decodeIfPresent(Int.self, forKey: .buildMemoryGB) ?? memoryGB
        buildMemoryAuto = try c.decodeIfPresent(Bool.self, forKey: .buildMemoryAuto) ?? memoryAuto
        buildAutoHeapGB = try c.decodeIfPresent(Int.self, forKey: .buildAutoHeapGB) ?? HeapScaling.firstGB
    }
}

extension Project {
    /// Hard floor for the injected heap — guards against a stale, too-low `memoryGB` (e.g. a
    /// leftover `1`) starving the dev server into an out-of-memory crash.
    static let minHeapGB = 2

    /// Clamp a requested heap to `[minHeapGB, systemGB]`.
    private static func clampHeap(_ requested: Int, systemGB: Int?) -> Int {
        var gb = max(Project.minHeapGB, requested)
        if let systemGB, systemGB > 0 { gb = min(gb, max(Project.minHeapGB, systemGB)) }
        return gb
    }

    /// Dev-server heap (GB) injected as `--max-old-space-size`. In **auto** mode it follows the OOM
    /// autoscaler's learned level (`autoHeapGB`, starting at 4 and climbing 4→6→8); only when
    /// `memoryAuto` is off does the explicit `memoryGB` win. Floored at `minHeapGB`, capped at
    /// physical RAM when supplied, so the result is deterministic.
    func effectiveMemoryGB(systemGB: Int? = nil) -> Int {
        Project.clampHeap(memoryAuto ? autoHeapGB : memoryGB, systemGB: systemGB)
    }

    /// Build heap (GB), INDEPENDENT from the dev server. In **auto** mode follows the build OOM
    /// autoscaler's learned level (`buildAutoHeapGB`, 4→6→8); else the explicit `buildMemoryGB`.
    func effectiveBuildMemoryGB(systemGB: Int? = nil) -> Int {
        Project.clampHeap(buildMemoryAuto ? buildAutoHeapGB : buildMemoryGB, systemGB: systemGB)
    }

    /// `~/Library/Application Support/DevMonitor/logs` — one file per project lives here.
    static var logsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevMonitor/logs", isDirectory: true)
    }

    /// Stable per-project log file: a name slug plus a short id so it survives renames/restarts and
    /// never collides with another project. Both the supervisor (writer) and the CLI (`logs`, via
    /// the hub's `status`) derive the path from here.
    var logFileURL: URL {
        let slug = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        let trimmed = slug.isEmpty ? "project" : String(slug.prefix(40))
        return Project.logsDirectory.appendingPathComponent("\(trimmed)-\(id.uuidString.prefix(8)).log")
    }
}
