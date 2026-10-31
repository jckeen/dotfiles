## 2026-10-30 — feat(bin): track rc-start, the Remote Control launcher

- **`rc-start`** is now in dotfiles and linked into `~/.local/bin` by
  `setup.sh`, beside the other top-level helpers. Before, it existed only on
  one machine. It starts `claude remote-control` in a detached tmux session
  named `rc`; `--hold` blocks, so the `wsl.exe` of a Windows boot task keeps
  WSL running.
- It puts `~/.bun/bin` on PATH. Remote Control runs claude directly, not
  through a login shell, so `~/.bash_profile`'s bun line never reached those
  sessions, and anything they ran that called `bunx` failed.
- The session starts in `~/dev`, as before, or in `RC_START_DIR` when that
  is set.
- Two fixes to the copied script, from review:
  - The session no longer keeps a shell behind claude (`exec bash`). That
    shell made a dead Remote Control count as running, so no later
    `rc-start` restarted it. The session now ends when claude does, and the
    exit status goes to `~/.local/state/rc-start.log`.
  - The running check matches the session name exactly. Plain `rc` also
    matched a session such as `rc-other`, and the start was skipped.
  - The session's window gets `remain-on-exit off` in the same tmux
    command that creates it. A config that turns the option on can't leave
    a dead pane counting as running, and nothing ever has to kill a
    session. Two calls at once are safe: tmux refuses the second session
    name.
  - The working directory is checked by entering it, so one that is
    missing or can't be entered is refused. tmux would otherwise start in
    `$HOME`. The directory is read back from `$PWD`, not `$(pwd)`, which
    would drop a trailing newline from its name. Its `#` characters are
    doubled, because tmux expands `-c` as a format, and a `#()` there would
    run a command. An inherited `CDPATH` is unset in both the script and
    its test.
  - The pane's command is passed to tmux as separate arguments
    (`sh -c …`), which tmux runs directly, so tmux's `default-shell` (fish,
    say) never interprets it.
- New suite `claude/scripts/tests/rc-start.test.sh` runs a real tmux on a
  private socket directory with a stub `claude`. It runs in the `checkers`
  shard, and fails there rather than skipping if the runner lacks tmux.
  Every tmux call it makes, cleanup included, names its own socket, and it
  runs nothing unless every temp directory was created, so it can never
  reach the caller's tmux server.
