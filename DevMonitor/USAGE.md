# Using Dev Monitor from the terminal

While the Dev Monitor app is running it hosts a local hub (Unix socket at
`~/Library/Application Support/DevMonitor/dm.sock`). Any terminal — or a Claude Code instance —
can drive it with the `dev-monitor` CLI instead of running the dev server directly.

## Commands

| Command | What it does |
|---------|--------------|
| `dev-monitor up [path] [--gb N] [--wait]` | Start + supervise a project (default: cwd). **Idempotent** — a no-op that reports the port if already running. Auto-detects pnpm/npm + framework. `--gb N` overrides the heap (and pins it). `--wait` blocks until the server is HTTP-ready and prints its URL (or exits non-zero with the failure cause). (`run` is an alias.) |
| `dev-monitor build [path]` | Build the project **alongside** its dev server (the running server is left untouched). Adds a build tab to the global terminal. |
| `dev-monitor status [--json]` | List **every known** project (idle or running) with state + port. `--json` adds a machine-readable array with `ready`, `url`, `pid`, `exitCode`, `lastError`, `logPath` — everything an agent needs to operate and diagnose. |
| `dev-monitor stop [path] [--all]` | Stop one project's server (default: cwd), or `--all` of them. |
| `dev-monitor restart [path]` | Relaunch the project's server. Works from **any** state — including `Failed`/`Idle` (relaunches), not just a live server. |
| `dev-monitor remove [path]` | Stop the server and **forget** the project (removes it from `projects.json`). Aliases: `rm`, `forget`. |
| `dev-monitor logs [path] [-f]` | Print, or follow with `-f`, **that project's own** log (default: cwd). One log file per project. |
| `dev-monitor version` | Print the version (aliases: `-v`, `--version`). |
| `dev-monitor docs` | Print help (aliases: `--help`, `-h`). |

Paths default to the current directory and are resolved to **absolute**. Invalid input fails loudly:
a path that isn't a project folder (no `package.json` / Deno config) is rejected; unknown flags and a
malformed `--gb` (non-positive / non-integer) error with a clear message and a non-zero exit. The Dev
Monitor app hosts the hub; if it isn't running the CLI **starts it automatically** (via LaunchServices)
and waits for the hub before issuing the command.

## Readiness — don't poll the port yourself

A dev server often prints `Local: http://localhost:PORT` long before it actually accepts HTTP (e.g.
~25s of Vite/Nuxt compilation). Dev Monitor stays `Launching…` during warm-up and only flips to
`Running` after the **first successful HTTP probe** — it never recycles during warm-up. So:

- `dev-monitor up --wait` blocks until ready and prints `ready: http://localhost:PORT/` (or the cause on failure).
- `dev-monitor status --json` exposes `ready` (bool) and `url` — read those instead of `curl`-ing the port.

## Diagnosing a failure — without reading internal files

When a server fails, `status --json` carries the cause so you can self-correct:

- `state` — e.g. `Failed: out of memory — relaunch with more heap (e.g. dev-monitor up --gb 8)`
- `exitCode` — the last process exit code
- `lastError` — a human-readable cause with a remedy when known (OOM is detected and the heap fix is suggested)

```jsonc
// dev-monitor status --json
[
  { "name": "MiddleSpace", "path": "…/MiddleSpace", "state": "Running · :3000",
    "ready": true, "url": "http://localhost:3000/", "pid": 12345, "port": 3000,
    "logPath": "…/DevMonitor/logs/MiddleSpace-CA6AA3C8.log" }
]
```

## Memory (heap)

The heap maps to `NODE_OPTIONS=--max-old-space-size`. It is **deterministic**:

- **Auto** (default): the framework default — Nuxt/Next 8 GB, Astro/Vite 4 GB, Node/Express 2 GB —
  never a stale stored value. (This is the fix for the 1 GB → OOM bug.)
- **Manual**: `dev-monitor up --gb N` pins an explicit value (and turns auto off).
- Always **floored** at 2 GB and **capped at physical RAM**. If you ask for more than the machine
  has, the launch reports it: `launched X (Nuxt, 8 GB — capped from 99 GB to fit 8 GB RAM)`.
- **OOM recovery**: a crash that looks like a V8 out-of-memory is retried once with a bigger heap; if
  it still can't fit, the server is left `Failed` with an OOM `lastError` suggesting `--gb`.

## Supervision

- **One supervised server per project**, keyed by path — several projects run at once. `up` is
  idempotent per project; `status` lists them all.
- **Hang detection**: a server that stops responding is recycled (kill tree + relaunch).
- **Crash auto-revive**: a server that *was* healthy then dies is auto-restarted with exponential
  backoff (1s, 2s, 4s), bounded to 3 attempts per stable run — and the **port is pinned** across
  restarts so it doesn't drift (3000 → 3001). A server that never became healthy (a config error) is
  left `Failed` rather than looped.
- A notification subsystem failure can never take the app down — supervision is crash-proof.

## Logs

Each project has its **own** log file under `~/Library/Application Support/DevMonitor/logs/`
(`<name>-<id>.log`), retained across runs (a crash log survives the next launch). `dev-monitor logs
[path]` resolves and prints it; `-f` follows it live.

## For Claude Code / agents in other terminals

Route dev servers and JS builds through the app instead of running them directly:

```bash
dev-monitor up --wait     # instead of `npm run dev` / `pnpm dev` / `nuxt dev` — blocks, prints the URL
dev-monitor build         # instead of `npm run build` (runs alongside the server)
dev-monitor status --json # ready/url/pid/exitCode/lastError per project (parseable)
```

so Dev Monitor supervises each one — auto-recycle on hang, auto-revive on crash, live resource
graphs, notifications — and you keep every server under one observable place.

This is enforced machine-wide by a **Claude Code hook** that hard-blocks raw `npm run dev` /
`nuxt dev` / framework builds and points back at `dev-monitor` (with `--help` / `status --json` for the
full surface). See [`integrations/claude/`](../integrations/claude/) to install it. Because the app is
launched by LaunchServices (its environment has no `CLAUDECODE`/`AI_AGENT` vars), routing through it
also sidesteps Nuxt's agent-only dev-lock; servers are additionally spawned with `NUXT_IGNORE_LOCK=1`.

## Notes

- Editing `projects.json` by hand does **not** hot-reload — the app reads it at launch (and prunes
  entries whose folder no longer exists). Use the CLI (`up` / `remove`) instead of editing the file.
- A server you start **outside** the app is still identified in the activity table and menu-bar list
  as *project :port* (in **indigo**, vs blue for supervised ones) — but it isn't supervised: only
  servers started through Dev Monitor are health-probed, recycled and auto-revived.
