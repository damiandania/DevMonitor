import Foundation

/// Installs / removes a global Claude Code `PreToolUse` hook so OTHER Claude Code sessions on this
/// Mac are blocked from launching dev servers (or JS builds) directly and told to use the
/// `dev-monitor` CLI instead — routing every server through this app. Edits `~/.claude/settings.json`
/// (preserving the user's other keys) and drops the script in `~/.claude/hooks/`.
enum ClaudeHookInstaller {
    static let scriptName = "route-dev-through-devmonitor.sh"

    /// Directory that holds `.claude` — the user's home in production; overridable in tests so they
    /// never touch the real `~/.claude`.
    nonisolated(unsafe) static var baseDir = URL(fileURLWithPath: NSHomeDirectory())
    static var claudeDir: URL { baseDir.appendingPathComponent(".claude", isDirectory: true) }
    static var hooksDir: URL { claudeDir.appendingPathComponent("hooks", isDirectory: true) }
    static var scriptURL: URL { hooksDir.appendingPathComponent(scriptName) }
    static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }
    static var command: String { "bash \(scriptURL.path)" }

    /// True when a PreToolUse hook referencing our script is present in settings.json.
    static var isInstalled: Bool {
        for matcher in preToolUse(in: readSettings()) {
            let hooks = (matcher["hooks"] as? [[String: Any]]) ?? []
            if hooks.contains(where: { ($0["command"] as? String)?.contains(scriptName) == true }) {
                return true
            }
        }
        return false
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try Data(claudeHookScriptBody.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var obj = readSettings()
        var hooks = (obj["hooks"] as? [String: Any]) ?? [:]
        var pre = stripOurEntries((hooks["PreToolUse"] as? [[String: Any]]) ?? [])
        pre.append(["matcher": "Bash",
                    "hooks": [["type": "command", "command": command]]])
        hooks["PreToolUse"] = pre
        obj["hooks"] = hooks
        try writeSettings(obj)
    }

    static func uninstall() throws {
        var obj = readSettings()
        if var hooks = obj["hooks"] as? [String: Any] {
            let pre = stripOurEntries((hooks["PreToolUse"] as? [[String: Any]]) ?? [])
            if pre.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = pre }
            if hooks.isEmpty { obj.removeValue(forKey: "hooks") } else { obj["hooks"] = hooks }
            try writeSettings(obj)
        }
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - settings.json helpers (preserve unknown keys)

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func writeSettings(_ obj: [String: Any]) throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL)
    }

    private static func preToolUse(in obj: [String: Any]) -> [[String: Any]] {
        ((obj["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]) ?? []
    }

    /// Remove every hook entry referencing our script, dropping any matcher left empty.
    private static func stripOurEntries(_ pre: [[String: Any]]) -> [[String: Any]] {
        pre.compactMap { matcher in
            var m = matcher
            var hooks = (m["hooks"] as? [[String: Any]]) ?? []
            hooks.removeAll { ($0["command"] as? String)?.contains(scriptName) == true }
            if hooks.isEmpty { return nil }
            m["hooks"] = hooks
            return m
        }
    }
}

// The exact script the app writes on install. MUST stay byte-for-byte in sync with
// integrations/claude/route-dev-through-devmonitor.sh — they had drifted (this copy carried the
// old `dev-monitor run` messages and the path-blind regex), which is why the installed hook lagged
// the source. No backslashes / no `\\(` so it embeds in this Swift """ literal verbatim; lines are
// at column 0 so the closing """ (also column 0) preserves the bash indentation.
private let claudeHookScriptBody = """
#!/bin/bash
# PreToolUse(Bash) hook — route dev servers and JS builds through the DevMonitor app.
#
# DevMonitor supervises ONE dev server per project. Starting a server (or a JS build) directly
# fights it (port/.nuxt collisions, the Nuxt dev-lock, the pressure auto-killer). So we hard-block
# the raw command and tell Claude to use the `dev-monitor` CLI, which talks to the app.
#
# exit 2 + stderr => Claude Code blocks the call and shows stderr to the model.
# There is deliberately NO inline escape hatch — dev/build/preview launches ALWAYS route through the
# app. To run one unsupervised, uninstall the hook: Dev Monitor > Settings > General > Claude Code.
input=$(cat)
cmd=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_input.command raw -o - - 2>/dev/null)
cwd=$(printf '%s' "$input" | /usr/bin/plutil -extract cwd raw -o - - 2>/dev/null)
[ -z "$cwd" ] && cwd='.'
[ -z "$cmd" ] && exit 0

# A command's first real word — after any leading VAR=val assignments and an optional path prefix —
# being a known read-only INSPECTION tool means that SEGMENT is just looking, not launching (e.g.
# `pgrep -fl 'nuxt dev'`, `grep vite file`, `ps aux`). Such a segment is allowed as-is.
INSPECT_RE='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=([^[:space:]"'"'"']*|"[^"]*"|'"'"'[^'"'"']*'"'"')[[:space:]]+)*([^[:space:]]*/)?(pgrep|pkill|kill|grep|egrep|fgrep|rg|ag|ack|ps|echo|printf|cat|bat|less|more|head|tail|ls|find|fd|which|type|command|whereis|whatis|man|lsof|awk|sed|tr|cut|sort|uniq|wc|jq|yq|stat|file|dirname|basename|realpath|readlink|true|false|test|tmux|history)([[:space:]]|$)'

# Match a real launch. `sep` no longer excludes '/', so a path-qualified launch
# (`./node_modules/.bin/nuxt dev`, `/usr/local/bin/next dev`, `node_modules/.bin/vite`) is caught too.
sep='(^|[^[:alnum:]_.-])'
DEV_RE="${sep}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?dev([^[:alnum:]_:-]|$)|${sep}(nuxt|next|astro|vinxi)[[:space:]]+dev([^[:alnum:]_-]|$)|${sep}vite([[:space:]]+(dev|serve|--)|[[:space:]]*$)|${sep}ng[[:space:]]+serve([^[:alnum:]_-]|$)|${sep}(webpack[[:space:]]+serve|webpack-dev-server)|${sep}remix[[:space:]]+vite:dev"
BUILD_RE="${sep}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?build([^[:alnum:]_:-]|$)|${sep}(nuxt|next|astro|ng|vite|vinxi)[[:space:]]+build([^[:alnum:]_-]|$)"
PREVIEW_RE="${sep}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?preview([^[:alnum:]_:-]|$)|${sep}(nuxt|nuxi|vite|astro)[[:space:]]+preview([^[:alnum:]_-]|$)|${sep}next[[:space:]]+start([^[:alnum:]_-]|$)"

# Judge each shell SEGMENT independently, so a real launch can't ride behind an allowed prefix
# (`echo x && npm run dev`, `pgrep foo | npm run build`, `dev-monitor stop X && npm run build`). We
# split on && || ; | and newlines: `tr` maps &,|,; to a newline (nl), and && / || just yield an empty
# middle segment (skipped). Over-splitting a quoted separator (e.g. grep -E 'a|b') only ever inspects
# MORE segments — it can never merge a hidden launch into an allowed one, so it cannot create a bypass.
nl='
'
block=''
while IFS= read -r seg || [ -n "$seg" ]; do
  printf '%s' "$seg" | grep -q '[^[:space:]]' || continue    # blank segment
  printf '%s' "$seg" | grep -qE "$INSPECT_RE" && continue     # a read-only inspection segment
  printf '%s' "$seg" | grep -qE "$DEV_RE"     && { block=dev;     break; }
  printf '%s' "$seg" | grep -qE "$BUILD_RE"   && { block=build;   break; }
  printf '%s' "$seg" | grep -qE "$PREVIEW_RE" && { block=preview; break; }
done < <(printf '%s' "$cmd" | tr '&|;' "$nl")

case "$block" in
  dev)
    echo "BLOCKED — dev servers on this machine run through DevMonitor (one supervised server per project)." >&2
    echo "Do not start a dev server directly. Instead run:  dev-monitor up '$cwd' --wait   (blocks until ready, prints the URL)" >&2
    echo "Inspect with: dev-monitor status --json   (ready/url/pid/exitCode/lastError per project)" >&2
    echo "Full surface: dev-monitor --help" >&2
    exit 2 ;;
  build)
    echo "BLOCKED — builds run through DevMonitor so the project's dev server is stopped first." >&2
    echo "Instead run:  dev-monitor build '$cwd'   (stops the server, builds, relaunches it; prints a ✅/❌ verdict + exits non-zero on failure)." >&2
    echo "If it fails, read the WHOLE error (not just the printed tail):  dev-monitor logs '$cwd' --build" >&2
    exit 2 ;;
  preview)
    echo "BLOCKED — preview servers (serving the production build) also run through DevMonitor." >&2
    echo "Instead run:  dev-monitor preview '$cwd' --wait   (blocks until ready, prints the URL)." >&2
    exit 2 ;;
esac
exit 0
"""
