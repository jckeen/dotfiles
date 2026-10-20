## 2026-10-19 — fix: legacy skill-dir migration never deletes, so a race can't lose a source file

- **`lib-symlinks.sh`** (issue #638): `symlink_migrate_legacy_skill_dir`
  drained the legacy per-file dir in place. If a concurrent `--heal` swapped
  `$dst` for the directory link between the `[ -L "$dst/x" ]` check and the
  `rm`, the `rm` resolved through the link and deleted the real tracked
  `$src/x`. Review rounds that patched the drain each found another
  delete-by-path race, because neither shell nor Node can unlink "only if
  still a symlink". So the migration no longer deletes anything.
- **Move aside, then link**: the whole legacy dir is renamed (`rename(2)`
  through `perl`, atomic) into
  `~/.claude/.migrated-skill-dirs/<name>.<UTC timestamp>.<pid>`, and
  `check_link` then creates the directory link. A rename that would cross
  filesystems is refused, never copied. A run whose rename fails because a
  rival already moved the dir returns success and lets `check_link` judge.
- **Nothing is ever renamed back**, since `rename(2)` cannot refuse to
  overwrite. A rival's directory link grabbed by mistake stays in the
  archive. Content that changed mid-migration goes to the archive's `kept/`
  and is reported. `check-claude.sh` then warns `KEPT` on every run until
  the user removes it.
- **Archive hygiene**: its top-level entries hold only old symlinks and are
  safe to delete by hand; anything under `kept/` is user content to review
  (`CLAUDE-GUIDE.md`). `check-claude.sh` prunes the archive from its orphan,
  broken-link and backup scans, so an archived dangling link is never
  `ORPHAN` and `--fix` never touches it. `check-deployed-orphans.sh` lists it
  as known state. A read-only legacy dir cannot move to another parent, so
  it is reported and left in place, still reachable.
- **`claude/hooks/SymlinkRepair.hook.ts`**: the SessionStart mirror had the
  same in-place `unlinkSync`. It now does the same rename-aside, with the same
  `kept/` handling and every post-rename check inside its handler, and lets
  `ensureLink` judge a destination a rival already relinked.
- **Tests** (`heal-race`, `symlink-enumerate`, `deployed-orphans`): fake `rm`
  and `perl` on PATH play the races deterministically.
  - A rival finishing mid-migration costs no source file; the old loop lost
    `$src/f1`.
  - A regular file that appears at `$dst` survives, and so does one swapped
    into the moved dir, which lands under `kept/` and is warned about.
  - Further cases cover the archive name and links, the hook's archive, the
    read-only case, and the archived-dangling-link scans.
