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

### Model/ · Store/
- `Project` (Codable, persisted to Application Support), `SessionState` (state machine),
  `MetricPoint` (one sample). `ProjectStore` loads/saves the project list.

### Views/
- `RootSplitView` (sidebar + dashboard), `ProjectSidebar`, `DashboardView` (status, launch
  controls, GB stepper), `LogPaneView`, `Charts/MetricsGrid`.

## Concurrency model

- `DevSession` is `@MainActor @Observable`. Background producers (pipe reader, process-exit
  watcher) are `DispatchSource` handlers that capture **only Sendable values** and feed an
  `AsyncStream<Chunk>`; a single `@MainActor` task consumes and mutates state. Sampling and health
  run as `@MainActor` tasks with `Task.sleep`, cancelled on stop/recycle.

## Why these choices

See the "Technical notes" in the README — the `zsh -lc + exec`, session-id enumeration, and
mach-timebase fixes were each found via the headless tests in `tests/`.
