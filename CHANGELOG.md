# Changelog

Notable changes to Dev Monitor. Loosely follows [Keep a Changelog](https://keepachangelog.com/);
versions use [SemVer](https://semver.org/).

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
