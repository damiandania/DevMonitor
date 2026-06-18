# Using Dev Monitor from the terminal

While the Dev Monitor app is running it hosts a local hub (Unix socket at
`~/Library/Application Support/DevMonitor/dm.sock`). Any terminal — or a Claude Code instance —
can drive it with the `dev-monitor` CLI instead of running the dev server directly.

## Commands

| Command | What it does |
|---------|--------------|
| `dev-monitor run [path] [--gb N]` | Launch + supervise a project (default: current directory) through the app (auto-detects pnpm/npm + framework; optional heap override). |
| `dev-monitor status` | Show the active server (name, state, port). |
| `dev-monitor stop` | Stop the active server. |
| `dev-monitor restart` | Recycle (kill the tree + relaunch) the active server. |
| `dev-monitor logs [-f]` | Print, or follow with `-f`, the live server log. |
| `dev-monitor docs` | Print help. |

The Dev Monitor app hosts the hub. If it isn't running, the CLI **starts it automatically** (via
LaunchServices) and waits for the hub before issuing the command.

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

When asked to start a dev server for a project, prefer:

```bash
dev-monitor run        # instead of `npm run dev` / `pnpm dev`
```

so Dev Monitor supervises it — auto-recycle on hang, live resource graphs, and notifications.
Query state with `dev-monitor status`. This lets you (or the user) keep every dev server under
one supervised, observable place instead of scattered across terminals.

## Notes

- One actively-supervised server at a time in this MVP (matches the app's UI). Multi-server hub
  is a planned extension.
- The heap size (`--gb`) maps to `NODE_OPTIONS=--max-old-space-size`. On an 8 GB Mac, prefer 4 GB
  over 8 GB to avoid memory pressure.
