# Changelog

Notable changes to Dev Monitor. Loosely follows [Keep a Changelog](https://keepachangelog.com/);
versions use [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Background workers.** A project with a `worker` script (`worker`, `worker:dev`, …) gets a
  supervised long-running worker — its own run-control, terminal tab and process-table row.
- **Production-build preview.** A project with a `preview` (or Next's `start`) script gets a Preview
  control that serves the built output through the same server supervision as the dev server (port,
  health, logs), with its own terminal tab.
- **Unified run-controls.** Dev, worker, build and preview are now one row of play/stop pills on the
  dashboard, each showing a short live status; a failed control's status is an underlined link that
  opens a popover with the terminal error (copyable). Launching/building blinks. They all come from
  one source (`AppState.runControls`), so the menu bar, terminal tabs and the menu-bar health glyph
  pick up a new process type automatically.
- **Terminal run timers.** The terminal pane shows a live uptime for a running server/worker, and for
  a build the elapsed time + a progress bar against the last build's duration as the ETA.
- **Persistent event history.** Crashes, recycles, OOM retries, builds and pressure events are written
  to a JSONL log (rotated by size) and shown in a new **History** window — a timeline grouped by day —
  so the record survives an app restart (the sidebar feed only keeps the last few).
- **Log search + export.** The terminal pane has a filter field (case-insensitive, ANSI-stripped) and
  an export-to-file button (`Core/LogFilter`).
- **Localization (Spanish + French) + in-app language picker.** Settings → Appearance → Language
  switches the UI **live**, no relaunch (strings live in a `Localizable.xcstrings` catalog, applied
  via a `\.locale` environment override). VoiceOver labels added across the interactive UI
  (run-controls, activity meters, process rows, menu bar).
- **Collapsible menu-bar sections.** The menu bar lists *every* project as a collapsible section
  (status dot + name). A play/stop button — revealed on hover, with stop always shown — launches or
  stops the dev server without expanding; expanding reveals all of the project's controls.
- **Per-project health-probe path.** An API-only server whose `/` route hangs can point the liveness
  check at a real route (per-project server config). Any HTTP response counts as alive.
- **Distribution scaffolding** (opt-in, no effect on the default unsigned build): Developer ID signing
  + notarization in `tools/package-release.sh`, hardened runtime, a Sparkle auto-update hook, a
  Homebrew cask template, and a tag-triggered release workflow. See `docs/DISTRIBUTION.md`.

### Changed
- **Menu-bar status glyph** now turns red when *any* supervised process (dev, worker, build, preview)
  is stopped or failed — not just a failed dev server.
- **`dev-monitor build` is now synchronous.** It waits for the build to finish, then prints the tail
  of the build output and a success/failure verdict — exiting non-zero on failure — instead of
  returning immediately with "building …". A caller (or an agent) gets the real result, not a
  fire-and-forget acknowledgement. Hub-side only: the existing CLI already reads the socket to EOF,
  so no CLI reinstall is needed.
- **Heap autoscaling now climbs in fixed steps and is remembered per project.** In auto mode the
  heap starts at 4 GB and, on an out-of-memory, climbs **4 → 6 → 8 → 12 → 16 → 24**, clamped to the
  machine's physical RAM — so a big-RAM Mac keeps climbing instead of giving up at 8 (on an 8 GB Mac
  the effective ladder is still 4 → 6 → 8). The learned level is persisted to `projects.json`, so the
  next launch starts there instead of replaying the OOMs. Policy in `Core/HeapScaling.swift`.
- **Corruption-safe storage.** `projects.json` / `settings.json` are versioned and, if unreadable,
  backed up to `*.corrupt-<timestamp>` and surfaced via a notification — instead of silently resetting
  to empty/defaults (shared `Core/JSONFileStore`).
- **No orphaned processes left behind.** Stop / recycle / quit now kill the *full* tree — session
  members plus `setsid()` descendants that escape `killpg` — and quit also closes + unlinks the IPC
  socket. Leftover-reaping matches a project path on a boundary, so `/p/foo` never reaps `/p/foobar`.
- **IPC hub is owner-only.** The socket is `chmod 0600` and rejects connections from another UID
  (`LOCAL_PEERCRED`), without breaking the accept loop.
- **Deno projects resolve their tasks.** The detector reads `deno.json(c)` `tasks`, so `deno task
  <name>` is correct instead of always falling back to `deno task dev`.
- **Internal refactor — no behavior change.** The dev-server/build process plumbing is shared in
  `SpawnedProcess` + `ProcessSupport`/`LineBuffer`/`LogNoise`; the `AppState` god object (712 → ~300
  lines) is split into focused extensions (`+Projects`/`+Builds`/`+Doctor`) with `PressureManager`
  and a reusable `AsyncJob` extracted; views gain reusable pieces (`StatusDot`, `.pulsing()`, status
  colour extensions). All 14 test suites stay green. See `docs/ARCHITECTURE.md`.

### Fixed
- **OOM auto-scaling has fewer false positives.** A clean exit (code 0) is never treated as
  out-of-memory however the log reads, and a generic "allocation failed" only counts as OOM alongside
  a fatal-error marker — so a non-OOM crash isn't pointlessly retried with a bigger heap.
- **Astro 7 dev servers no longer loop-relaunch.** From v7, `astro dev` auto-daemonizes when it
  detects an AI coding agent — the spawned process detaches and exits 0 immediately, which the
  supervisor read as a crash, relaunching forever. Astro projects now spawn with
  `ASTRO_DEV_BACKGROUND=0`, keeping the server in the foreground where Dev Monitor supervises it
  (the framework-specific env lives in `DevSession.frameworkEnv`, alongside Nuxt's `NUXT_IGNORE_LOCK`).
- **Build failures now show a banner.** A failed build was delivered to Notification Center silently
  (a `.passive` interruption level); it's now urgent/time-sensitive so it breaks through as a banner,
  while a successful build stays silent.
- **Cancelling a build no longer reports it as "failed".** Stopping a running build used to fire a
  "Build failed" notification because the process is signal-killed; a user-initiated stop is now
  suppressed (the paused dev server still relaunches).
- **Builds no longer OOM (exit 6) on memory-heavy projects.** `dev-monitor build` (and the Build
  button) now inject the same `NODE_OPTIONS=--max-old-space-size` heap as the dev server, instead of
  running a bare `npm run build` with Node's small default heap.
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
- **Independent build heap, with its own autoscaler and a "Build memory" setting.** The build now
  has a heap **separate** from the dev server (a production build is usually heavier), with the same
  4 → 6 → 8 OOM autoscaler and a learned level remembered per project. A new **"Build memory"** row
  sits next to "Memory" in each project's settings. See `docs/HEAP-AND-BUILD.md`.
- **The build now pauses all active dev servers while it runs** (relaunching them after). On a
  RAM-starved Mac, building alongside a multi-GB dev server got the build SIGKILLed by the kernel
  before V8 could OOM — failing the build and bypassing the autoscaler. Pausing the servers frees the
  RAM, so the build completes (or surfaces a clean V8 OOM the autoscaler can act on).
- **Aggressive RAM relief around builds** (this app targets 8 GB Macs, where a heavy build's final
  Nitro prerender gets jetsam-SIGKILLed once swap fills). The build now: `purge`s inactive/cached
  system memory before starting (and again mid-build under pressure); surfaces the resource advisor
  to close heavy non-essential apps (user-confirmed); watches `systemMemPercent` during the build to
  act **before** the kernel jetsam; and injects `--optimize-for-size` into Node so V8 favours
  footprint over speed. See `docs/HEAP-AND-BUILD.md`.
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
