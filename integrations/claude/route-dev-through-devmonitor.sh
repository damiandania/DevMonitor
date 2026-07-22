#!/bin/bash
# PreToolUse(Bash) hook — route dev servers and JS builds through the DevMonitor app.
#
# DevMonitor supervises ONE dev server per project. Starting a server (or a JS build) directly
# fights it (port/.nuxt collisions, the Nuxt dev-lock, the pressure auto-killer). So we hard-block
# the raw command and tell Claude to use the `dev-monitor` CLI, which talks to the app.
#
# exit 2 + stderr => Claude Code blocks the call and shows stderr to the model.
# There is deliberately NO inline escape hatch — dev/build/preview launches ALWAYS route through the
# app. To run one unsupervised, uninstall the hook: Dev Monitor > Settings > General > Claude Code.
input=$(cat)
cmd=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_input.command raw -o - - 2>/dev/null)
cwd=$(printf '%s' "$input" | /usr/bin/plutil -extract cwd raw -o - - 2>/dev/null)
[ -z "$cwd" ] && cwd='.'
[ -z "$cmd" ] && exit 0

# A command's first real word — after any leading VAR=val assignments and an optional path prefix —
# being a known read-only INSPECTION tool means that SEGMENT is just looking, not launching (e.g.
# `pgrep -fl 'nuxt dev'`, `grep vite file`, `ps aux`). Such a segment is allowed as-is.
INSPECT_RE='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=([^[:space:]"'"'"']*|"[^"]*"|'"'"'[^'"'"']*'"'"')[[:space:]]+)*([^[:space:]]*/)?(pgrep|pkill|kill|grep|egrep|fgrep|rg|ag|ack|ps|echo|printf|cat|bat|less|more|head|tail|ls|find|fd|which|type|command|whereis|whatis|man|lsof|awk|sed|tr|cut|sort|uniq|wc|jq|yq|stat|file|dirname|basename|realpath|readlink|true|false|test|tmux|history)([[:space:]]|$)'

# Match a real launch. `sep` no longer excludes '/', so a path-qualified launch
# (`./node_modules/.bin/nuxt dev`, `/usr/local/bin/next dev`, `node_modules/.bin/vite`) is caught too.
sep='(^|[^[:alnum:]_.-])'
DEV_RE="${sep}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?dev([^[:alnum:]_:-]|$)|${sep}(nuxt|next|astro|vinxi)[[:space:]]+dev([^[:alnum:]_-]|$)|${sep}vite([[:space:]]+(dev|serve|--)|[[:space:]]*$)|${sep}ng[[:space:]]+serve([^[:alnum:]_-]|$)|${sep}(webpack[[:space:]]+serve|webpack-dev-server)|${sep}remix[[:space:]]+vite:dev"
BUILD_RE="${sep}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?build([^[:alnum:]_:-]|$)|${sep}(nuxt|next|astro|ng|vite|vinxi)[[:space:]]+build([^[:alnum:]_-]|$)"
PREVIEW_RE="${sep}(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?preview([^[:alnum:]_:-]|$)|${sep}(nuxt|nuxi|vite|astro)[[:space:]]+preview([^[:alnum:]_-]|$)|${sep}next[[:space:]]+start([^[:alnum:]_-]|$)"

# Judge each shell SEGMENT independently, so a real launch can't ride behind an allowed prefix
# (`echo x && npm run dev`, `pgrep foo | npm run build`, `dev-monitor stop X && npm run build`). We
# split on && || ; | and newlines: `tr` maps &,|,; to a newline (nl), and && / || just yield an empty
# middle segment (skipped). Over-splitting a quoted separator (e.g. grep -E 'a|b') only ever inspects
# MORE segments — it can never merge a hidden launch into an allowed one, so it cannot create a bypass.
nl='
'
block=''
while IFS= read -r seg || [ -n "$seg" ]; do
  printf '%s' "$seg" | grep -q '[^[:space:]]' || continue    # blank segment
  printf '%s' "$seg" | grep -qE "$INSPECT_RE" && continue     # a read-only inspection segment
  printf '%s' "$seg" | grep -qE "$DEV_RE"     && { block=dev;     break; }
  printf '%s' "$seg" | grep -qE "$BUILD_RE"   && { block=build;   break; }
  printf '%s' "$seg" | grep -qE "$PREVIEW_RE" && { block=preview; break; }
done < <(printf '%s' "$cmd" | tr '&|;' "$nl")

case "$block" in
  dev)
    echo "BLOCKED — dev servers on this machine run through DevMonitor (one supervised server per project)." >&2
    echo "Do not start a dev server directly. Instead run:  dev-monitor up '$cwd' --wait   (blocks until ready, prints the URL)" >&2
    echo "If a build is in progress (this or ANY project), that command WAITS and starts the server automatically once the build finishes — keep listening for the 'ready:' line; do NOT retry, kill the build, or launch it another way." >&2
    echo "Inspect with: dev-monitor status --json   (ready/url/pid/exitCode/lastError + building/buildElapsed/buildETA per project)" >&2
    echo "Full surface: dev-monitor --help" >&2
    exit 2 ;;
  build)
    echo "BLOCKED — builds run through DevMonitor so the project's dev server is stopped first." >&2
    echo "Instead run:  dev-monitor build '$cwd'   (stops the server, builds, relaunches it; prints a ✅/❌ verdict + exits non-zero on failure)." >&2
    echo "If it fails, read the WHOLE error (not just the printed tail):  dev-monitor logs '$cwd' --build" >&2
    exit 2 ;;
  preview)
    echo "BLOCKED — preview servers (serving the production build) also run through DevMonitor." >&2
    echo "Instead run:  dev-monitor preview '$cwd' --wait   (blocks until ready, prints the URL)." >&2
    echo "If a build is in progress, that command WAITS and starts the preview automatically once it finishes — keep listening; do NOT retry or launch it another way." >&2
    exit 2 ;;
esac
exit 0
