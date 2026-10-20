#!/usr/bin/env bash
# symlink-enumerate.test.sh — fixture tests for lib-symlinks.sh's
# symlink_enumerate. The scripts/ category: *.sh must be linked executable,
# *.json data files (gate schemas) must be linked plain, and docs must not be
# linked. Regression for the codex-review-gate.sh fail-open: the gate resolves
# its schema via plain dirname beside the script SYMLINK, so an unenumerated
# scripts/*.json is invisible to it at runtime. The skills/ category (issue
# #592): one directory link per bundle, legacy per-file layout migration, and
# SymlinkRepair.hook.ts producing the same shape.
set -uo pipefail

resolve_script_path() {
  local target="$1" dir
  while [[ -L "$target" ]]; do
    dir="$(cd -P "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    [[ "$target" != /* ]] && target="$dir/$target"
  done
  cd -P "$(dirname "$target")" && pwd
}
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
# shellcheck source=../../../lib-symlinks.sh
. "$SCRIPT_DIR/../../../lib-symlinks.sh"

pass=0
failed=0

check() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
  else
    echo "FAIL: $name" >&2
    failed=$((failed + 1))
  fi
}

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/claude/scripts"
: >"$FIX/claude/nolink.txt"
printf '#!/usr/bin/env bash\n' >"$FIX/claude/scripts/gate.sh"
printf '{}\n' >"$FIX/claude/scripts/gate-schema.json"
printf '#!/usr/bin/env python3\n' >"$FIX/claude/scripts/review-receipt.py"
printf '# docs\n' >"$FIX/claude/scripts/README.md"

out="$(symlink_enumerate "$FIX/claude" "$HOME/.claude")"

# gate.sh linked with the executable flag
awk -F'\t' '$3 == "scripts/gate.sh" && $4 == "executable" { found = 1 } END { exit !found }' <<<"$out"
check "scripts/*.sh enumerated executable" $((1 - $?))

# gate-schema.json linked, WITHOUT the executable flag
awk -F'\t' '$3 == "scripts/gate-schema.json" && $4 == "" { found = 1 } END { exit !found }' <<<"$out"
check "scripts/*.json enumerated plain (gate schema reachable at runtime)" $((1 - $?))

awk -F'\t' '$3 == "scripts/review-receipt.py" && $4 == "" { found = 1 } END { exit !found }' <<<"$out"
check "scripts/*.py enumerated plain (receipt helper reachable at runtime)" $((1 - $?))

# README.md under scripts/ must not be linked
! grep -q "scripts/README\.md" <<<"$out"
check "scripts/README.md not enumerated" $((1 - $?))

# ── Skills: one directory link per bundle (issue #592) ─────────────────────
# Supporting files (references/, scripts/, assets/, .claude-plugin/) must reach
# the destination, so each skill is ONE record for the whole directory, never a
# record per file.
SK="$FIX/claude/skills/demo"
mkdir -p "$SK/references" "$SK/scripts" "$SK/.claude-plugin"
printf -- '---\nname: demo\n---\n' >"$SK/SKILL.md"
printf 'detail\n' >"$SK/references/x.md"
printf '#!/usr/bin/env bash\n' >"$SK/scripts/y.sh"
printf '{}\n' >"$SK/.claude-plugin/plugin.json"

out="$(symlink_enumerate "$FIX/claude" "$HOME/.claude")"

awk -F'\t' -v s="$SK" -v d="$HOME/.claude/skills/demo" \
  '$3 == "skills/demo" && $1 == s && $2 == d { found = 1 } END { exit !found }' <<<"$out"
check "skill bundle enumerated as one directory record (no trailing slash)" $((1 - $?))

! awk -F'\t' '$3 ~ /^skills\/demo\// { found = 1 } END { exit !found }' <<<"$out"
check "no per-file records inside a skill bundle" $((1 - $?))

# Legacy layout: a real directory holding only our own per-file links (live or
# dangling) is converted in place; anything else is left for the caller.
H="$FIX/home"
legacy="$H/.claude/skills/demo"
mkdir -p "$legacy"
ln -s "$SK/SKILL.md" "$legacy/SKILL.md"
ln -s "$SK/removed.md" "$legacy/removed.md"
symlink_is_legacy_skill_dir "$SK" "$legacy"
check "per-file link dir recognized as legacy layout" $((1 - $?))
symlink_migrate_legacy_skill_dir "$SK" "$legacy" && [ ! -e "$legacy" ] && [ ! -L "$legacy" ]
check "legacy layout removed so the directory link can take its place" $((1 - $?))

mkdir -p "$legacy"
ln -s "$SK/SKILL.md" "$legacy/SKILL.md"
printf 'my notes\n' >"$legacy/notes.md"
! symlink_is_legacy_skill_dir "$SK" "$legacy"
check "dir holding a real file is not legacy" $((1 - $?))
mkdir -p "$legacy/sub"
rm "$legacy/notes.md"
! symlink_is_legacy_skill_dir "$SK" "$legacy"
check "dir holding a subdirectory is not legacy" $((1 - $?))
rmdir "$legacy/sub"
ln -s "$FIX/elsewhere.md" "$legacy/foreign.md"
! symlink_is_legacy_skill_dir "$SK" "$legacy"
check "dir holding a foreign link is not legacy" $((1 - $?))
! symlink_migrate_legacy_skill_dir "$SK" "$legacy" && [ -L "$legacy/foreign.md" ]
check "migration refuses a non-legacy dir and leaves it intact" $((1 - $?))
rm -rf "$H"

# ── SymlinkRepair.hook.ts stays in lockstep (issue #592) ───────────────────
# The SessionStart hook mirrors the enumerator in TypeScript; drive it against
# the same fixture and assert the same directory-link shape and migration.
HOOK="$SCRIPT_DIR/../../hooks/SymlinkRepair.hook.ts"
if ! command -v bun >/dev/null 2>&1; then
  echo "FAIL: bun is required to run SymlinkRepair.hook.ts" >&2
  failed=$((failed + 1))
else
  # Fresh HOME: the bundle lands as one directory link.
  H="$FIX/h-fresh"
  mkdir -p "$H"
  HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" >/dev/null 2>&1
  ok=0
  [ "$(readlink "$H/.claude/skills/demo")" = "$SK" ] \
    && [ -f "$H/.claude/skills/demo/references/x.md" ] \
    && [ -f "$H/.claude/skills/demo/scripts/y.sh" ] \
    && [ -f "$H/.claude/skills/demo/.claude-plugin/plugin.json" ] && ok=1
  check "SymlinkRepair links the skill directory; subfolders reachable" "$ok"

  # Legacy per-file layout: converted to the directory link.
  H="$FIX/h-legacy"
  mkdir -p "$H"
  mkdir -p "$H/.claude/skills/demo"
  ln -s "$SK/SKILL.md" "$H/.claude/skills/demo/SKILL.md"
  HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" >/dev/null 2>&1
  ok=0
  [ "$(readlink "$H/.claude/skills/demo")" = "$SK" ] && ok=1
  check "SymlinkRepair migrates a legacy per-file skill dir" "$ok"

  # The migration never deletes (issue #638): the old dir is archived whole
  # under ~/.claude/.migrated-skill-dirs/, links intact, and nothing is left
  # hidden in skills/. A legacy dir that cannot be moved (its parent skills/
  # is read-only, which is what blocks rename(2) on every platform) is
  # reported and left in place, still reachable, never half-converted.
  arch=""
  for d in "$H/.claude/.migrated-skill-dirs"/demo.*; do [ -d "$d" ] && arch="$d"; done
  ok=0
  [ -n "$arch" ] && [ "$(readlink "$arch/SKILL.md")" = "$SK/SKILL.md" ] \
    && [ "$(find "$H/.claude/skills" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] && ok=1
  check "SymlinkRepair archives the legacy dir, links intact" "$ok"
  # A foreign link swapped in just before the hook's rename is someone's own
  # config, not a rival's repair: it goes to kept/ and is reported, never
  # passed off as a clean conversion (gate review on #638). A --preload shim
  # makes the window deterministic by wrapping fs.renameSync.
  H="$FIX/h-foreign"
  mkdir -p "$H/.claude/skills/demo" "$FIX/my-own-skill"
  ln -s "$SK/SKILL.md" "$H/.claude/skills/demo/SKILL.md"
  cat > "$FIX/rename-shim.ts" <<SHIM
import fs from 'fs';
const real = fs.renameSync;
let fired = false;
fs.renameSync = ((from: fs.PathLike, to: fs.PathLike) => {
  if (!fired && String(from) === '$H/.claude/skills/demo') {
    fired = true;
    fs.unlinkSync('$H/.claude/skills/demo/SKILL.md');
    fs.rmdirSync('$H/.claude/skills/demo');
    fs.symlinkSync('$FIX/my-own-skill', '$H/.claude/skills/demo');
  }
  return real(from, to);
}) as typeof fs.renameSync;
SHIM
  hook_out="$(HOME="$H" DOTFILES_DIR="$FIX" bun --preload "$FIX/rename-shim.ts" "$HOOK" 2>&1)"
  kept_link=""
  for k in "$H/.claude/.migrated-skill-dirs/kept"/demo.*; do [ -L "$k" ] && kept_link="$k"; done
  ok=0
  [ -n "$kept_link" ] && [ "$(readlink "$kept_link")" = "$FIX/my-own-skill" ] \
    && grep -q 'skills/demo.*kept' <<<"$hook_out" && ok=1
  check "SymlinkRepair keeps and reports a foreign link grabbed by its rename" "$ok"

  # A symlinked archive root is refused: renaming through it could drop the
  # archived copy back into skills/ as a duplicate skill (#697).
  H="$FIX/h-archlink"
  mkdir -p "$H/.claude/skills/demo"
  ln -s "$SK/SKILL.md" "$H/.claude/skills/demo/SKILL.md"
  ln -sn "$H/.claude/skills" "$H/.claude/.migrated-skill-dirs"
  hook_out="$(HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" 2>&1)"
  dupes=0
  for d in "$H/.claude/skills"/demo.*; do [ -e "$d" ] && dupes=1; done
  ok=0
  [ -d "$H/.claude/skills/demo" ] && [ ! -L "$H/.claude/skills/demo" ] && [ "$dupes" -eq 0 ] \
    && grep -q 'skills/demo.*not a real directory' <<<"$hook_out" && ok=1
  check "SymlinkRepair refuses a symlinked archive root" "$ok"

  # A symlinked kept/ is never followed: changed content stays in the archive.
  H="$FIX/h-keptlink"
  mkdir -p "$H/.claude/skills/demo" "$H/.claude/.migrated-skill-dirs" "$FIX/kept-elsewhere"
  ln -s "$SK/SKILL.md" "$H/.claude/skills/demo/SKILL.md"
  ln -sn "$FIX/kept-elsewhere" "$H/.claude/.migrated-skill-dirs/kept"
  cat > "$FIX/change-shim.ts" <<SHIM
import fs from 'fs';
const real = fs.renameSync;
fs.renameSync = ((from: fs.PathLike, to: fs.PathLike) => {
  real(from, to);
  if (String(from) === '$H/.claude/skills/demo') {
    fs.unlinkSync(String(to) + '/SKILL.md');
    fs.writeFileSync(String(to) + '/SKILL.md', 'mine\n');
  }
}) as typeof fs.renameSync;
SHIM
  hook_out="$(HOME="$H" DOTFILES_DIR="$FIX" bun --preload "$FIX/change-shim.ts" "$HOOK" 2>&1)"
  found=0
  for f in "$H/.claude/.migrated-skill-dirs"/demo.*/SKILL.md; do [ -f "$f" ] && [ ! -L "$f" ] && found=1; done
  ok=0
  [ "$found" -eq 1 ] && [ -z "$(ls -A "$FIX/kept-elsewhere")" ] \
    && grep -q 'skills/demo.*changed during migration' <<<"$hook_out" && ok=1
  check "SymlinkRepair never follows a symlinked kept/" "$ok"

  # A rename that fails because a rival already installed exactly the bundle
  # link is that rival's completed repair, not a failure (#694). The shim
  # plays the rival, then fails the rename.
  H="$FIX/h-rivaldone"
  mkdir -p "$H/.claude/skills/demo"
  ln -s "$SK/SKILL.md" "$H/.claude/skills/demo/SKILL.md"
  cat > "$FIX/rival-shim.ts" <<SHIM
import fs from 'fs';
let fired = false;
const real = fs.renameSync;
fs.renameSync = ((from: fs.PathLike, to: fs.PathLike) => {
  if (!fired && String(from) === '$H/.claude/skills/demo') {
    fired = true;
    fs.unlinkSync('$H/.claude/skills/demo/SKILL.md');
    fs.rmdirSync('$H/.claude/skills/demo');
    fs.symlinkSync('$SK', '$H/.claude/skills/demo');
    throw Object.assign(new Error('EBUSY: rival in the way'), { code: 'EBUSY' });
  }
  return real(from, to);
}) as typeof fs.renameSync;
SHIM
  hook_out="$(HOME="$H" DOTFILES_DIR="$FIX" bun --preload "$FIX/rival-shim.ts" "$HOOK" 2>&1)"
  ok=0
  [ "$(readlink "$H/.claude/skills/demo")" = "$SK" ] \
    && ! grep -q 'skills/demo' <<<"$hook_out" && ok=1
  check "SymlinkRepair treats a rival's finished link after a failed rename as done" "$ok"

  if [ "$(id -u)" -ne 0 ]; then
    H="$FIX/h-legacy-ro"
    mkdir -p "$H/.claude/skills/demo"
    ln -s "$SK/SKILL.md" "$H/.claude/skills/demo/SKILL.md"
    # Archive parent (~/.claude) stays writable; only skills/ is locked.
    chmod 555 "$H/.claude/skills"
    hook_out="$(HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" 2>&1)"
    chmod 755 "$H/.claude/skills"
    ok=0
    [ -d "$H/.claude/skills/demo" ] && [ ! -L "$H/.claude/skills/demo" ] \
      && [ -L "$H/.claude/skills/demo/SKILL.md" ] \
      && grep -q 'skills/demo.*legacy skill dir move failed' <<<"$hook_out" && ok=1
    check "SymlinkRepair leaves an unmovable legacy dir in place and reports it" "$ok"
    # A dir it cannot read (0300) or traverse (0600) is never judged legacy,
    # so user content in it is never archived as "only old links".
    for mode in 300 600; do
      H="$FIX/h-perm$mode"
      mkdir -p "$H/.claude/skills/demo"
      printf 'mine\n' > "$H/.claude/skills/demo/notes.md"
      chmod "$mode" "$H/.claude/skills/demo"
      HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" >/dev/null 2>&1
      chmod 755 "$H/.claude/skills/demo"
      ok=0
      [ -d "$H/.claude/skills/demo" ] && [ ! -L "$H/.claude/skills/demo" ] \
        && [ -f "$H/.claude/skills/demo/notes.md" ] && [ ! -e "$H/.claude/.migrated-skill-dirs" ] && ok=1
      check "SymlinkRepair leaves an unreadable ($mode) dir untouched" "$ok"
    done
  fi

  # Real content at the destination: left alone and reported.
  H="$FIX/h-real"
  mkdir -p "$H"
  mkdir -p "$H/.claude/skills/demo"
  printf 'mine\n' >"$H/.claude/skills/demo/notes.md"
  hook_out="$(HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" 2>&1)"
  [ ! -L "$H/.claude/skills/demo" ] && [ -f "$H/.claude/skills/demo/notes.md" ] \
    && grep -q 'skills/demo' <<<"$hook_out"
  check "SymlinkRepair leaves a real skill dir alone and reports it" $((1 - $?))

  # No ~/.claude/scripts yet (fresh machine, hook wired before setup.sh ran,
  # #598): the hook creates the category dir, links *.sh, *.json and *.py
  # (the same set as symlink_enumerate) and exits 0.
  H="$FIX/h-nodir"
  mkdir -p "$H"
  HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" >/dev/null 2>&1
  check "SymlinkRepair exits 0 when ~/.claude/scripts is missing" $((1 - $?))
  ok=0
  [ "$(readlink "$H/.claude/scripts/gate.sh")" = "$FIX/claude/scripts/gate.sh" ] \
    && [ "$(readlink "$H/.claude/scripts/gate-schema.json")" = "$FIX/claude/scripts/gate-schema.json" ] \
    && [ ! -e "$H/.claude/scripts/README.md" ] && ok=1
  check "SymlinkRepair creates ~/.claude/scripts and links into it" "$ok"
  ok=0
  [ "$(readlink "$H/.claude/scripts/review-receipt.py")" = "$FIX/claude/scripts/review-receipt.py" ] && ok=1
  check "SymlinkRepair links scripts/*.py (matches symlink_enumerate)" "$ok"

  # No ~/.claude at all: the top-level pass runs first, so the config root
  # must exist before it, or every top-level link fails and stays missing
  # until the next SessionStart. Own fixture: the shared one's empty
  # nolink.txt makes the hook skip top-level files entirely.
  TOP="$FIX/top-dotfiles"
  mkdir -p "$TOP/claude"
  printf 'nolink.txt\n' >"$TOP/claude/nolink.txt"
  printf '# global\n' >"$TOP/claude/CLAUDE.md"
  H="$FIX/h-noroot"
  mkdir -p "$H"
  HOME="$H" DOTFILES_DIR="$TOP" bun "$HOOK" >/dev/null 2>&1
  ok=0
  [ "$(readlink "$H/.claude/CLAUDE.md")" = "$TOP/claude/CLAUDE.md" ] \
    && [ ! -e "$H/.claude/nolink.txt" ] && ok=1
  check "SymlinkRepair creates ~/.claude before linking top-level files" "$ok"

  # A link that cannot be created (read-only category dir) is reported as
  # skipped, never thrown: the hook still exits 0 and later categories run.
  if [ "$(id -u)" -ne 0 ]; then
    H="$FIX/h-ro"
    mkdir -p "$H/.claude/scripts"
    chmod 555 "$H/.claude/scripts"
    hook_out="$(HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" 2>&1)"
    rc=$?
    chmod 755 "$H/.claude/scripts"
    ok=0
    [ "$rc" -eq 0 ] && grep -q 'scripts/gate.sh' <<<"$hook_out" \
      && [ "$(readlink "$H/.claude/skills/demo")" = "$SK" ] && ok=1
    check "SymlinkRepair records an unlinkable entry as skipped and continues" "$ok"
  fi
fi

echo "symlink-enumerate: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
