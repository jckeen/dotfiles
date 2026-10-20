## 2026-10-20 — fix: skill-dir migration never clobbers a foreign link or follows a symlinked archive

- **`lib-symlinks.sh`** and **`claude/hooks/SymlinkRepair.hook.ts`**
  (issue #697, follow-up to #682): only an absent destination or exactly the bundle
  link (`readlink` equals the source, as `check_link` compares) counts as a
  rival's finished migration. Before, the device check treated any change at
  the destination as success. A foreign link that replaced it there (skills
  on another filesystem) then reached `link_file`, which replaced the user's
  link. Now it is left in place and the migration fails, at the first check,
  the device check and a failed rename alike.
- **The archive root and `kept/` must be real directories.** `mkdir -p`
  accepts a symlink to a directory and the rename followed it, for example
  back into `skills/`, where the archived copy loaded as a duplicate skill.
  A symlinked archive root now refuses the migration and leaves the legacy
  dir in place. A symlinked `kept/` leaves changed content in the archive,
  where `check-claude.sh` still reports it.
- **Tests** (`heal-race`, `symlink-enumerate`): a fake `stat` swaps in a
  foreign link and reports another device; a symlinked archive root and a
  symlinked `kept/` are covered in the shell and, through a Bun `--preload`
  shim, in the hook. Each new case fails on the previous code.
