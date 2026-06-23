# Architecture

Dev Monitor is a non-sandboxed SwiftUI app (Swift 6, macOS 26 SDK) plus a small CLI target.
State is `@Observable @MainActor`; long-running work (output streaming, sampling, health probing)
runs off the main actor and hops back through `AsyncStream`/`Task { @MainActor }`.

## Layers

### Sys/ — C interop
- **`spawn.c`** — `dm_spawn_session(command, cwd, &fd)`: `posix_spawn` of `/bin/zsh -lc <command>`
  with `POSIX_SPAWN_SETSID` (own session/pgid → `killpg` reaps the whole tree) and stdout+stderr
  merged into one pipe. The dev command is built as `… exec <devcmd>` so the spawned process
  *becomes* the dev server (the session leader), not a parent shell. `-lc` is login but
  **non-interactive** (no `.zshrc`), so the Node version-manager `PATH` (fnm/nvm) is supplied by
  `ShellEnvironment` (see Core/) rather than by the shell itself.
- **`ipc.c`** — Unix-socket hub primitives (`dm_ipc_listen`/`accept`/`connect`). `listen` probes for
  a live hub before reclaiming a socket, so a second instance can't steal it from a running one;
  only a stale socket is unlinked.
- **`metrics.c`** — `libproc`/`mach` shims:
  - `dm_proc_stat_for(pid)` → cumulative CPU ns (via `proc_pid_rusage`, scaled by
    `mach_timebase_info` because rusage CPU is in mach units on Apple Silicon) + `ri_phys_footprint`.
  - `dm_system_cpu_ticks` (`host_processor_info`), `dm_system_mem` (`host_statistics64` + `sysctl`),
    `dm_load_avg` (`getloadavg`).
  - `dm_session_pids(sid)` — every pid whose session id == `sid` (robust to p10k/fnm reparenting);
    `dm_child_pids` / `dm_pgrp_pids` kept as alternatives.

### Core/
- **`Detector`** — reads the lockfile + `package.json` to infer package manager, framework, dev/build
  commands and default heap. Pure, headless-testable. Frameworks: Nuxt · Next · Astro · SvelteKit ·
  Remix · SolidStart · Angular · Qwik · Vite · Express · Node (the Vite-based ones are matched first).
- **`HeapScaling`** — pure heap-autoscale policy: the **4 → 6 → 8** ladder + OOM detection, shared by
  the dev server and the build. See **`docs/HEAP-AND-BUILD.md`** for the whole heap/build story.
- **`ShellEnvironment`** — resolves the user's login+interactive shell `$PATH` (where fnm/nvm/asdf
  install their shims) and exports it into the process before each launch, so the non-interactive
  spawn shell can still find `node`/`npm`. Resolved fresh per launch (fnm's per-shell dir is
  ephemeral), with a short cache and a timeout.
- **`ProcessTree`** — `sessionMembers(of:)` enumerates the supervised tree by session id.
- **`DevSession`** — the heart. Per project it:
  1. **Launches** via `dm_spawn_session`; streams the merged pipe through a `DispatchSource` →
     `AsyncStream` → main-actor consumer; parses the port (`Local: …:<port>`) and ready signal.
  2. **Samples** (1 Hz): sums CPU-time deltas and memory over the session, plus system CPU/mem,
     into a rolling `[MetricPoint]` buffer for Swift Charts.
  3. **Probes health** (HTTP GET, configurable interval/strikes): on consecutive failures →
     `recycle()` (kill tree via `killpg`, relaunch with the same heap). Distinguishes a manual
     `stop()` (→ Stopped) from a crash (→ Failed) from a recycle.
  4. **Autoscales the heap** on an out-of-memory exit: relaunches one rung up the 4 → 6 → 8 ladder
     (`HeapScaling`), and in auto mode persists the learned level so the next launch starts there.
     The build has the same autoscaler, driven from `AppState.runBuildAndWait`. See
     `docs/HEAP-AND-BUILD.md`.
- **`SpawnedProcess`** — the single owner of the spawn → `DispatchSource` (read + exit) →
  `AsyncStream<Chunk>` plumbing. `DevSession` and `BuildRunner` consume its `chunks` and layer their
  own policy on top (port detection + health for the server, nothing extra for a build). Supporting
  primitives: `ProcessSupport` (`decodeExitCode`, `gracefulKillGroup`, `nodeHeapFlag`), `LineBuffer`
  (`\n`-splitting with partial-line carryover), `LogNoise` (the shared shell session-restore filter).
- **`BuildRunner`** — a one-shot tracked build process (same spawn/stream plumbing), reporting
  success/failure. A user-initiated `stop()` is not reported as a build *failure*. Records its
  start time + duration (the latter becomes the next build's progress-bar ETA).
- **`WorkerRunner`** — supervises a project's long-running background **worker** (a queue/job worker,
  `tsx watch …`): same spawn/stream plumbing as the build, but no port/health — it just runs and
  reports running / stopped / crashed.
- **Preview** — serving a production build (`npm run preview` / `next start`) reuses `DevSession`
  via a `commandOverride`, so it gets the same port/health/log supervision as the dev server.
- **`PressureManager`** — the machine-pressure subsystem: the "under pressure" state, the one-shot
  auto-close of orphaned dev processes, and the kill suggestions (heuristic + Haiku). Owned by
  `AppState` via an unowned back-reference.
- **`AsyncJob<Output>`** — a one-at-a-time cancellable async job (latest result + running flag);
  backs the Doctor's three AI analyses, which used to duplicate the guard/flag/`Task`/cancel dance.

### App/
- **`AppState`** (`@MainActor @Observable`) — the root store, split across cohesive extensions:
  `AppState+Projects` (project CRUD + the per-project setters, all funneled through one
  `mutate(_:_:)` helper), `AppState+Builds` (the pause-servers → relieve-pressure → autoscale build
  orchestration), and `AppState+Doctor` (the three AI analyses, backed by `AsyncJob`). Every
  notification is funneled through `route(_:)`; classification/wording lives in `NotificationPolicy`.

### Model/ · Store/
- `Project` (Codable, persisted to Application Support), `SessionState` (state machine),
  `MetricPoint` (one sample). `ProjectStore` loads/saves the project list.

### Views/
- `RootSplitView` (sidebar + dashboard), `ProjectSidebar`, `LogPaneView`, `Charts/MetricsGrid`.
- **`RunControl`** is the single source of a project's run-controls (dev, worker, build, preview):
  `AppState.runControls(for:)` lists them once, and the dashboard pills (`RunControlButton` driven by
  the shared `RunStatus`), the menu-bar rows and the terminal tabs all render that one list — so
  adding a new supervised process type makes it appear in every surface (and the menu-bar health
  glyph) automatically. `RunTimerBar` shows a server/worker uptime or a build's elapsed + ETA in the
  terminal pane.

## Concurrency model

- `DevSession` is `@MainActor @Observable`. Background producers (pipe reader, process-exit
  watcher) are `DispatchSource` handlers — now owned by `SpawnedProcess` — that capture **only
  Sendable values** and feed an `AsyncStream<Chunk>`; a single `@MainActor` task consumes and
  mutates state. Sampling and health run as `@MainActor` tasks with `Task.sleep`, cancelled on
  stop/recycle.

## Why these choices

See the "Technical notes" in the README — the `zsh -lc + exec`, session-id enumeration, and
mach-timebase fixes were each found via the headless tests in `tests/`.
