# Changelog

Notable changes to Dev Monitor. Loosely follows [Keep a Changelog](https://keepachangelog.com/);
versions use [SemVer](https://semver.org/).

## [Unreleased]

### Fixed
- **Dev servers managed by fnm/nvm no longer fail with `command not found` (exit 127).** The spawn
  shell (`zsh -lc`) is login but non-interactive, so it never sourced `~/.zshrc` where Node version
  managers put their shims — a GUI launch from launchd then had no `node`/`npm` on `PATH`. A new
  `ShellEnvironment` resolves the user's login+interactive `PATH` and exports it before each launch
  (re-resolved per launch, because fnm's per-shell dir is ephemeral).
- **The hub no longer dies when a `dev-monitor` client disconnects.** It now ignores `SIGPIPE`
  (as the CLI already did), so writing a reply to a client that has already exited can't terminate
  the whole app right after handling an `up`/`status`.
- **A second instance can no longer steal the IPC socket** from a running hub — the listener probes
  for a live owner before reclaiming a stale socket, instead of unlinking it unconditionally.
- **Claude hook regex** no longer blocks read-only commands that merely *mention* a dev server
  (e.g. `pgrep 'nuxt dev'`), and no longer misses path-qualified launches
  (`./node_modules/.bin/nuxt dev`). The embedded and on-disk copies of the script are back in sync.

### Added
- **More frameworks detected** — SvelteKit, Remix, SolidStart, Angular and Qwik, in addition to
  Nuxt, Next, Astro, Vite and Express, each with a tuned default heap. (Any project with a `dev`
  script already launched; this just names/sizes them properly.)

### Changed
- `NUXT_IGNORE_LOCK=1` is now injected **only for Nuxt projects**, instead of into every spawned
  server's environment.

## [0.1.0] — 2026-06-18

First public release — a native macOS app that launches, supervises, and auto-recycles JS/TS dev
servers, with a `dev-monitor` CLI every terminal can route through.

### Added
- **Detect & launch** dev servers (npm · pnpm · yarn · bun · deno; Nuxt · Next · Astro · Vite ·
  Express) with a **deterministic heap** (`--max-old-space-size`) and live logs.
- **Live activity** — system CPU/Memory/Swap, an Activity-Monitor-style table with each supervised
  server as its own identified row, and external dev servers identified (not supervised).
- **Health, recovery & resilience** — hang detection + auto-recycle; **crash auto-revive** (bounded
  backoff, port pinned); **OOM recovery** (retry once with a bigger heap); **crash-proof
  supervision** (a managed crash — or the notification subsystem — can't take the app down).
- **Pressure response** — detects a stuck machine and auto-closes orphaned dev processes; surfaces
  other heavy processes as suggestions.
- **Build runner**, **global terminal**, **menu-bar item**, and app/terminal **theming**.
- **CLI + hub** — `up [--gb N] [--wait]` · `build` · `status [--json]` · `stop` · `restart` ·
  `remove` · `logs [path]` · `version`. Structured `status --json` (`ready` · `url` · `pid` ·
  `exitCode` · `lastError`) so agents operate and diagnose without curling the port or reading
  internal files. Robust arg parsing; path validation; per-project logs.
- **Claude integration** — a `PreToolUse` hook that routes raw `npm run dev`/builds through the app;
  read-only Diagnose and Resource Advisor.

### Notes
- Distributed **unsigned** (ad-hoc) — the first launch needs **right-click → Open** (see the README).
- **Requires macOS 26 or later** (the UI uses SwiftUI / Liquid Glass).

[0.1.0]: https://github.com/damiandania/DevMonitor/releases/tag/v0.1.0
