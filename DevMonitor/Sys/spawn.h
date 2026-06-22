#ifndef DM_SPAWN_H
#define DM_SPAWN_H

#include <sys/types.h>

/// Spawn `/bin/zsh -lc <command>` in a NEW session (so the child is its own
/// session/pgid leader and the whole tree can be reaped with killpg). The command
/// runs with `cwd` as working directory and inherits the current environment.
/// NOTE: `-lc` is login but NON-interactive (it does NOT source `.zshrc`), so Node version-manager
/// shims (fnm/nvm) are on PATH only because ShellEnvironment resolves the user's login+interactive
/// PATH and exports it into this process before each launch. stdout and stderr are merged into
/// a single pipe whose read end is returned via `out_fd`.
///
/// stdout and stderr are merged into a single pipe whose read end is returned via `out_fd`.
/// If `in_fd` is non-NULL, a stdin pipe is also created and its WRITE end returned via `in_fd`
/// (so the parent can send input to the process). Pass NULL for no writable stdin.
///
/// Returns the child pid (> 0) on success, or -1 on failure.
pid_t dm_spawn_session(const char *command, const char *cwd, int *out_fd, int *in_fd);

#endif /* DM_SPAWN_H */
