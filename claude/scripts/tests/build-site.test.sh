#!/usr/bin/env bash
# build-site.test.sh — fixture tests for build-site.sh's awk frontmatter
# reader (issue #235). Builds throwaway git repos under mktemp with the five
# copied docs plus skill/agent sources, copies the builder INTO the fixture
# (it resolves the repo root from the caller's cwd via git), runs it, asserts
# exit code + an output fragment. The reader must fail LOUDLY — never
# silently mangle — on the two YAML forms it cannot represent: a blank line
# inside a block scalar, and quoted scalar values. Run directly; exit 1 on
# any failure. Mirrors skill-parity.test.sh.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
BUILDER="$SCRIPT_DIR/../build-site.sh"

pass=0
failed=0
R=""

# new_repo — fresh mktemp git repo (build-site locates the root via
# `git rev-parse`) with the builder copied in, the five docs it copies into
# site-src/, and one valid agent.
new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q
  mkdir -p "$R/claude/scripts" "$R/claude/skills" "$R/claude/agents" "$R/docs"
  cp "$BUILDER" "$R/claude/scripts/build-site.sh"
  chmod +x "$R/claude/scripts/build-site.sh"
  printf '# Readme\n' > "$R/README.md"
  printf '# Guide\n' > "$R/CLAUDE-GUIDE.md"
  printf '# Multi-agent\n' > "$R/claude/MULTI-AGENT.md"
  printf '# Windows\n' > "$R/docs/WINDOWS.md"
  printf '# Branch protection\n' > "$R/docs/BRANCH_PROTECTION.md"
  printf -- '---\nname: reviewer\ndescription: reviews things\n---\n' \
    > "$R/claude/agents/reviewer.md"
}

# write_skill_fm <name> <frontmatter-body...> — SKILL.md with the given
# frontmatter lines between the --- fences.
write_skill_fm() {
  local name="$1"
  shift
  mkdir -p "$R/claude/skills/$name"
  {
    echo "---"
    printf '%s\n' "$@"
    echo "---"
    echo ""
    echo "# $name"
  } > "$R/claude/skills/$name/SKILL.md"
}

# check <name> <expected-exit> [<required output fragment>]
check() {
  local name="$1" want="$2" frag="${3:-}"
  local out rc
  out="$(cd "$R" && claude/scripts/build-site.sh 2>&1)"
  rc=$?
  local ok=1
  [ "$rc" -eq "$want" ] || ok=0
  if [ -n "$frag" ] && ! grep -qF -- "$frag" <<<"$out"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (want rc=$want frag='$frag'; got rc=$rc)"
    echo "$out" | sed 's/^/      | /'
  fi
  rm -rf "$R"
}

# --- Case 1: GOOD — plain + folded-block frontmatter builds ------------------
new_repo
write_skill_fm demo "name: demo" "description: >-" "  first line" "  second line"
check "good: folded block joins lines and builds" 0 "build-site: OK"

# --- Case 1b: GOOD — folded value lands space-joined in the catalog ----------
new_repo
write_skill_fm demo "name: demo" "description: >-" "  first line" "  second line"
(cd "$R" && claude/scripts/build-site.sh >/dev/null 2>&1)
if grep -qF 'first line second line' "$R/site-src/skills.md"; then
  pass=$((pass + 1)); echo "ok   - good: folded description joined with single spaces"
else
  failed=$((failed + 1)); echo "FAIL - good: folded description joined with single spaces"
fi
rm -rf "$R"

# --- Case 2: GOOD — blank line AFTER a block, before the next key ------------
# (legal YAML, handled today; the guard must not false-positive on it)
new_repo
write_skill_fm demo "name: demo" "description: >-" "  only paragraph" "" \
  "disable-model-invocation: true"
check "good: blank line ending a block is not an error" 0 "build-site: OK"

# --- Case 3: BAD — blank line INSIDE a folded block → loud failure -----------
# True YAML keeps the second paragraph; the reader would silently drop it.
new_repo
write_skill_fm demo "name: demo" "description: >-" "  first paragraph" "" \
  "  second paragraph"
check "bad: blank line inside folded block fails loudly" 1 \
  'blank line inside block scalar for key "description"'

# --- Case 4: BAD — double-quoted scalar → loud failure -----------------------
# The reader would emit the quotes and backslash escapes literally.
new_repo
write_skill_fm demo "name: demo" 'description: "He said \"hi\""'
check "bad: double-quoted scalar fails loudly" 1 \
  'quoted scalar for key "description"'

# --- Case 5: BAD — single-quoted scalar → loud failure -----------------------
new_repo
write_skill_fm demo "name: demo" "description: 'quoted value'"
check "bad: single-quoted scalar fails loudly" 1 \
  'quoted scalar for key "description"'

echo ""
echo "build-site tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
