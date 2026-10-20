## 2026-10-19 — fix: ccw shares each session's todos and tasks with the second account

- **`claude/scripts/link-claude-profile.sh`** (#591): the profile now links
  `todos/` and `tasks/` back to `~/.claude`, using the same mechanism as
  `projects/` and `file-history/`, so a session resumed on the other account
  still sees its todos and tasks. Both directories are created in the default
  profile when missing, and `--check` reports one that was removed as drift
  rather than accepting a dangling link. `session-env/` stays per account
  because it can carry account-bound environment.
- The guarantees from #632 are unchanged: an ancestor of `~/.claude` is
  refused, a symlinked `.claude.json` is drift, and a populated private
  directory is never overwritten.
- Docs: `CLAUDE-GUIDE.md` (A second account) and `claude/scripts/README.md`
  now name the shared sidecars and the per-account `session-env/`.
- Tests: seven new assertions in `claude/scripts/tests/claude-profile.test.sh`.
