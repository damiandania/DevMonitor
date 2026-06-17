#!/usr/bin/env bash
# Headless tests for Dev Monitor's C shims and the DevSession supervisor.
# These compile the real source files standalone (no Xcode host needed).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/DevMonitor"
SYS="$SRC/Sys"
HDR="$SYS/DevMonitor-Bridging-Header.h"
BIN="$(mktemp -d)"
export SHELL_SESSIONS_DISABLE=1
fail=0

build_run() {
  local name="$1"; shift
  echo "=== $name ==="
  if swiftc "$@" -o "$BIN/$name" 2>"$BIN/$name.err"; then
    "$BIN/$name" || fail=1
  else
    echo "COMPILE FAILED:"; grep -E "error:" "$BIN/$name.err" | head; fail=1
  fi
  echo ""
}

build_run spawn    "$ROOT/tests/spawn/main.swift" "$SYS/spawn.c" -import-objc-header "$HDR"
build_run metrics  "$ROOT/tests/metrics/main.swift" "$SYS/metrics.c" "$SYS/spawn.c" -import-objc-header "$HDR"
build_run detector "$ROOT/tests/detector/main.swift" "$SRC/Model/Project.swift" "$SRC/Core/Detector.swift"
build_run session  -enable-bare-slash-regex "$ROOT/tests/session/main.swift" \
  "$SRC/Model/Project.swift" "$SRC/Model/SessionState.swift" "$SRC/Model/MetricsSample.swift" \
  "$SRC/Model/SupervisionEvent.swift" \
  "$SRC/Core/Detector.swift" "$SRC/Core/ProcessTree.swift" "$SRC/Core/DevSession.swift" \
  "$SYS/metrics.c" "$SYS/spawn.c" -import-objc-header "$HDR"

[ "$fail" = 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit $fail
