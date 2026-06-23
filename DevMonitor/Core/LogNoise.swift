import Foundation

/// Shell session-restore chatter that a login `zsh -lc` emits around the real command output. It
/// would otherwise clobber a project log's true first/last lines, so both the dev-server and build
/// readers drop it. (DevSession filters the ANSI-stripped line; BuildRunner the raw line.)
enum LogNoise {
    static func isShellNoise(_ line: String) -> Bool {
        line.hasPrefix("Restored session:") || line.contains("Saving session...completed")
    }
}
