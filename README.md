# Dev Monitor

A native **macOS 26** (Swift 6 + SwiftUI, Liquid Glass) app that launches, supervises and
auto-recycles JS/TS dev servers — with live resource graphs, hang detection, a build runner, a
central IPC hub other terminals route through, and Claude-generated self-error reports.

> Built to replace an ad-hoc shell watchdog: a doubled `npm` wrapper once left an orphaned Nuxt
> process listening on `:3000` but unresponsive, pinning a CPU core and slowing the whole Mac.
> Dev Monitor does that supervision properly and visibly.

## Status

| Phase | Done | Summary |
|------|:----:|---------|
| P0 — Scaffold | ✅ | XcodeGen project (app + CLI targets), persistent project sidebar, Dock icon |
| P1 — Launch & log | ✅ | Detector + supervisor (`posix_spawn` session, `killpg`), log streaming, port/ready parsing, `NODE_OPTIONS` |
| P2 — Metrics & charts | ✅ | Per-process CPU/mem (`libproc`), system CPU/mem (`mach`), 4 live Swift Charts |
| P3 — Health & recycle | ✅ | HTTP health probe + strike state machine + automatic tree recycle |
| P4 — Notifications | ✅ | Native notifications (crash/hang/recycle/build) with sound |
| P5 — Build runner | ✅ | Run the project's build script as a tracked tree |
| P6 — Hub + CLI + docs | ✅ | Unix-socket hub + `dev-monitor` CLI (run/status/stop/restart/logs) + auto-start |
| P7 — Claude reports | ✅ | Read-only "Diagnose" report about Dev Monitor itself |
| P8 — Polish & dist | ✅ | App icon, MenuBarExtra, Release → /Applications, CLI → `~/.local/bin` (signing: ad-hoc¹) |
| P9 — Resource advisor | ✅ | Claude-recommended actions on heavy processes; auto-stop managed dev, **confirm before closing foreign** |
| P9b — Pressure auto-kill | ✅ | Detects a stuck machine (sustained CPU, or memory full + swapping) → **auto-closes orphaned dev processes** (+notify); other heavy processes are surfaced with a fast **Haiku** eval and a red **skull** button (manual) |
| P10 — Multi-session orchestrator | ✅ | **One supervised server per project** (concurrent, each its own table row), idempotent `dev-monitor up`, `build` orchestration (stop→build→relaunch), `status --json`, sidebar running indicator, **external dev servers identified** in the table & menu (*project :port*, purple), the menu-bar item lists **all** online servers, a global **Claude Code hook** that routes raw `npm run dev`/builds through the CLI, and `NUXT_IGNORE_LOCK=1` + a CLOEXEC fd fix so cold launches don't hang |

¹ Signed ad-hoc (`CODE_SIGN_IDENTITY = -`): no Apple Developer ID identity is installed on this
machine. Local notifications and the menu-bar item work; for distribution outside this Mac, sign
with a Developer ID and notarize.

## Features (current)

- **Auto-detects** package manager (npm/pnpm/yarn/bun/deno) and framework (Nuxt/Next/Astro/Vite/
  Express) per project.
- **Launches** the dev server with a chosen heap size (`--max-old-space-size`), streaming its log live.
- **Live activity**: system **CPU / Memory / Swap** progress bars + an Activity-Monitor-style table
  of only the processes with real impact (heavy CPU or memory). **Each supervised server is its own
  identified row** (e.g. *MiddleSpace :3000*, blue) — trees aren't merged. A dev server running
  **outside** the app is identified the same way but in **purple** (e.g. *MiddleSpace :3001*) so you
  can tell it apart at a glance; it's shown, not supervised. CPU is per-core (100% = one core), so a
  busy tree can read >100% like Activity Monitor; the "% of machine" toggle re-expresses it as a
  share of total capacity. Generic helpers (`node`, "Code Helper") are named from the extension's own
  `package.json` `displayName` (resolving `%key%` via `package.nls.json`) — e.g. *Vue (Official)*,
  *ESLint*, *Tailwind CSS IntelliSense*.
- **Per-project settings** (gear on each sidebar row → modal): **Memory / Port / Package**, each with
  an **Auto** toggle (on by default); turn it off for a manual value (slider / field / package picker:
  npm·pnpm·yarn·bun·deno). Auto memory follows the framework default; auto port is parsed from stdout.
  The package manager in use is also shown as a chip next to the Launch button.
- **App settings** (gear at the bottom of the sidebar → modal): the **browser** to open servers in
  (auto-detected via LaunchServices — Chrome/Firefox/Safari/Chromium/…), the **Claude model** used for
  Diagnose / Advisor / pressure analysis (Haiku/Sonnet/Opus), an orphan-auto-close toggle, and the
  default heap for new projects. Persisted in `settings.json`.
- **Hang detection + auto-recycle**: HTTP probes the server; after consecutive failures it kills the
  whole process tree (including orphans) and relaunches.
- **Build runner**: runs the project's build script as a separate tracked tree. Its process tree
  shows as one identified row in the activity table (just like the dev server), the log area becomes
  **pill tabs** (Server / Build, each closable with an ✕) and auto-switches to Build on start, and the
  Build button turns into a red **Stop build** while running.
- **Pressure auto-kill**: when the machine is detected as *stuck* (CPU pinned, or memory full and
  swapping, for a sustained window):
  - **Orphaned dev processes auto-close.** A dev server (detected by its actual binary in argv —
    `…/.bin/nuxt`, `vite/bin/vite`, `next dev`, …) that isn't in Dev Monitor's managed tree is killed
    automatically (SIGTERM → SIGKILL) and a **notification** lists what was closed. The managed dev
    server (and the editor/system) are excluded.
  - **Everything else stays a suggestion.** The sidebar surfaces a panel — a fast **Haiku**
    evaluation of which other heavy processes are worth killing — each with a red **skull** button
    (foreign processes are only closed when *you* press it). A heuristic list shows instantly while
    Haiku refines it. Critical processes (editor, WindowServer, Finder, daemons, Dev Monitor itself)
    are never suggested or auto-closed.
- **Menu-bar item** (`MenuBarExtra`): lists **every online server** — each supervised one with live
  status/uptime and Stop/Restart, plus any **external** dev servers (purple, display-only) — a Launch
  button for the selected idle project, and a system CPU/memory snapshot, without opening the window.
- **Central hub + CLI**: run servers from any terminal through the app — **one supervised server
  per project**, several concurrently. `dev-monitor up` (idempotent), `build` (stops the project's
  server, builds, relaunches), `status [--json]`, `stop [path]/--all`, `restart [path]`, `logs -f`;
  auto-starts the app if needed. The sidebar shows a small **status dot** on each project whose
  server is live. See [DevMonitor/USAGE.md](DevMonitor/USAGE.md).
- **Routes other Claude Code sessions through the app**: a global PreToolUse hook hard-blocks raw
  `npm run dev` / `nuxt dev` / framework builds and redirects to `dev-monitor`, so every terminal's
  servers land in one supervised place. See [integrations/claude/](integrations/claude/). A server
  started **outside** the app still appears in the activity table but isn't supervised.
- **Diagnose (read-only)**: a toolbar button runs the logged-in `claude` against Dev Monitor's *own*
  source to explain its internal errors — never edits anything (`--permission-mode plan` + write
  tools disallowed).
- **Resource advisor (read-only)**: Claude ranks the machine's heavy processes and proposes actions.
  Managed dev processes can be stopped with one tap; **foreign processes (editors/browsers/daemons)
  are only closed after an explicit confirmation — never auto-killed.**

## Requirements

- macOS 26+ and Xcode 26+ (Swift 6.3).
- [XcodeGen](https://github.com/yonsm/XcodeGen) (`brew install xcodegen`) to generate the project.
- The project is **not sandboxed** (it spawns processes and reads system info).

## Build & run

```bash
brew install xcodegen
cd DevMonitor
xcodegen generate
xcodebuild -project DevMonitor.xcodeproj -scheme DevMonitor -configuration Debug \
  -derivedDataPath build build
open "build/Build/Products/Debug/Dev Monitor.app"
```

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). In short:

```
DevMonitor/
  App/        @main App (WindowGroup + MenuBarExtra), AppState (@Observable @MainActor)
  Model/      Project, AppSettings (+SettingsStore, BrowserList), SessionState, MetricPoint, IPCProtocol
  Store/      ProjectStore (Application Support JSON)
  Core/       Detector, DevSession (supervisor+metrics+health), ProcessTree, SystemSampler
              (+pressure detection), BuildRunner, IPCServer, Notifier, AppLog, ClaudeRunner,
              ResourceAdvisor (advise / pressureKills(Haiku) / heuristicKills)
  Sys/        spawn.c (posix_spawn SETSID + CLOEXEC_DEFAULT), metrics.c (libproc/mach + swap +
              listen-port), ipc.c (FD_CLOEXEC) + bridging header
  Views/      RootSplitView, ProjectSidebar, DashboardView, LogPaneView, MenuBarView, ServerConfigView,
              ProjectSettingsSheet, AppSettingsView, PressureSuggestionsView, ReportSheet (P7),
              AdvisorSheet (P9), PillButton, SessionState+UI
  Resources/  Assets.xcassets (AppIcon + monochrome github + skull), Info.plist
  tools/      make-icon.swift (Core Graphics app-icon generator)
dev-monitor/  CLI target (IPC client — up/run/build/status[--json]/stop[--all]/restart/logs, auto-starts the app)
```

## Technical notes

A few non-obvious things this codebase gets right (verified with headless tests under `tests/`):

- **Spawn with `zsh -lc … exec`** (login, *not* interactive) so the user's PATH/fnm resolves while
  avoiding the interactive `.zshrc` (p10k/fnm) that reparents the real shell out of our process
  group and prints session-restore noise. `exec` makes the dev process the session leader we
  spawned, so the whole tree is enumerable and killable.
- **Process enumeration by session id** (`getsid` + `proc_listpids(PROC_SESSION…)`-style), robust to
  process-group churn. `killpg` reaps exactly what we measure.
- **CPU times need timebase conversion**: `proc_pid_rusage` returns CPU time in *mach* units on
  Apple Silicon (not nanoseconds); scaled via `mach_timebase_info` (1:1 on Intel).
- **Spawned servers must not inherit the IPC socket**: the supervisor spawns with
  `POSIX_SPAWN_CLOEXEC_DEFAULT` (and sets `FD_CLOEXEC` on the hub sockets), so a long-lived dev
  server can't inherit the `dev-monitor` client socket — otherwise a cold-launch CLI call blocks on
  `read()` until the server dies, because the connection never sees EOF.
- **Nuxt's dev-lock is agent-only**: `std-env` enables it whenever `CLAUDECODE`/`AI_AGENT` is set,
  so it fires inside Claude Code terminals. Servers are spawned with `NUXT_IGNORE_LOCK=1`, and the
  app's own (LaunchServices) environment has no agent vars, so app-spawned servers never lock.
- **External dev servers are identified, not just listed**: a process whose argv looks like a dev
  server (`looksLikeDevServer`) is labelled *project :port* — project from the path before
  `/node_modules/`, port from `dm_proc_listen_port` (a `proc_pidfdinfo` scan for the LISTENing TCP
  socket). It's flagged `isExternalDev` (purple) but never supervised (no probe/recycle).

## Install (local)

A Release build installs the app to `/Applications` and the CLI to `~/.local/bin`:

```bash
xcodebuild -project DevMonitor.xcodeproj -scheme DevMonitor  -configuration Release -derivedDataPath build build
xcodebuild -project DevMonitor.xcodeproj -scheme dev-monitor -configuration Release -derivedDataPath build build
cp -R "build/Build/Products/Release/Dev Monitor.app" "/Applications/Dev Monitor.app"
cp    "build/Build/Products/Release/dev-monitor"      ~/.local/bin/dev-monitor
```

The app is **ad-hoc signed** (no Developer ID on this machine) — fine for local use. The
`dev-monitor` CLI auto-starts the app via LaunchServices when the hub isn't already running.

## Tests

`bash tests/run-tests.sh` is the one command that verifies the whole project still works, in two
phases (add `--unit` to skip the slower Phase 1):

**Phase 1 — full compile.** Regenerates the project and builds *both* targets (app + CLI). This
catches SwiftUI/view errors that the standalone unit suites can't see (the views aren't compiled by
swiftc in Phase 2).

**Phase 2 — headless unit suites** (each compiles the real source files standalone with `swiftc`,
no Xcode host, no GUI):

- **spawn** — `posix_spawn` session + cwd + `killpg` tree reap.
- **metrics** — `proc_pid_rusage` (timebase-scaled), system CPU/mem/swap, child enumeration.
- **detector** — package-manager/framework detection over real local projects.
- **model** — `Project` Codable backward-compat (legacy JSON → auto defaults), `effectiveMemoryGB`,
  encode/decode round trip.
- **sampler** — `SystemSampler.aggregate` (dev/build identified rows + impact filter) and
  `evaluatePressure` (the stuck-machine state machine: sustain, hysteresis, reasons).
- **session** — `DevSession` launch → port parse → HTTP-ready → stop, recycle, build success/failure.
- **advisor** — `ResourceAdvisor` snapshot rendering, tolerant JSON parsing of Claude's reply, the
  heuristic kill list (protected-process exclusion, impact ranking), and orphan dev-server detection
  (`looksLikeDevServer`: matches real `nuxt/vite/next` servers, rejects editor servers / Chrome).

When you add a feature, prefer extracting its decision logic into a pure (ideally `nonisolated
static`) function so it can be unit-tested here, and add or extend a suite. The Claude integrations
(Diagnose, Advisor) reuse the same read-only `ClaudeRunner.run` path and were additionally verified
live against the logged-in `claude` CLI.
