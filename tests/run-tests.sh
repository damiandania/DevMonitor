#!/usr/bin/env bash
# Dev Monitor test system — verifies the whole project still works:
#   Phase 1 — the app + CLI actually compile (catches SwiftUI/view errors the unit suites can't).
#   Phase 2 — headless unit suites for the C shims and the pure logic (fast, no Xcode host).
#
# Usage:
#   bash tests/run-tests.sh          # full check (build + units)
#   bash tests/run-tests.sh --unit   # units only (skip the slow build phase)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/DevMonitor"
SYS="$SRC/Sys"
HDR="$SYS/DevMonitor-Bridging-Header.h"
BIN="$(mktemp -d)"
export SHELL_SESSIONS_DISABLE=1
fail=0
UNIT_ONLY=0
[ "${1:-}" = "--unit" ] && UNIT_ONLY=1

# ── Phase 1: full compile of both targets ───────────────────────────────────
if [ "$UNIT_ONLY" = 0 ]; then
  echo "── Phase 1: build app + CLI ────────────────────"
  ( cd "$ROOT" && xcodegen generate ) >/dev/null 2>&1
  for scheme in DevMonitor dev-monitor; do
    if ( cd "$ROOT" && xcodebuild -project DevMonitor.xcodeproj -scheme "$scheme" \
           -configuration Debug -derivedDataPath build build ) >"$BIN/build-$scheme.log" 2>&1; then
      echo "PASS $scheme compiles"
    else
      echo "FAIL $scheme build:"
      grep -E "error:" "$BIN/build-$scheme.log" | grep -v CoreSimulator | head
      fail=1
    fi
  done
  echo ""
fi

# ── Phase 2: headless unit suites ───────────────────────────────────────────
echo "── Phase 2: unit suites ────────────────────────"
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
build_run model    "$ROOT/tests/model/main.swift" "$SRC/Model/Project.swift" "$SRC/Core/Detector.swift" \
  "$SRC/Model/AppSettings.swift"
build_run sampler  "$ROOT/tests/sampler/main.swift" "$SRC/Core/SystemSampler.swift" \
  "$SRC/Core/ResourceAdvisor.swift" "$SRC/Core/ClaudeRunner.swift" \
  "$SYS/metrics.c" "$SYS/spawn.c" -import-objc-header "$HDR"
build_run session  -enable-bare-slash-regex "$ROOT/tests/session/main.swift" \
  "$SRC/Model/Project.swift" "$SRC/Model/SessionState.swift" "$SRC/Model/MetricsSample.swift" \
  "$SRC/Model/SupervisionEvent.swift" \
  "$SRC/Core/Detector.swift" "$SRC/Core/ProcessTree.swift" "$SRC/Core/DevSession.swift" \
  "$SRC/Core/BuildRunner.swift" "$SRC/Core/ANSI.swift" "$SRC/Core/AppLog.swift" \
  "$SYS/metrics.c" "$SYS/spawn.c" -import-objc-header "$HDR"
build_run advisor "$ROOT/tests/advisor/main.swift" \
  "$SRC/Core/ResourceAdvisor.swift" "$SRC/Core/ClaudeRunner.swift"
build_run argparse "$ROOT/tests/argparse/main.swift" "$ROOT/dev-monitor/ArgParse.swift"

echo "────────────────────────────────────────────────"
[ "$fail" = 0 ] && echo "✅ ALL CHECKS PASSED" || echo "❌ SOME CHECKS FAILED"
exit $fail
