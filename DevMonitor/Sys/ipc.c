#include "ipc.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>

static int dm_set_path(struct sockaddr_un *addr, const char *path) {
    memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr->sun_path)) {
        return -1;
    }
    strncpy(addr->sun_path, path, sizeof(addr->sun_path) - 1);
    return 0;
}

int dm_ipc_listen(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_un addr;
    if (dm_set_path(&addr, path) != 0) {
        close(fd);
        return -1;
    }
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 16) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int dm_ipc_accept(int listen_fd) {
    return accept(listen_fd, NULL, NULL);
}

int dm_ipc_connect(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_un addr;
    if (dm_set_path(&addr, path) != 0) {
        close(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}
