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
