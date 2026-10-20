## 2026-10-19 — fix: re-sourcing the managed tmux config no longer duplicates terminal entries

- **`.tmux.conf`**: `terminal-features` and `terminal-overrides` are set at a
  fixed array index (`set -s terminal-features[100] …`, the man page's
  `command-alias[100]` form) instead of appended with `set -as`. Since #643,
  `setup.sh` and `cct` re-source the config into a running server, and each
  append added another copy of the same entry (#673).
- **`claude/scripts/tests/setup-dry-run.test.sh`**: a real tmux on a private
  socket dir sources the repo's `.tmux.conf` three times, then asserts both
  array options hold their entry exactly once. Only the server the test
  started is killed, by its PID.
