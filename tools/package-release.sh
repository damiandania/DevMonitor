#!/usr/bin/env bash
# Package a public (UNSIGNED / ad-hoc) release into dist/:
#   - "Dev Monitor-<ver>.dmg"   the app + an /Applications drop target
#   - "dev-monitor-<ver>.zip"   the universal CLI binary
#
# Usage: bash tools/package-release.sh
# Requires: xcodegen, Xcode (macOS 26 SDK). The artifacts are unsigned — users open the app the
# first time via right-click -> Open, or `xattr -dr com.apple.quarantine "/Applications/Dev Monitor.app"`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VER=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$VER" ] || { echo "could not read MARKETING_VERSION from project.yml" >&2; exit 1; }
echo "Packaging Dev Monitor $VER (unsigned)…"

xcodegen generate >/dev/null
xcodebuild -project DevMonitor.xcodeproj -scheme DevMonitor  -configuration Release -derivedDataPath build build >/dev/null
xcodebuild -project DevMonitor.xcodeproj -scheme dev-monitor -configuration Release -derivedDataPath build build >/dev/null

APP="build/Build/Products/Release/Dev Monitor.app"
CLI="build/Build/Products/Release/dev-monitor"
[ -d "$APP" ] && [ -x "$CLI" ] || { echo "Release build artifacts missing" >&2; exit 1; }

rm -rf dist && mkdir -p dist

# DMG: app + a symlink to /Applications so users can drag-install.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Dev Monitor" -srcfolder "$STAGE" -ov -format UDZO "dist/Dev Monitor-$VER.dmg" >/dev/null
rm -rf "$STAGE"

# CLI zip (universal binary).
ZIP="$(mktemp -d)"
cp "$CLI" "$ZIP/dev-monitor"
( cd "$ZIP" && zip -q "dev-monitor-$VER.zip" dev-monitor )
cp "$ZIP/dev-monitor-$VER.zip" "dist/"
rm -rf "$ZIP"

echo
echo "Artifacts (unsigned):"
ls -lh dist/
echo "arch (app):"; lipo -archs "$APP/Contents/MacOS/Dev Monitor" 2>/dev/null || true
echo "arch (cli):"; lipo -archs "$CLI" 2>/dev/null || true
echo
echo "Reminder: unsigned — first launch needs right-click -> Open, or:"
echo '  xattr -dr com.apple.quarantine "/Applications/Dev Monitor.app"'
