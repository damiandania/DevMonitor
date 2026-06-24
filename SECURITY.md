# Security Policy

## Supported versions

Dev Monitor is pre-1.0; security fixes land on the latest `master` and are noted in
[`CHANGELOG.md`](CHANGELOG.md).

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for an unfixed
vulnerability.

- Preferred: open a [private security advisory](https://github.com/damiandania/DevMonitor/security/advisories/new)
  on this repository.
- Otherwise, contact the maintainer via the GitHub profile [@damiandania](https://github.com/damiandania).

Please include the macOS version, the Dev Monitor version, and steps to reproduce. We aim to
acknowledge a report within a few days.

## Security posture

A few things to know about how Dev Monitor runs, since it supervises other processes:

- **Not sandboxed.** The app launches arbitrary dev servers, reads system process metrics, and spawns
  `node`/`npm`/`claude`, so it runs outside the App Sandbox. Release builds use the **hardened
  runtime**.
- **Local IPC hub.** The CLI talks to the app over a Unix-domain socket. The socket is created
  `0600` (owner-only) and the hub rejects connections whose peer UID differs from the app's
  (`LOCAL_PEERCRED`), so another local user can't drive `run`/`stop`/`build`/`remove`.
- **Claude integration is read-only.** The Diagnose and resource-advisor features run the logged-in
  `claude` CLI in plan mode with write tools disallowed; foreign processes are only closed after
  explicit confirmation, never automatically (except orphaned dev servers under memory pressure,
  which is off-switchable).
- **No telemetry.** Dev Monitor does not phone home; persisted data (projects, settings, logs, event
  history) stays under `~/Library/Application Support/DevMonitor`.
