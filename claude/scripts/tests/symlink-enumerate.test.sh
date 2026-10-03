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
# The hook's per-file categories assume setup.sh already created their parent
# dirs (the hook throws without them, #598), so each fixture HOME starts with
# ~/.claude/scripts in place.
mkhome() { mkdir -p "$1/.claude/scripts"; }
if ! command -v bun >/dev/null 2>&1; then
  echo "FAIL: bun is required to run SymlinkRepair.hook.ts" >&2
  failed=$((failed + 1))
else
  # Fresh HOME: the bundle lands as one directory link.
  H="$FIX/h-fresh"
  mkhome "$H"
  HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" >/dev/null 2>&1
  ok=0
  [ "$(readlink "$H/.claude/skills/demo")" = "$SK" ] \
    && [ -f "$H/.claude/skills/demo/references/x.md" ] \
    && [ -f "$H/.claude/skills/demo/scripts/y.sh" ] \
    && [ -f "$H/.claude/skills/demo/.claude-plugin/plugin.json" ] && ok=1
  check "SymlinkRepair links the skill directory; subfolders reachable" "$ok"

  # Legacy per-file layout: converted to the directory link.
  H="$FIX/h-legacy"
  mkhome "$H"
  mkdir -p "$H/.claude/skills/demo"
  ln -s "$SK/SKILL.md" "$H/.claude/skills/demo/SKILL.md"
  HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" >/dev/null 2>&1
  ok=0
  [ "$(readlink "$H/.claude/skills/demo")" = "$SK" ] && ok=1
  check "SymlinkRepair migrates a legacy per-file skill dir" "$ok"

  # Real content at the destination: left alone and reported.
  H="$FIX/h-real"
  mkhome "$H"
  mkdir -p "$H/.claude/skills/demo"
  printf 'mine\n' >"$H/.claude/skills/demo/notes.md"
  hook_out="$(HOME="$H" DOTFILES_DIR="$FIX" bun "$HOOK" 2>&1)"
  [ ! -L "$H/.claude/skills/demo" ] && [ -f "$H/.claude/skills/demo/notes.md" ] \
    && grep -q 'skills/demo' <<<"$hook_out"
  check "SymlinkRepair leaves a real skill dir alone and reports it" $((1 - $?))
fi

echo "symlink-enumerate: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
