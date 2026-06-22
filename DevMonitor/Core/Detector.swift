import Foundation

/// Detects package manager, framework, dev command and port from a project folder.
enum Detector {
    struct Result: Sendable {
        var packageManager: PackageManager
        var framework: Framework
        var devCommand: String
        var buildCommand: String?
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

        // Parse package.json deps + scripts.
        var deps: [String: String] = [:]
        var scripts: [String: String] = [:]
        if let data = fm.contents(atPath: path + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["dependencies", "devDependencies"] {
                if let d = json[key] as? [String: String] { deps.merge(d) { a, _ in a } }
            }
            if let s = json["scripts"] as? [String: String] { scripts = s }
        }

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

        return Result(packageManager: pm, framework: framework,
                      devCommand: devCommand, buildCommand: buildCommand, port: nil)
    }

    /// Dev/build commands for an explicit package manager, preserving the project's scripts.
    /// Used when the user overrides the package manager in the server config.
    static func commands(path: String, packageManager pm: PackageManager) -> (dev: String, build: String?) {
        var scripts: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: path + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = json["scripts"] as? [String: String] { scripts = s }
        let dev: String
        if scripts["dev"] != nil { dev = "\(pm.runScriptPrefix) dev" }
        else if scripts["start"] != nil { dev = "\(pm.runScriptPrefix) start" }
        else { dev = "\(pm.runScriptPrefix) dev" }
        let build = scripts["build"] != nil ? "\(pm.runScriptPrefix) build" : nil
        return (dev, build)
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
