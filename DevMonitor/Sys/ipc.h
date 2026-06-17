#ifndef DM_IPC_H
#define DM_IPC_H

/// Create a Unix-domain stream socket bound + listening at `path` (unlinks first).
/// Returns the listening fd, or -1 on error.
int dm_ipc_listen(const char *path);

/// Accept a client connection on `listen_fd`. Returns the client fd, or -1.
int dm_ipc_accept(int listen_fd);

/// Connect to a Unix-domain socket at `path`. Returns the connected fd, or -1.
int dm_ipc_connect(const char *path);

#endif /* DM_IPC_H */
