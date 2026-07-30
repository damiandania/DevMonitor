import Foundation

/// Detects package manager, framework, dev command and port from a project folder.
enum Detector {
    struct Result: Sendable {
        var packageManager: PackageManager
        var framework: Framework
        var devCommand: String
        var buildCommand: String?
        /// Optional long-running background worker command (e.g. a queue/job worker), `nil` when the
        /// project has no worker script.
        var workerCommand: String?
        /// Optional command to serve the production build (`preview` / `start`), `nil` when none.
        var previewCommand: String?
        var port: Int?
    }

    /// Whether `path` is an existing directory that actually holds a launchable JS/TS project — a
    /// `package.json` or a Deno config. Used to reject bogus `up <path>` calls before a junk entry
    /// is ever created/persisted (e.g. `up /tmp` or `up /does/not/exist`).
    static func isProject(path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        let manifests = ["package.json", "deno.json", "deno.jsonc", "deno.lock"]
        return manifests.contains { fm.fileExists(atPath: path + "/" + $0) }
    }

    static func detect(path: String) -> Result {
        let fm = FileManager.default

        // Package manager by lockfile / config (most common managers in use today).
        let pm: PackageManager
        if fm.fileExists(atPath: path + "/bun.lockb") || fm.fileExists(atPath: path + "/bun.lock") { pm = .bun }
        else if fm.fileExists(atPath: path + "/pnpm-lock.yaml") { pm = .pnpm }
        else if fm.fileExists(atPath: path + "/yarn.lock") { pm = .yarn }
        else if fm.fileExists(atPath: path + "/deno.lock") || fm.fileExists(atPath: path + "/deno.json")
                 || fm.fileExists(atPath: path + "/deno.jsonc") { pm = .deno }
        else { pm = .npm }

        // Parse package.json deps (framework detection), and the runnable scripts/tasks.
        var deps: [String: String] = [:]
        if let data = fm.contents(atPath: path + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["dependencies", "devDependencies"] {
                if let d = json[key] as? [String: String] { deps.merge(d) { a, _ in a } }
            }
        }
        // package.json "scripts" for npm/pnpm/yarn/bun, deno.json(c) "tasks" for Deno.
        let scripts = self.scripts(path: path, packageManager: pm)

        // Framework by deps.
        let framework: Framework
        if deps.keys.contains(where: { $0 == "nuxt" || $0.hasPrefix("@nuxt/") }) { framework = .nuxt }
        else if deps.keys.contains("next") { framework = .next }
        else if deps.keys.contains("astro") { framework = .astro }
        else if deps.keys.contains("@sveltejs/kit") { framework = .sveltekit }
        else if deps.keys.contains(where: { $0.hasPrefix("@remix-run/") }) { framework = .remix }
        else if deps.keys.contains(where: { $0 == "@solidjs/start" || $0 == "solid-start" }) { framework = .solid }
        else if deps.keys.contains(where: { $0.hasPrefix("@angular/") }) { framework = .angular }
        else if deps.keys.contains(where: { $0.hasPrefix("@builder.io/qwik") }) { framework = .qwik }
        // SvelteKit / Remix / SolidStart / Qwik run on top of Vite, so they MUST be matched before
        // the generic `vite` check below (their package.json also depends on vite).
        else if deps.keys.contains("vite") { framework = .vite }
        else if deps.keys.contains("express") { framework = .express }
        else if scripts["dev"] != nil || scripts["start"] != nil { framework = .node }
        else { framework = .unknown }

        // Dev command: prefer a "dev" script, else "start", else a framework default.
        let devCommand: String
        if scripts["dev"] != nil { devCommand = "\(pm.runScriptPrefix) dev" }
        else if scripts["start"] != nil { devCommand = "\(pm.runScriptPrefix) start" }
        else { devCommand = "\(pm.runScriptPrefix) dev" }

        let buildCommand: String? = scripts["build"] != nil ? "\(pm.runScriptPrefix) build" : nil
        let workerCommand = self.workerScript(in: scripts).map { "\(pm.runScriptPrefix) \($0)" }
        let previewCommand = self.previewScript(in: scripts).map { "\(pm.runScriptPrefix) \($0)" }

        return Result(packageManager: pm, framework: framework,
                      devCommand: devCommand, buildCommand: buildCommand,
                      workerCommand: workerCommand, previewCommand: previewCommand, port: nil)
    }

    /// The script that serves the production build, if any: a `preview` script (Vite/Nuxt/Astro/…),
    /// else a `start` script *only when it's distinct from the dev command* (e.g. Next's `next start`,
    /// where `dev` is a separate script). Returns the script name or nil.
    static func previewScript(in scripts: [String: String]) -> String? {
        if scripts["preview"] != nil { return "preview" }
        if scripts["start"] != nil && scripts["dev"] != nil { return "start" }
        return nil
    }

    /// Pick the project's long-running worker script, if any. Prefers a watch/dev variant so the
    /// worker reloads on change (mirrors preferring `dev` over `start` for the server), then the
    /// plain run variant. Returns the script *name* (e.g. "worker:dev") or nil when there is none.
    static func workerScript(in scripts: [String: String]) -> String? {
        for candidate in ["worker:dev", "worker:watch", "worker:start", "worker"] where scripts[candidate] != nil {
            return candidate
        }
        return nil
    }

    /// The runnable script/task NAMES for a project: package.json `scripts` for npm/pnpm/yarn/bun, or
    /// deno.json(c) `tasks` for Deno (only the keys are used downstream — to pick dev/build/worker/
    /// preview — so a Deno project resolves `deno task <name>` instead of always falling back to a
    /// possibly-nonexistent `deno task dev`). A Deno project with no tasks declared falls back to
    /// package.json scripts (Deno's npm-compat).
    static func scripts(path: String, packageManager pm: PackageManager) -> [String: String] {
        if pm == .deno {
            let tasks = denoTasks(path: path)
            if !tasks.isEmpty { return tasks }
        }
        if let data = FileManager.default.contents(atPath: path + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = json["scripts"] as? [String: String] { return s }
        return [:]
    }

    /// Task names declared in deno.json / deno.jsonc (`tasks` object). The value is the task's command
    /// when it's a plain string, or "" for the newer object form — only the names are used downstream.
    /// (JSONSerialization can't parse deno.jsonc comments; such a file yields no tasks and falls back.)
    static func denoTasks(path: String) -> [String: String] {
        for file in ["deno.json", "deno.jsonc"] {
            guard let data = FileManager.default.contents(atPath: path + "/" + file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tasks = json["tasks"] as? [String: Any] else { continue }
            var out: [String: String] = [:]
            for (name, body) in tasks { out[name] = (body as? String) ?? "" }
            if !out.isEmpty { return out }
        }
        return [:]
    }

    /// Dev/build commands for an explicit package manager, preserving the project's scripts.
    /// Used when the user overrides the package manager in the server config.
    static func commands(path: String, packageManager pm: PackageManager) -> (dev: String, build: String?, worker: String?, preview: String?) {
        let scripts = self.scripts(path: path, packageManager: pm)
        let dev: String
        if scripts["dev"] != nil { dev = "\(pm.runScriptPrefix) dev" }
        else if scripts["start"] != nil { dev = "\(pm.runScriptPrefix) start" }
        else { dev = "\(pm.runScriptPrefix) dev" }
        let build = scripts["build"] != nil ? "\(pm.runScriptPrefix) build" : nil
        let worker = workerScript(in: scripts).map { "\(pm.runScriptPrefix) \($0)" }
        let preview = previewScript(in: scripts).map { "\(pm.runScriptPrefix) \($0)" }
        return (dev, build, worker, preview)
    }

    /// Reasonable default heap (GB) for a framework's dev server.
    static func defaultMemoryGB(for framework: Framework) -> Int {
        switch framework {
        case .nuxt, .next, .angular: return 8
        case .astro, .vite, .sveltekit, .remix, .solid, .qwik: return 4
        case .express, .node, .unknown: return 2
        }
    }
}
