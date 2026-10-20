## 2026-10-19 — fix: worktree retirement branch cleanup and retained-archive exemptions (#640)

- **`claude/scripts/worktree-lifecycle.py`**: `--delete-branch` now encodes the
  branch name with `os.fsencode`, inside the error handler, so a non-UTF-8
  name no longer raises after the ref has already been deleted.
- Branch configuration is now removed by unsetting every listed
  `branch.<name>.*` key and then checking that none remain. A section Git
  stored as `[Branch "x"]`, which `--remove-section branch.x` refuses, no
  longer survives.
- Retirement now merges the second scan's process exemptions and writes them
  to `recovery.json` before the "worktree changed during archival" check. An
  archive kept because of that check still names every identity a scan
  skipped.
- New tests in `claude/scripts/tests/worktree-lifecycle.test.py` cover all
  three.
