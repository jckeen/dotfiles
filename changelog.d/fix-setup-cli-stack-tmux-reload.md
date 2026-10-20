## 2026-10-19 — fix: setup.sh installs the CLI stack from one list, and a running tmux server picks up the managed config

- **`lib-checks.sh`**: each `CLI_STACK_TOOLS` entry now carries everything
  both consumers need, as `NAME:DEBIAN_BINARY:APT_PACKAGE:BREW_PACKAGE`
  (empty fields default to the name; a `?`-marked apt package is
  installed on its own line because older archives lack it, as with eza).
  `cli_stack_entry` parses one entry; `check_cli_stack` uses it (#636).
- **`setup.sh`**: the #204 install and shim block loops over
  `CLI_STACK_TOOLS` instead of hardcoding rg/fd/bat/eza and the fd/bat
  shims, so a tool added to the list is installed, shimmed and checked alike
  (#636).
- **`setup.sh`** and **`cct`** (`.bash_aliases`): when `tmux list-sessions`
  finds a running server, `tmux source-file ~/.tmux.conf` loads the managed
  config into it. Before, a server started earlier kept its old config until
  every session closed. `list-sessions`, not `tmux info`, because `info`
  fails when every session is detached. `setup.sh` invokes tmux only when the
  server socket already exists, since any tmux client creates its socket
  directory and `$TMUX_TMPDIR` may sit under `$HOME`. `--dry-run` prints the
  reload instead of running it (#643).
- **`claude/scripts/tests/setup-dry-run.test.sh`**: runs setup against a
  PATH that hides every name in `CLI_STACK_TOOLS` and asserts each entry is
  apt-installed, then plants only the Debian binaries and asserts each is
  shimmed, not reinstalled. A fake tmux covers the dry-run preview, the live
  reload, no tmux call at all without a server socket, a stale socket, and
  `cct`'s reload. A real tmux on a private socket dir covers a server whose
  only session is detached. The suite now sets
  `TMUX_TMPDIR` and unsets `TMUX`, so no run can reach a developer's real
  tmux server.
