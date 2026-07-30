# Owl Monitor workflow

After every code or resource change to this project:

1. Compile the Debug build to validate the change.
2. Run `bash tools/install-local.sh` to build Release, sign it, and install it in `/Applications/Owl Monitor.app`.
3. Quit Owl Monitor, then explicitly open `/Applications/Owl Monitor.app` (never resolve it only by name).
4. Verify that the installed app has reopened before reporting completion.

Do not consider a requested change complete until these steps succeed, unless the user explicitly asks not to install or restart.
