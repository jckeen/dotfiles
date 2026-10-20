## 2026-10-20 — fix: the handoff reminder fires on stock macOS

- **`claude/hooks/HandoffReminder.hook.sh`** (issue #700): the hook found the
  latest handoff with GNU `find -maxdepth 1`, which stock macOS `find` lacks.
  It hid `find` errors, so on macOS every session silently missed its
  handoff reminder. It now walks the one handoff directory with a glob,
  keeps notes from the last 7 days (a per-file `find -prune -mtime`, which
  is POSIX) and names the newest by mtime. The directory, filename pattern
  and output are unchanged.
- **`claude/scripts/tests/handoff-reminder.test.sh`**, wired into CI: the
  hook runs over a fixture HOME with a `find` shim that rejects `-maxdepth`.
  The newest recent note for the project is named. Nothing is printed when
  the only note is too old, belongs to another project, or sits in a
  subdirectory.
- **Sweep** of `claude/hooks/*.sh` and `claude/statusline.sh` for GNU-only
  tools. No other hook in the settings template needs a change: `timeout`
  is guarded by `command -v`, `stat -c` falls back to `stat -f`, and the
  `grep -P` in `conventional-commit.sh` is #691's fix. The unregistered
  `OperatorQueueReminder.hook.sh` still uses `find -maxdepth 1` when it
  cleans its cache temporaries.
