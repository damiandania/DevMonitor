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
| P9b — Pressure auto-kill | ✅ | Detects a stuck machine (sustained CPU, or memory full + swapping) → fast **Haiku** eval of which orphan/heavy processes to kill, surfaced in the sidebar with a red **skull** button |

¹ Signed ad-hoc (`CODE_SIGN_IDENTITY = -`): no Apple Developer ID identity is installed on this
machine. Local notifications and the menu-bar item work; for distribution outside this Mac, sign
with a Developer ID and notarize.

## Features (current)

- **Auto-detects** package manager (pnpm/npm) and framework (Nuxt/Next/Astro/Express) per project.
- **Launches** the dev server with a chosen heap size (`--max-old-space-size`), streaming its log live.
- **Live activity**: system **CPU / Memory / Swap** progress bars + an Activity-Monitor-style table
  of only the processes with real impact (heavy CPU or memory), with the dev-server tree aggregated
  into one row. CPU is per-core (100% = one core), so a busy tree can read >100% like Activity
  Monitor; the "% of machine" toggle re-expresses it as a share of total capacity. Generic helpers
  (`node`, "Code Helper") are named from the extension's own `package.json` `displayName` (resolving
  `%key%` via `package.nls.json`) — e.g. *Vue (Official)*, *ESLint*, *Tailwind CSS IntelliSense*.
- **Server configuration** (bottom of the sidebar): per-project **Memory / Port / Package**, each
  with an **Auto** toggle (on by default); turn it off to set a manual value (slider / field /
  npm·pnpm picker). Auto memory follows the framework default; auto port is parsed from stdout.
- **Hang detection + auto-recycle**: HTTP probes the server; after consecutive failures it kills the
  whole process tree (including orphans) and relaunches.
- **Pressure auto-kill**: when the machine is detected as *stuck* (CPU pinned, or memory full and
  swapping, for a sustained window), the sidebar surfaces a panel — a fast **Haiku** evaluation of
  which orphan/heavy processes are safe to kill — each with a red **skull** button (SIGTERM →
  SIGKILL). Critical processes (the editor, WindowServer, Finder, daemons, Dev Monitor itself) are
  never suggested. A heuristic list shows instantly while Haiku refines it.
- **Menu-bar item** (`MenuBarExtra`): active-server status, live uptime, Launch/Stop/Restart, and a
  system CPU/memory snapshot without opening the main window.
- **Central hub + CLI**: run servers from any terminal through the app with `dev-monitor run`
  (auto-starts the app if needed); `status` / `stop` / `restart` / `logs -f`. See
  [DevMonitor/USAGE.md](DevMonitor/USAGE.md).
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
  Model/      Project, SessionState, MetricPoint, IPCProtocol
  Store/      ProjectStore (Application Support JSON)
  Core/       Detector, DevSession (supervisor+metrics+health), ProcessTree, SystemSampler
              (+pressure detection), BuildRunner, IPCServer, Notifier, AppLog, ClaudeRunner,
              ResourceAdvisor (advise / pressureKills(Haiku) / heuristicKills)
  Sys/        spawn.c (posix_spawn SETSID), metrics.c (libproc/mach + swap), ipc.c + bridging header
  Views/      RootSplitView, ProjectSidebar, DashboardView, LogPaneView, MenuBarView, ServerConfigView,
              PressureSuggestionsView, ReportSheet (P7), AdvisorSheet (P9), PillButton, SessionState+UI
  Resources/  Assets.xcassets (AppIcon + monochrome github/vscode/chrome/skull), Info.plist
  tools/      make-icon.swift (Core Graphics app-icon generator)
dev-monitor/  CLI target (IPC client — run/status/stop/restart/logs, auto-starts the app)
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

Headless Swift test programs live under `tests/` (run `bash tests/run-tests.sh`). They validate the
C shims and pure logic end-to-end without a GUI:

- **spawn** — `posix_spawn` session + cwd + `killpg` tree reap.
- **metrics** — `proc_pid_rusage` (timebase-scaled), system CPU/mem/swap, child enumeration.
- **detector** — package-manager/framework detection over real local projects.
- **session** — `DevSession` launch → port parse → HTTP-ready → stop, recycle, build success/failure.
- **advisor** — `ResourceAdvisor` snapshot rendering, tolerant JSON parsing of Claude's reply, and
  the heuristic kill list (protected-process exclusion, impact ranking).

The Claude integrations (Diagnose, Advisor) reuse the same read-only `ClaudeRunner.run` path and were
additionally verified live against the logged-in `claude` CLI.
