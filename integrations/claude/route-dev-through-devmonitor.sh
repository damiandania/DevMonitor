#!/bin/bash
# PreToolUse(Bash) hook — routes dev servers and JS builds through the DevMonitor app.
#
# DevMonitor is the single authority that supervises ONE dev server per project. Starting a
# server (or a JS build) directly fights it (port/.nuxt collisions, the Nuxt dev-lock, the
# pressure auto-killer). So we hard-block the raw command and tell Claude to use the CLI, which
# talks to the app over its Unix socket.
#
# Mechanism: exit 2 + stderr → Claude Code blocks the call and shows stderr to the model.
# Escape hatch: prefix the command with `DM_RAW=1 ` to run it untouched.
# Edit the DEV_RE / BUILD_RE patterns below to tune what gets intercepted.

input=$(cat)

# Extract the shell command (and cwd for a helpful hint). plutil ships with macOS — no jq needed.
cmd=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_input.command raw -o - - 2>/dev/null)
cwd=$(printf '%s' "$input" | /usr/bin/plutil -extract cwd raw -o - - 2>/dev/null)
[ -z "$cwd" ] && cwd='.'
[ -z "$cmd" ] && exit 0                                   # nothing to inspect → allow

# Allow the corrected command through, and honour the explicit escape hatch.
printf '%s' "$cmd" | grep -q 'dev-monitor'   && exit 0
printf '%s' "$cmd" | grep -q 'DM_RAW=1'      && exit 0

sep='(^|[^[:alnum:]_/.-])'                                # a boundary before the keyword

# --- dev-server starts -------------------------------------------------------------------------
DEV_RE="${sep}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?dev([^[:alnum:]_:-]|$)\
|${sep}(nuxt|next|astro|vinxi)[[:space:]]+dev([^[:alnum:]_-]|$)\
|${sep}vite([[:space:]]+(dev|serve|--)|[[:space:]]*$)\
|${sep}ng[[:space:]]+serve([^[:alnum:]_-]|$)\
|${sep}(webpack[[:space:]]+serve|webpack-dev-server)\
|${sep}remix[[:space:]]+vite:dev"

# --- JS/framework builds (NOT xcodebuild/go/cargo/docker/make) ---------------------------------
BUILD_RE="${sep}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?build([^[:alnum:]_:-]|$)\
|${sep}(nuxt|next|astro|ng|vite|vinxi)[[:space:]]+build([^[:alnum:]_-]|$)"

if printf '%s' "$cmd" | grep -qE "$DEV_RE"; then
  cat >&2 <<EOF
BLOCKED — dev servers on this machine run through DevMonitor (one supervised server per project).
Do not start a dev server directly. Instead run:

    dev-monitor run "$cwd"      # idempotent — no-op if it's already up

Check what's already running with:  dev-monitor status
This routes through the DevMonitor app (its env has no agent vars, so Nuxt's dev-lock won't fire).
To bypass intentionally, prefix the command with: DM_RAW=1
EOF
  exit 2
fi

if printf '%s' "$cmd" | grep -qE "$BUILD_RE"; then
  cat >&2 <<EOF
BLOCKED — builds run through DevMonitor so the project's dev server is stopped first (they share
the same build dir, e.g. Nuxt's .nuxt). Instead run:

    dev-monitor build "$cwd"    # stops the running server, builds, then relaunches it

To bypass intentionally, prefix the command with: DM_RAW=1
EOF
  exit 2
fi

exit 0
