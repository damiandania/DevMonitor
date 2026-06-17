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
| P4 — Notifications | ⏳ | Native notifications (crash/hang/recycle/build) with sound |
| P5 — Build runner | ⏳ | Run the project's build script as a tracked tree |
| P6 — Hub + CLI + docs | ⏳ | Unix-socket hub + `dev-monitor` CLI (run/status/logs) |
| P7 — Claude reports | ⏳ | Read-only error reports about Dev Monitor itself |
| P8 — Polish & dist | ⏳ | Liquid Glass pass, MenuBarExtra, icon, Release + CLI install |
| P9 — Resource advisor | ⏳ | Claude-recommended actions on heavy processes (ask before killing non-dev) |

## Features (current)

- **Auto-detects** package manager (pnpm/npm) and framework (Nuxt/Next/Astro/Express) per project.
- **Launches** the dev server with a chosen heap size (`--max-old-space-size`), streaming its log live.
- **Live charts**: system CPU, system memory, dev-server tree CPU and memory.
- **Hang detection + auto-recycle**: HTTP probes the server; after consecutive failures it kills the
  whole process tree (including orphans) and relaunches.

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
  App/        @main App, AppState (@Observable @MainActor)
  Model/      Project, SessionState, MetricPoint
  Store/      ProjectStore (Application Support JSON)
  Core/       Detector, DevSession (supervisor+metrics+health), ProcessTree
  Sys/        spawn.c (posix_spawn SETSID), metrics.c (libproc/mach) + bridging header
  Views/      RootSplitView, ProjectSidebar, DashboardView, LogPaneView, Charts/
dev-monitor/  CLI target (IPC client — P6)
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

## Tests

Headless Swift test programs live under `tests/` and validate the C shims and the `DevSession`
supervisor end-to-end (spawn/cwd/killpg, detector over real projects, metrics, recycle).
