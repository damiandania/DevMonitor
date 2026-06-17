import Foundation

// dev-monitor CLI — the IPC hub client.
// Full implementation (run/status/list/logs/stop/restart/docs talking to dm.sock)
// lands in P6. This P0 stub keeps the target building and documents intent.

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "docs", "--help", "-h", nil:
    print("""
    dev-monitor — launch and supervise dev servers through the Dev Monitor app.

    USAGE:
      dev-monitor run                 Launch + supervise the project in the current directory
      dev-monitor status              List managed servers and their state
      dev-monitor logs <project>      Tail a server's log
      dev-monitor stop|restart <p>    Control a managed server

    NOTE: subcommands are wired to the app's IPC hub in phase P6. This is a stub.
    """)
default:
    print("dev-monitor: '\(arguments.joined(separator: " "))' — not yet implemented (lands in P6).")
}
