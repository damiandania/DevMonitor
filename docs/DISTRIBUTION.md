# Distribution

How to ship Dev Monitor as a signed, notarized, auto-updating app with a Homebrew cask. The
scaffolding is in the repo; the steps below are what *you* complete with an Apple Developer account.
Everything here is opt-in — without credentials the build and `package-release.sh` still produce the
unsigned artifacts they always did.

## 1. Code signing + notarization

The Release config already enables the **hardened runtime** and uses
`DevMonitor/Resources/DevMonitor.entitlements` (see `project.yml`). To sign + notarize locally:

```bash
# One-time: store an app-specific password for the notary service.
xcrun notarytool store-credentials devmonitor-notary \
  --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"

# Then package signed + notarized + stapled:
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
AC_NOTARY_PROFILE="devmonitor-notary" \
  bash tools/package-release.sh
```

`tools/package-release.sh` signs the CLI and the app with the hardened runtime, submits the `.dmg`
to the notary service, and staples the ticket. Verify with `spctl -a -vvv "dist/.../Dev Monitor.app"`
and `codesign --verify --deep --strict`.

## 2. Auto-update (Sparkle)

`DevMonitor/App/Updater.swift` is ready but inert (`#if canImport(Sparkle)`). To activate:

1. Add the package in `project.yml`:
   ```yaml
   packages:
     Sparkle:
       url: https://github.com/sparkle-project/Sparkle
       from: "2.6.0"
   targets:
     DevMonitor:
       dependencies:
         - package: Sparkle
   ```
2. Add to `DevMonitor/Resources/Info.plist`:
   - `SUFeedURL` → the hosted `appcast.xml` URL (e.g. GitHub Pages / Releases).
   - `SUPublicEDKey` → the EdDSA public key from Sparkle's `generate_keys`.
3. In `DevMonitorApp`, hold an `UpdaterController` and add `UpdaterCommands(updater:)` to
   `.commands { }` — the "Check for Updates…" menu item then appears.
4. Sign updates with `sign_update` and publish `appcast.xml` alongside each release `.dmg`.

`xcodegen generate` + a Release build then links Sparkle (the unit suites are unaffected — they
don't build the app).

## 3. Homebrew cask

Template: `distribution/dev-monitor.rb`. Publish it in a tap repo as `Casks/dev-monitor.rb`, fill in
`version`, the two `sha256` values (`shasum -a 256 dist/*.dmg dist/*.zip`) and the release URLs. Then:

```bash
brew tap <you>/tap
brew install --cask dev-monitor   # installs the app + the dev-monitor CLI
```

The cask needs a **notarized** `.dmg` — Gatekeeper blocks an unsigned cask install.

## 4. CI release pipeline

`.github/workflows/release.yml` runs on a `v*` tag: it builds, signs + notarizes (only if the
secrets below exist), and publishes the artifacts to a GitHub Release. Set these repo secrets:

| Secret | What |
|---|---|
| `DEVELOPER_ID` | `Developer ID Application: Your Name (TEAMID)` |
| `DEVELOPER_ID_P12` | base64 of the exported signing cert (`.p12`) |
| `DEVELOPER_ID_P12_PASSWORD` | password for that `.p12` |
| `AC_APPLE_ID`, `AC_TEAM_ID`, `AC_PASSWORD` | notary submission (app-specific password) |

Tag a release with `git tag v0.1.1 && git push --tags`. `.github/workflows/ci.yml` also runs a
non-blocking full app build on PRs (Phase 1); the unit suites (Phase 2) remain the gating check.
