# Using Dev Monitor from the terminal

While the Dev Monitor app is running it hosts a local hub (Unix socket at
`~/Library/Application Support/DevMonitor/dm.sock`). Any terminal — or a Claude Code instance —
can drive it with the `dev-monitor` CLI instead of running the dev server directly.

## Commands

| Command | What it does |
|---------|--------------|
| `dev-monitor up [path] [--gb N]` | Start + supervise a project (default: cwd) through the app. **Idempotent** — a no-op that reports the port if that project's server is already running. Auto-detects pnpm/npm + framework; optional heap override. (`run` is an alias.) |
| `dev-monitor build [path]` | Build the project. If its dev server is running, **stops it first** (so dev & build don't fight over the same build dir, e.g. Nuxt's `.nuxt`), runs the build, then **relaunches** the server. |
| `dev-monitor status [--json]` | List **every** supervised server (name, state, port). `--json` prints a machine-readable array for scripts/agents. |
| `dev-monitor stop [path] [--all]` | Stop one project's server (default: cwd), or `--all` of them. |
| `dev-monitor restart [path]` | Recycle (kill the tree + relaunch) the project's server (default: cwd). |
| `dev-monitor logs [-f]` | Print, or follow with `-f`, the live server log. |
| `dev-monitor docs` | Print help. |

Paths default to the current directory. The Dev Monitor app hosts the hub; if it isn't running the
CLI **starts it automatically** (via LaunchServices) and waits for the hub before issuing the command.

## Diagnostics channel

The app mirrors the active server's log (ANSI-stripped) to
`~/Library/Application Support/DevMonitor/dev-server.log`. Follow it live with
`dev-monitor logs -f` or `tail -f` that path. This is how an agent can watch a server's
output and errors while it runs.

## Warm-up note

A dev server often prints `Local: http://localhost:PORT` long before it actually accepts HTTP
(e.g. ~25s of Vite compilation). Dev Monitor stays in "Launching…" during warm-up and only flips
to "Running" after the **first successful HTTP probe** — it never recycles during warm-up.

## For Claude Code / agents in other terminals

Route dev servers and JS builds through the app instead of running them directly:

```bash
dev-monitor up          # instead of `npm run dev` / `pnpm dev` / `nuxt dev`
dev-monitor build       # instead of `npm run build` (stops the server, builds, relaunches)
dev-monitor status      # what's already running (add --json to parse)
```

so Dev Monitor supervises each one — auto-recycle on hang, live resource graphs, notifications —
and you keep every server under one observable place instead of scattered across terminals.

This is enforced machine-wide by a **Claude Code hook** that hard-blocks raw `npm run dev` /
`nuxt dev` / framework builds and points back at `dev-monitor`. See
[`integrations/claude/`](../integrations/claude/) to install it. Because the app is launched by
LaunchServices (its environment has no `CLAUDECODE`/`AI_AGENT` vars), routing through it also
sidesteps Nuxt's agent-only dev-lock; servers are additionally spawned with `NUXT_IGNORE_LOCK=1`.

## Notes

- **One supervised server per project**, keyed by project path — several projects can run at once.
  `dev-monitor up` is idempotent per project; `status` lists them all.
- The heap size (`--gb`) maps to `NODE_OPTIONS=--max-old-space-size`. On an 8 GB Mac, prefer 4 GB
  over 8 GB to avoid memory pressure.
- A server you start **outside** the app is still identified in the activity table and the menu-bar
  list as *project :port* (in **purple**, vs blue for supervised ones) — but it isn't supervised:
  only servers started through Dev Monitor are health-probed and recycled.
