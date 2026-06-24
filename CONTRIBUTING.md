# Contributing to Dev Monitor

Thanks for your interest in improving Dev Monitor. This guide covers how to build, test, and submit
changes.

## Prerequisites

- **macOS 26+** with **Xcode 26** (the app uses the macOS 26 SDK and SwiftUI Liquid Glass).
- [**XcodeGen**](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

## Build & run

```bash
cd DevMonitor            # the Xcode project lives one level down
xcodegen generate        # regenerate DevMonitor.xcodeproj from project.yml
xcodebuild -project DevMonitor.xcodeproj -scheme DevMonitor -configuration Debug \
  -derivedDataPath build build
open "build/Build/Products/Debug/Dev Monitor.app"
```

> Dev servers on a machine running Dev Monitor are meant to go **through** the app
> (`dev-monitor up <path>`), not raw `npm run dev`. The repo ships a Claude Code hook that enforces
> this — see [`integrations/claude/`](integrations/claude/).

## Tests

All logic is covered by **headless suites** (pure `swiftc`, no Xcode host) plus a full-build phase:

```bash
bash tests/run-tests.sh          # Phase 1: build app + CLI · Phase 2: unit suites
bash tests/run-tests.sh --unit   # units only — exactly what CI runs
```

A change should keep `run-tests.sh` green. When adding pure logic, add a test to the matching suite
under `tests/` and, if the new code references another source file, add that file to the suite's
`build_run` line in `tests/run-tests.sh`. UI-only changes are validated by the full build (Phase 1).

## Architecture

Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) first — it explains the layering (C interop →
`Core` → `App` → `Views`), the concurrency model, and why the key decisions were made.
[`docs/HEAP-AND-BUILD.md`](docs/HEAP-AND-BUILD.md) covers heap autoscaling and the build runner.

## Code style

- Match the surrounding code: naming, comment density, and idiom.
- Comments explain **why**, not what. The codebase favours one well-explained line over a clever one.
- Swift 6 with **strict concurrency**; keep UI state on `@MainActor` and push long-running work off it
  via `AsyncStream`/`Task`, as the existing `Core` types do.
- Keep `Core` framework-free where it's unit-tested headless (no SwiftUI/AppKit imports there).

## Submitting changes

1. Branch from `master`.
2. Make focused commits. Messages follow a conventional prefix — `feat:`, `fix:`, `docs:`,
   `build:`, `refactor:`, `test:` — with a scope where useful (e.g. `fix(astro): …`).
3. Update [`CHANGELOG.md`](CHANGELOG.md) under **Unreleased** for user-visible changes.
4. Open a pull request. CI (the unit suites) must pass; describe how you tested the change.
