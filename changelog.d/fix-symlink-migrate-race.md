## 2026-10-19 — fix: legacy skill-dir migration can no longer delete a source file mid-race

- **`lib-symlinks.sh`** (issue #638): `symlink_migrate_legacy_skill_dir`
  drained the legacy per-file dir in place. If a concurrent `--heal` swapped
  `$dst` for the directory link between the `[ -L "$dst/x" ]` check and the
  `rm`, the `rm` resolved through the link and deleted the real tracked
  `$src/x`. The migrator now renames `$dst` to a private dot-sibling,
  `.<name>.migrating.<pid>`, and drains only that path, which no rival can
  swap. The rename is atomic, so exactly one run owns the dir. A run whose
  rename fails because a rival took it returns success without acting and
  lets `check_link` judge the settled state.
- **Renames are plain `rename(2)`** (through `perl`), never `mv`. `mv` onto a
  directory link a rival just recreated would move the private dir INTO the
  source bundle, and across filesystems it falls back to a non-atomic copy.
  A directory link moved by mistake goes back, or our copy of it is dropped.
- **Drain re-checks every entry** right before its `rm`. Content that a writer
  adds after the scan is never deleted; `rmdir` then fails and the rest is
  restored to `$dst`, or left at the private path if `$dst` was relinked.
- **Dead-owner recovery**: `symlink_reap_stale_migrations` runs on every
  `check-claude.sh --heal` skill record, because once `$dst` is relinked no
  migration revisits it. It reaps `.<name>.migrating.<pid>` leftovers whose
  pid is gone, renaming each to its own pid's name first so two reapers never
  drain the same path. It removes only a dir that still holds nothing but our
  own links; anything else is left in place and reported. `setup.sh` does not
  call it yet.
- **`claude/hooks/SymlinkRepair.hook.ts`**: the SessionStart mirror had the
  same in-place `unlinkSync(join(dst, name))`. It now renames to the same
  private name, re-checks each entry before unlinking it, and restores the
  dir if any unlink or the `rmdir` fails (late content, or a read-only dir). The shell reaper also recovers a hook that died
  mid-drain.
- **`claude/scripts/tests/heal-race.test.sh`**: a fake `rm` on PATH plays the
  rival on its first call. The old code loses `$src/f1`; the new code keeps
  every source file. A second fake `rm` adds a late file and relinks `$dst`
  mid-drain: the file survives and nothing lands inside the bundle. A stale-dir
  fixture runs `--heal` with `$dst` already linked: a links-only leftover is
  reaped, while one holding a real file, or one whose owner is alive, is kept.
