## 2026-10-19 — fix: legacy skill-dir migration can no longer delete a source file mid-race

- **`lib-symlinks.sh`** (issue #638): `symlink_migrate_legacy_skill_dir`
  drained the legacy per-file dir in place. If a concurrent `--heal` swapped
  `$dst` for the directory link between the `[ -L "$dst/x" ]` check and the
  `rm`, the `rm` resolved through the link and deleted the real tracked
  `$src/x`. The migrator now renames `$dst` to a private dot-sibling,
  `.<name>.migrating.<pid>`, and drains only that path, which no rival can
  swap. The rename is atomic, so exactly one run owns the dir. A run whose
  rename fails because a rival took it returns success without acting and
  lets `check_link` judge the settled state. It also refuses a mount point,
  since `mv` would fall back to a non-atomic copy. A directory link moved by
  mistake, or content that appeared mid-flight, is put back untouched.
- **Dead-owner recovery**: each migration first reaps
  `.<name>.migrating.<pid>` leftovers whose pid is gone. The reaper renames
  the leftover to its own pid's name first, so two reapers never drain the
  same path. It removes only a dir that still holds nothing but our own links;
  anything else is left in place and reported.
- **`claude/hooks/SymlinkRepair.hook.ts`**: the SessionStart mirror had the
  same in-place `unlinkSync(join(dst, name))`. It now renames to the same
  private name before unlinking, so the shell reaper also recovers a hook
  that died mid-drain.
- **`claude/scripts/tests/heal-race.test.sh`**: a fake `rm` on PATH plays the
  rival on its first call. The old code loses `$src/f1`; the new code keeps
  every source file. Also adds a stale-dir fixture: a links-only leftover is
  reaped, while one holding a real file, or one whose owner is alive, is kept.
