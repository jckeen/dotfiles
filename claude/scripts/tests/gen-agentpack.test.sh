#!/usr/bin/env bash
# gen-agentpack.test.sh — fixture tests for gen-agentpack.sh's frontmatter
# reader (issue #235). Builds throwaway repos under mktemp, copies the
# generator INTO the fixture (it resolves REPO_ROOT from its own location,
# not cwd), runs it, asserts exit code + an output fragment. The reader must
# fail LOUDLY — never silently mangle — on the two YAML forms it cannot
# represent: a blank line inside a block scalar, and quoted scalar values.
# Run directly; exit 1 on any failure. Mirrors skill-parity.test.sh.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
GENERATOR="$SCRIPT_DIR/../gen-agentpack.sh"
LIB="$SCRIPT_DIR/../checker-lib.sh"

pass=0
failed=0
R=""

# new_repo — fresh mktemp fixture with the generator copied in at the same
# repo-relative path the real repo uses, so REPO_ROOT resolves to $R, plus a
# minimal meta fragment and one valid agent (the generator dies without one).
new_repo() {
  R="$(mktemp -d)"
  mkdir -p "$R/claude/scripts" "$R/claude/skills" "$R/claude/agents"
  cp "$GENERATOR" "$R/claude/scripts/gen-agentpack.sh"
  cp "$LIB" "$R/claude/scripts/checker-lib.sh"
  chmod +x "$R/claude/scripts/gen-agentpack.sh"
  cat > "$R/claude/agentpack-meta.json" <<'JSON'
{
  "agentpack": "0.1",
  "metadata": {"name": "fixture"},
  "compatibility": {},
  "permissions": {},
  "security": {},
  "profiles": {},
  "exports": {},
  "instruction_atoms": [],
  "atom_defaults": {
    "skill": {"risk_level": "low", "permissions": [], "skill_format": "agent-skills"},
    "subagent": {"risk_level": "medium", "permissions": []}
  }
}
JSON
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
  out="$("$R/claude/scripts/gen-agentpack.sh" 2>&1)"
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

# --- Case 1: GOOD — plain + folded-block frontmatter generates ---------------
new_repo
write_skill_fm demo "name: demo" "description: >-" "  first line" "  second line"
check "good: folded block joins lines and generates" 0 "gen-agentpack: wrote"

# --- Case 1b: GOOD — folded value survives verbatim in the manifest ----------
new_repo
write_skill_fm demo "name: demo" "description: >-" "  first line" "  second line"
"$R/claude/scripts/gen-agentpack.sh" >/dev/null 2>&1
if grep -qF '"description": "first line second line"' "$R/claude/AGENTPACK.yaml"; then
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
check "good: blank line ending a block is not an error" 0 "gen-agentpack: wrote"

# --- Case 3: BAD — blank line INSIDE a folded block → loud failure -----------
# True YAML keeps the second paragraph; the reader would silently drop it.
new_repo
write_skill_fm demo "name: demo" "description: >-" "  first paragraph" "" \
  "  second paragraph"
check "bad: blank line inside folded block fails loudly" 1 \
  "blank line inside block scalar for key 'description'"

# --- Case 4: BAD — double-quoted scalar → loud failure -----------------------
# The reader would emit the quotes and backslash escapes literally.
new_repo
write_skill_fm demo "name: demo" 'description: "He said \"hi\""'
check "bad: double-quoted scalar fails loudly" 1 \
  "quoted scalar for key 'description'"

# --- Case 5: BAD — single-quoted scalar → loud failure -----------------------
new_repo
write_skill_fm demo "name: demo" "description: 'quoted value'"
check "bad: single-quoted scalar fails loudly" 1 \
  "quoted scalar for key 'description'"

# --- Case 6: BAD — literal block scalar → loud failure ------------------------
# Newlines are semantic in literal YAML; the reader would space-join them.
new_repo
write_skill_fm demo "name: demo" "description: |-" "  line one" "  line two"
check "bad: literal block scalar fails loudly" 1 \
  "literal block scalar (|) for key 'description'"

# --- Case 7: BAD — multi-line plain scalar → loud failure ---------------------
# Valid YAML folds the indented continuation in; the reader would drop it.
new_repo
write_skill_fm demo "name: demo" "description: first part" "  continuation part"
check "bad: multi-line plain scalar fails loudly" 1 \
  "multi-line plain scalar for key 'description'"

# --- Case 8: GOOD — plain `key: value` then the next key ----------------------
# (the plain-scalar guard must not false-positive on ordinary frontmatter)
new_repo
write_skill_fm demo "name: demo" "description: a plain value" \
  "disable-model-invocation: true"
check "good: plain value followed by next key is not an error" 0 \
  "gen-agentpack: wrote"

echo ""
echo "gen-agentpack tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
