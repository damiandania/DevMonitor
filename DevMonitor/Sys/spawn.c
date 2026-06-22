#include "spawn.h"

#include <spawn.h>
#include <unistd.h>
#include <stdlib.h>
#include <crt_externs.h>

#define dm_environ (*_NSGetEnviron())

pid_t dm_spawn_session(const char *command, const char *cwd, int *out_fd, int *in_fd) {
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return -1;
    }
    int stdinfd[2] = { -1, -1 };
    int want_stdin = (in_fd != NULL);
    if (want_stdin && pipe(stdinfd) != 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    // Child: close the read end, route stdout+stderr to the write end, then close it.
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);
    if (want_stdin) {
        // Child reads stdin from the pipe; close the parent's write end in the child.
        posix_spawn_file_actions_addclose(&actions, stdinfd[1]);
        posix_spawn_file_actions_adddup2(&actions, stdinfd[0], STDIN_FILENO);
        posix_spawn_file_actions_addclose(&actions, stdinfd[0]);
    }
    if (cwd != NULL) {
        // Use the macOS-canonical `_np` name: available on every macOS SDK, unlike the bare
        // POSIX-2024 `posix_spawn_file_actions_addchdir` which only the newest SDK declares.
        posix_spawn_file_actions_addchdir_np(&actions, cwd);
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // SETSID: new session => child pid == its pgid == its sid, so killpg(pid) reaps the tree.
    // CLOEXEC_DEFAULT: treat every inherited fd as close-on-exec EXCEPT the ones wired up by the
    // file actions above (stdout/stderr/stdin). Without this the long-lived dev server inherits
    // unrelated fds — notably the IPC client socket — and keeps a `dev-monitor` CLI blocked on
    // read() until the server dies (the connection never sees EOF).
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);

    // Login, NON-interactive (`-lc`): we deliberately skip the interactive `.zshrc` because on some
    // setups (p10k / fnm hooks) it reparents the real shell out of our process group and prints
    // session-restore noise into the dev-server log. The catch: Node version managers (fnm/nvm) are
    // usually initialized in `.zshrc`, so `-lc` ALONE would not put node/npm on PATH. We solve that
    // app-side: ShellEnvironment resolves the user's login+interactive PATH (off the spawn path) and
    // exports it into our process, so the environment inherited here already carries the Node shims.
    char *argv[] = { (char *)"/bin/zsh", (char *)"-lc", (char *)command, NULL };

    pid_t pid = 0;
    int rc = posix_spawn(&pid, "/bin/zsh", &actions, &attr, argv, dm_environ);

    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(pipefd[1]);                       // parent never writes to stdout pipe
    if (want_stdin) {
        close(stdinfd[0]);                  // parent never reads from stdin pipe
    }

    if (rc != 0) {
        close(pipefd[0]);
        if (want_stdin) {
            close(stdinfd[1]);
        }
        return -1;
    }

    *out_fd = pipefd[0];
    if (want_stdin) {
        *in_fd = stdinfd[1];
    }
    return pid;
}
