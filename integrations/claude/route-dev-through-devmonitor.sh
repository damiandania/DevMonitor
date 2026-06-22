#!/bin/bash
# PreToolUse(Bash) hook — route dev servers and JS builds through the DevMonitor app.
#
# DevMonitor supervises ONE dev server per project. Starting a server (or a JS build) directly
# fights it (port/.nuxt collisions, the Nuxt dev-lock, the pressure auto-killer). So we hard-block
# the raw command and tell Claude to use the `dev-monitor` CLI, which talks to the app.
#
# exit 2 + stderr => Claude Code blocks the call and shows stderr to the model.
# Escape hatch: prefix a command with `DM_RAW=1 ` to run it untouched.
# Install/remove from the app: Dev Monitor > Settings > General > Claude Code.
input=$(cat)
cmd=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_input.command raw -o - - 2>/dev/null)
cwd=$(printf '%s' "$input" | /usr/bin/plutil -extract cwd raw -o - - 2>/dev/null)
[ -z "$cwd" ] && cwd='.'
[ -z "$cmd" ] && exit 0
printf '%s' "$cmd" | grep -q 'dev-monitor' && exit 0
printf '%s' "$cmd" | grep -q 'DM_RAW=1' && exit 0

# Read-only / inspection commands that merely MENTION a dev server (e.g. `pgrep -fl 'nuxt dev'`,
# `grep "vite" file`, `ps aux | grep next`) must NOT be blocked. If the command's first real word —
# after any leading VAR=val assignments and an optional path prefix — is a known inspection tool,
# let it through. (This closes the false-positive that blocked plain `pgrep 'nuxt dev'`.)
INSPECT_RE='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=([^[:space:]"'"'"']*|"[^"]*"|'"'"'[^'"'"']*'"'"')[[:space:]]+)*([^[:space:]]*/)?(pgrep|pkill|kill|grep|egrep|fgrep|rg|ag|ack|ps|echo|printf|cat|bat|less|more|head|tail|ls|find|fd|which|type|command|whereis|whatis|man|lsof|awk|sed|tr|cut|sort|uniq|wc|jq|yq|stat|file|dirname|basename|realpath|readlink|true|false|test|tmux|history)([[:space:]]|$)'
printf '%s' "$cmd" | grep -qE "$INSPECT_RE" && exit 0

# Match a real launch. `sep` no longer excludes '/', so a path-qualified launch
# (`./node_modules/.bin/nuxt dev`, `/usr/local/bin/next dev`, `node_modules/.bin/vite`) is caught
# too — that hole is how a launch could previously slip past this hook.
sep='(^|[^[:alnum:]_.-])'
DEV_RE="${sep}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?dev([^[:alnum:]_:-]|$)|${sep}(nuxt|next|astro|vinxi)[[:space:]]+dev([^[:alnum:]_-]|$)|${sep}vite([[:space:]]+(dev|serve|--)|[[:space:]]*$)|${sep}ng[[:space:]]+serve([^[:alnum:]_-]|$)|${sep}(webpack[[:space:]]+serve|webpack-dev-server)|${sep}remix[[:space:]]+vite:dev"
BUILD_RE="${sep}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?build([^[:alnum:]_:-]|$)|${sep}(nuxt|next|astro|ng|vite|vinxi)[[:space:]]+build([^[:alnum:]_-]|$)"
if printf '%s' "$cmd" | grep -qE "$DEV_RE"; then
  echo "BLOCKED — dev servers on this machine run through DevMonitor (one supervised server per project)." >&2
  echo "Do not start a dev server directly. Instead run:  dev-monitor up '$cwd' --wait   (blocks until ready, prints the URL)" >&2
  echo "Inspect with: dev-monitor status --json   (ready/url/pid/exitCode/lastError per project)" >&2
  echo "Full surface: dev-monitor --help          (bypass this hook once with DM_RAW=1)" >&2
  exit 2
fi
if printf '%s' "$cmd" | grep -qE "$BUILD_RE"; then
  echo "BLOCKED — builds run through DevMonitor so the project's dev server is stopped first." >&2
  echo "Instead run:  dev-monitor build '$cwd'   (stops the server, builds, relaunches it)." >&2
  echo "Bypass once with DM_RAW=1." >&2
  exit 2
fi
exit 0
