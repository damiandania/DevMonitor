# Claude Code integration — route dev servers through Dev Monitor

A **PreToolUse hook** that makes every Claude Code session on this machine route dev servers and
JS/framework builds through the Dev Monitor app instead of running them directly. It hard-blocks
raw commands and tells Claude to use the `dev-monitor` CLI.

## Why

Dev Monitor is the single authority that supervises **one dev server per project**. Starting a
server (or a build) directly fights it:

- two servers on the same project collide on the build dir (e.g. Nuxt's `.nuxt` → `component-meta`
  errors) and on the port;
- Nuxt's agent-only **dev-lock** (`Another Nuxt dev server is already running`) trips inside any
  Claude Code terminal, because `std-env` sees `CLAUDECODE` / `AI_AGENT` and enables locking;
- the pressure auto-killer may treat the stray server as an orphan and kill it.

Routing through the app avoids all of this — and because the app is launched by LaunchServices (no
agent env vars), Nuxt's dev-lock never fires for app-spawned servers.

## What it intercepts

| Raw command (blocked) | Use instead |
|---|---|
| `npm/pnpm/yarn/bun run dev`, `nuxt/next/astro/vinxi dev`, `vite`, `ng serve`, `webpack serve`, … | `dev-monitor up "<dir>" --wait` (blocks until ready, prints the URL) |
| `npm/pnpm/yarn/bun run build`, `nuxt/next/astro/vite build`, … | `dev-monitor build "<dir>"` |

The block message also points to `dev-monitor status --json` (per-project `ready`/`url`/`pid`/
`exitCode`/`lastError`) and `dev-monitor --help` for the full surface, so an agent can operate and
self-diagnose without curling the port or reading internal files.

It deliberately does **not** touch `xcodebuild`, `go build`, `cargo build`, `docker build`,
`make`, `npm install`, `npm test`, `npm run dev:<variant>`, or any command that already calls
`dev-monitor`. Escape hatch: prefix any command with `DM_RAW=1 ` to run it untouched.

## Install

**Easiest — from the app:** Dev Monitor → **Settings → General → Claude Code** → **Install hook**
(and **Uninstall hook** to remove it). It writes the script to `~/.claude/hooks/` and adds the
PreToolUse entry to `~/.claude/settings.json`, preserving your other settings. Restart Claude Code
afterwards (hooks load at session start).

### Manual (user-global)

1. Copy the hook somewhere stable and make it executable:

   ```bash
   mkdir -p ~/.claude/hooks
   cp integrations/claude/route-dev-through-devmonitor.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/route-dev-through-devmonitor.sh
   ```

2. Merge this into `~/.claude/settings.json` (see `settings.snippet.json`):

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Bash",
           "hooks": [
             { "type": "command",
               "command": "bash /Users/<you>/.claude/hooks/route-dev-through-devmonitor.sh" }
           ]
         }
       ]
     }
   }
   ```

3. Restart Claude Code (hooks load at session start).

## How it works

Claude Code runs the hook before every Bash tool call, passing the call as JSON on stdin. The
script extracts `.tool_input.command` with `plutil` (ships with macOS — no `jq` needed), matches it
against the dev/build patterns, and on a match writes guidance to **stderr** and exits **2**, which
makes Claude Code block the call and feed that guidance back to the model. Anything else exits 0
(allowed). Requires only the Dev Monitor `dev-monitor` CLI on `PATH` (`~/.local/bin`).
