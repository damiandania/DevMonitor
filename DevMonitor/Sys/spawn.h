#ifndef DM_SPAWN_H
#define DM_SPAWN_H

#include <sys/types.h>

/// Spawn `/bin/zsh -lic <command>` in a NEW session (so the child is its own
/// session/pgid leader and the whole tree can be reaped with killpg). The command
/// runs with `cwd` as working directory and inherits the current environment
/// (a login-interactive zsh resolves fnm/PATH). stdout and stderr are merged into
/// a single pipe whose read end is returned via `out_fd`.
///
/// Returns the child pid (> 0) on success, or -1 on failure.
pid_t dm_spawn_session(const char *command, const char *cwd, int *out_fd);

#endif /* DM_SPAWN_H */
