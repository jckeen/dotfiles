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
  `~/.claude/.migrated-skill-dirs/NAME.UTC-TIMESTAMP.PID`, and
  `check_link` then creates the directory link. A rename that would cross
  filesystems is refused, never copied. A run whose rename fails because a
  rival already moved the dir returns success and lets `check_link` judge.
- **Nothing is ever renamed back**, since `rename(2)` cannot refuse to
  overwrite. A rival's directory link grabbed by mistake stays in the
  archive. Content that changed mid-migration goes to the archive's `kept/`
  and is reported. `check-claude.sh` then warns `KEPT` on every run until
  the user removes it.
- **Archive hygiene**: `check-claude.sh` flags every archived entry that is
  not only old links as `KEPT`, wherever it landed. An archive root, `kept/`
  or archived dir the check cannot read and traverse is `KEPT` too: what it
  can't see inside isn't safe to delete. An entry is safe to delete
  by hand only if it is not flagged (`CLAUDE-GUIDE.md`). The orphan,
  broken-link and backup scans skip the archive by a quoted `case` prefix
  match, not `find -path`, which read glob characters in `$HOME` as a
  pattern. An archived dangling link is therefore never `ORPHAN`, and `--fix`
  never touches the archive. `check-deployed-orphans.sh` lists it
  as known state. A read-only legacy dir cannot move to another parent, so
  it is reported and left in place, still reachable. A dir the migrator
  cannot read or traverse is never judged legacy, since its content cannot
  be seen.
- **Callers see every outcome**: the migration returns `2` when it archived
  changed content, and `0` when a rival already moved or relinked `$dst`.
  `setup.sh --repair` counts only a `2` as broken, even after it relinks the
  bundle; a rival that finished the repair is no error. Everything under
  `kept/` is always `KEPT`. Top-level archive links count as old only when
  they point into that skill's own source. A link the rename grabs counts as
  a rival's repair only if it is exactly the bundle link (`readlink` equals
  the source, as `check_link` compares). Any other link is someone's own
  config, so it goes to `kept/` and is reported. When content is archived,
  setup's install path still links the skill and fails only after the whole
  tree is linked. When the hook's rename fails because a rival already
  installed exactly the bundle link, that counts as done (#694).
  A `$dst` that a rival moves away during the filesystem check is that
  rival's success, not a cross-filesystem error. This holds in the shell and
  the hook.
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
    read-only and unreadable cases, the `KEPT` audit, and the scans run
    with glob characters in `$HOME`.
