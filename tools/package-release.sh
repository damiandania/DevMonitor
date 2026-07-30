#!/usr/bin/env bash
# Package a public release into dist/:
#   - "Owl Monitor-<ver>.dmg"   the app + an /Applications drop target
#   - "owl-monitor-<ver>.zip"   the universal CLI binary
#
# Usage: bash tools/package-release.sh
# Requires: xcodegen, Xcode (macOS 26 SDK).
#
# SIGNING + NOTARIZATION are opt-in via the environment (so a plain run still produces the unsigned
# artifacts it always did). Set:
#   DEVELOPER_ID   "Developer ID Application: Your Name (TEAMID)"   → codesign the app + CLI (hardened
#                                                                     runtime); without it, ad-hoc.
#   AC_NOTARY_PROFILE   a `notarytool store-credentials` profile name → notarize + staple the .dmg.
#       (or AC_APPLE_ID + AC_TEAM_ID + AC_PASSWORD for an app-specific-password submission)
# Without DEVELOPER_ID the app stays unsigned and first launch needs right-click -> Open, or
#   `xattr -dr com.apple.quarantine "/Applications/Owl Monitor.app"`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VER=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$VER" ] || { echo "could not read MARKETING_VERSION from project.yml" >&2; exit 1; }
SIGNED=0; [ -n "${DEVELOPER_ID:-}" ] && SIGNED=1
echo "Packaging Owl Monitor $VER ($([ "$SIGNED" = 1 ] && echo "signed: $DEVELOPER_ID" || echo unsigned))…"

xcodegen generate >/dev/null
xcodebuild -project OwlMonitor.xcodeproj -scheme OwlMonitor  -configuration Release -derivedDataPath build build >/dev/null
xcodebuild -project OwlMonitor.xcodeproj -scheme owl-monitor -configuration Release -derivedDataPath build build >/dev/null

APP="build/Build/Products/Release/Owl Monitor.app"
CLI="build/Build/Products/Release/owl-monitor"
[ -d "$APP" ] && [ -x "$CLI" ] || { echo "Release build artifacts missing" >&2; exit 1; }

# Developer ID signing (hardened runtime) — only when DEVELOPER_ID is set.
if [ "$SIGNED" = 1 ]; then
  ENT="OwlMonitor/Resources/OwlMonitor.entitlements"
  echo "Signing CLI + app with hardened runtime…"
  codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$CLI"
  codesign --force --timestamp --options runtime --entitlements "$ENT" \
           --sign "$DEVELOPER_ID" --deep "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

rm -rf dist && mkdir -p dist

# DMG: app + a symlink to /Applications so users can drag-install.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Owl Monitor" -srcfolder "$STAGE" -ov -format UDZO "dist/Owl Monitor-$VER.dmg" >/dev/null
rm -rf "$STAGE"

# Notarize + staple the DMG — only when signed AND notary credentials are present.
DMG="dist/Owl Monitor-$VER.dmg"
if [ "$SIGNED" = 1 ] && { [ -n "${AC_NOTARY_PROFILE:-}" ] || [ -n "${AC_APPLE_ID:-}" ]; }; then
  echo "Submitting to the notary service (this can take a few minutes)…"
  if [ -n "${AC_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$AC_NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$DMG" --apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" \
          --password "$AC_PASSWORD" --wait
  fi
  xcrun stapler staple "$DMG"
  echo "Notarized + stapled: $DMG"
fi

# CLI zip (universal binary).
ZIP="$(mktemp -d)"
cp "$CLI" "$ZIP/owl-monitor"
( cd "$ZIP" && zip -q "owl-monitor-$VER.zip" owl-monitor )
cp "$ZIP/owl-monitor-$VER.zip" "dist/"
rm -rf "$ZIP"

echo
echo "Artifacts ($([ "$SIGNED" = 1 ] && echo signed || echo unsigned)):"
ls -lh dist/
echo "arch (app):"; lipo -archs "$APP/Contents/MacOS/Owl Monitor" 2>/dev/null || true
echo "arch (cli):"; lipo -archs "$CLI" 2>/dev/null || true
if [ "$SIGNED" != 1 ]; then
  echo
  echo "Reminder: unsigned — first launch needs right-click -> Open, or:"
  echo '  xattr -dr com.apple.quarantine "/Applications/Owl Monitor.app"'
  echo "Set DEVELOPER_ID (+ AC_NOTARY_PROFILE) to sign + notarize. See docs/DISTRIBUTION.md."
fi
