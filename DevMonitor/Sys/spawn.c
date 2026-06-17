#include "spawn.h"

#include <spawn.h>
#include <unistd.h>
#include <stdlib.h>
#include <crt_externs.h>

#define dm_environ (*_NSGetEnviron())

pid_t dm_spawn_session(const char *command, const char *cwd, int *out_fd) {
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    // Child: close the read end, route stdout+stderr to the write end, then close it.
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);
    if (cwd != NULL) {
        posix_spawn_file_actions_addchdir(&actions, cwd);
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // New session => child pid == its pgid == its sid, so killpg(pid) reaps the tree.
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    // Login (not interactive): loads the user's PATH/fnm via .zprofile without the
    // interactive .zshrc, which on some setups (p10k/fnm hooks) reparents the real
    // shell out of our process group and prints session-restore noise.
    char *argv[] = { (char *)"/bin/zsh", (char *)"-lc", (char *)command, NULL };

    pid_t pid = 0;
    int rc = posix_spawn(&pid, "/bin/zsh", &actions, &attr, argv, dm_environ);

    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(pipefd[1]); // parent never writes

    if (rc != 0) {
        close(pipefd[0]);
        return -1;
    }

    *out_fd = pipefd[0];
    return pid;
}
