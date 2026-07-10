#!/usr/bin/env bash
# Build Dev Monitor + the CLI (Release), sign the app with the stable LOCAL certificate, and install:
#   /Applications/Dev Monitor.app        (GUI app)
#   ~/.local/bin/dev-monitor             (CLI)
#
# The stable signature is the whole point (see tools/ensure-signing-cert.sh): grant the app's
# permissions once and every future install keeps them — no more Downloads/Music/Automation re-prompts
# on each build. project.yml itself stays ad-hoc (so CI and other contributors are untouched); the
# stable identity is applied here, at install time.
#
# First run only: macOS pops ONE keychain dialog the first time codesign uses the private key. Click
# "Always Allow" and every later build signs silently.
#
# Does NOT run `xcodegen generate` — it builds the project as it stands so it never clobbers a
# hand-edited project.pbxproj. Run `xcodegen generate` yourself first if you changed project.yml.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="$(bash tools/ensure-signing-cert.sh)"
ENT="DevMonitor/Resources/DevMonitor.entitlements"

echo "Building Release (app + CLI)…"
xcodebuild -project DevMonitor.xcodeproj -scheme DevMonitor  -configuration Release -derivedDataPath build build >/dev/null
xcodebuild -project DevMonitor.xcodeproj -scheme dev-monitor -configuration Release -derivedDataPath build build >/dev/null

APP="build/Build/Products/Release/Dev Monitor.app"
CLI="build/Build/Products/Release/dev-monitor"
[ -d "$APP" ] && [ -x "$CLI" ] || { echo "Release build artifacts missing" >&2; exit 1; }

echo "Signing with \"$IDENTITY\" (hardened runtime)…"
codesign --force --options runtime --sign "$IDENTITY" "$CLI"
codesign --force --options runtime --entitlements "$ENT" --sign "$IDENTITY" --deep "$APP"
codesign --verify --deep --strict "$APP"

echo "Installing…"
rm -rf "/Applications/Dev Monitor.app"
ditto "$APP" "/Applications/Dev Monitor.app"
mkdir -p "$HOME/.local/bin"
ditto "$CLI" "$HOME/.local/bin/dev-monitor"

echo
echo "Installed /Applications/Dev Monitor.app — signed with \"$IDENTITY\":"
codesign -dvv "/Applications/Dev Monitor.app" 2>&1 | grep -E "^Authority=|^Identifier=" || true
echo
echo "Grant the app's permissions once on first launch — every future build signed with this cert keeps them."
