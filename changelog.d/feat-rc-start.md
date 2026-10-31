## 2026-10-30 — feat(bin): track rc-start, the Remote Control launcher

- **`rc-start`** is now in dotfiles and linked into `~/.local/bin` by
  `setup.sh`, beside the other top-level helpers. Before, it existed only on
  one machine. It starts `claude remote-control` in a detached tmux session
  named `rc`; `--hold` blocks, so the `wsl.exe` of a Windows boot task keeps
  WSL running.
- It puts `~/.bun/bin` on PATH. Remote Control runs claude directly, not
  through a login shell, so `~/.bash_profile`'s bun line never reached those
  sessions, and anything they ran that called `bunx` failed.
- The session starts in the folder that holds the dotfiles checkout, found
  through the script's own symlink, rather than a hardcoded `~/dev`.
  `RC_START_DIR` overrides it.
- Two fixes to the copied script, from review:
  - The session no longer keeps a shell behind claude (`exec bash`). That
    shell made a dead Remote Control count as running, so no later
    `rc-start` restarted it. The session now ends when claude does, and the
    exit status goes to `~/.local/state/rc-start.log`.
  - The running check matches the session name exactly. Plain `rc` also
    matched a session such as `rc-other`, and the start was skipped.
  - "Running" now means a live pane in the `rc` session. Where
    `remain-on-exit` is on, a dead pane left behind is replaced rather than
    reported as running.
  - A working directory that does not exist is refused. tmux would
    otherwise start in `$HOME` instead.
- New suite `claude/scripts/tests/rc-start.test.sh` runs a real tmux on a
  private socket directory with a stub `claude`. It runs in the `checkers`
  shard, and fails there rather than skipping if the runner lacks tmux.
  Every tmux call it makes, cleanup included, names its own socket, and it
  runs nothing unless every temp directory was created, so it can never
  reach the caller's tmux server.
