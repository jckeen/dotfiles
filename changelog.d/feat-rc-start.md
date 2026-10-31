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
- Fixes to the copied script, from review:
  - The session no longer keeps a shell behind claude (`exec bash`). That
    shell made a dead Remote Control count as running, so no later
    `rc-start` restarted it. The session now ends when claude does, and the
    exit status goes to `~/.local/state/rc-start.log`.
  - "Running" means a live pane in the session named exactly `rc`. Plain
    `rc` also matched a session such as `rc-other`, and the start was
    skipped.
  - Only where a config turns `remain-on-exit` on can the session outlive
    claude, with a dead pane. `rc-start` then refuses and prints
    `tmux kill-session -t =rc`, the command that clears it. It never
    restarts in place or kills a session, so it can't stop a running claude.
    One tmux query decides whether the session is absent, live or dead, so a
    session that a concurrent call creates mid-check is reported as running,
    never mistaken for a dead one.
  - `--hold` holds whatever happened, a refused start or a `set -e`
    failure included (an EXIT trap), since its job is to keep the boot
    task's WSL running. The exit log is best effort: a state directory that
    can't be created costs the log, with a warning, not Remote Control.
  - The working directory is entered with `cd`, which refuses one that is
    missing or can't be entered (tmux would silently use `$HOME`), and read
    back from `$PWD`, which keeps a trailing newline in the name. tmux is
    never handed the directory: it reads `-c` as a format and trims a
    trailing `\;`, so the session starts in `rc-start`'s own working
    directory. An inherited `CDPATH` is unset in both the script and its
    test.
  - The pane's command goes to tmux as separate arguments (`sh -c …`),
    which tmux runs directly, so tmux's `default-shell` (fish, say) never
    interprets it.
- New suite `claude/scripts/tests/rc-start.test.sh` runs a real tmux on a
  private socket directory with a stub `claude`. It runs in the `checkers`
  shard, and fails there rather than skipping if the runner lacks tmux.
  Every tmux call it makes, cleanup included, names its own socket, and it
  runs nothing unless every temp directory was created, so it can never
  reach the caller's tmux server.
