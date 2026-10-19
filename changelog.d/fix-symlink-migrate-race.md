## 2026-10-19 — fix: legacy skill-dir migration never deletes, so a race can't lose a source file

- **`lib-symlinks.sh`** (issue #638): `symlink_migrate_legacy_skill_dir`
  drained the legacy per-file dir in place. If a concurrent `--heal` swapped
  `$dst` for the directory link between the `[ -L "$dst/x" ]` check and the
  `rm`, the `rm` resolved through the link and deleted the real tracked
  `$src/x`. Three review rounds of patching each found another
  delete-by-path race. Neither shell nor Node can unlink "only if still a
  symlink", so the migration no longer deletes at all.
- **Move aside, then link**: the whole legacy dir is renamed (`rename(2)`
  through `perl`, atomic) into
  `~/.claude/.migrated-skill-dirs/<name>.<UTC timestamp>.<pid>`, and
  `check_link` then creates the directory link. A rename that would cross
  filesystems is refused, never copied. A run whose rename fails because a
  rival already moved the dir returns success and lets `check_link` judge.
  A rival's directory link grabbed by mistake stays in the archive rather
  than being renamed back over whatever appeared at `$dst`. A dir that turns
  out not to be legacy goes back only onto a still-absent `$dst`; otherwise
  it stays in the archive and is reported.
- **The archive is kept on purpose.** It holds only old symlinks and is safe
  to delete by hand (`CLAUDE-GUIDE.md`). A read-only legacy dir cannot be
  moved to another parent, so it is reported and left in place, still
  reachable.
- **`claude/hooks/SymlinkRepair.hook.ts`**: the SessionStart mirror had the
  same in-place `unlinkSync`. It now does the same rename-aside, with every
  check after the rename inside one report/restore handler, and lets
  `ensureLink` judge a destination a rival already relinked.
- **Tests** (`heal-race.test.sh`, `symlink-enumerate.test.sh`): fake `rm`
  and `perl` on PATH play the races deterministically. A rival finishing
  mid-migration costs no source file; the old loop lost `$src/f1`. A regular
  file that appears at `$dst` after the rename survives, and so does a file
  swapped into the moved dir. Further cases cover the archive name and links,
  the hook's archive, and the read-only case.
