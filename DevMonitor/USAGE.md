# Using Dev Monitor from the terminal

While the Dev Monitor app is running it hosts a local hub (Unix socket at
`~/Library/Application Support/DevMonitor/dm.sock`). Any terminal — or a Claude Code instance —
can drive it with the `dev-monitor` CLI instead of running the dev server directly.

## Commands

| Command | What it does |
|---------|--------------|
| `dev-monitor run [--gb N]` | Launch + supervise the project in the **current directory** through the app (auto-detects pnpm/npm + framework; optional heap override). |
| `dev-monitor status` | Show the active server (name, state, port). |
| `dev-monitor stop` | Stop the active server. |
| `dev-monitor docs` | Print help. |

The Dev Monitor app must be open (it hosts the hub). If it isn't, the CLI says so.

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
