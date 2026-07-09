#!/usr/bin/env bash
# skill-parity.test.sh — fixture tests for check-skill-parity.sh.
# Builds throwaway git repos under mktemp, copies the checker INTO the fixture
# (it resolves REPO_ROOT from its own location, not cwd), runs it, asserts exit
# code + an output fragment. Run directly; exit 1 on any failure. Mirrors
# install-integrity.test.sh.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
CHECKER="$SCRIPT_DIR/../check-skill-parity.sh"
LIB="$SCRIPT_DIR/../checker-lib.sh"

pass=0
failed=0
R=""

# new_repo — fresh mktemp git repo with the checker copied in at the same
# repo-relative path the real repo uses, so REPO_ROOT resolves to $R.
new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
  mkdir -p "$R/claude/scripts" "$R/claude/skills" "$R/agents/skills"
  cp "$CHECKER" "$R/claude/scripts/check-skill-parity.sh"
  cp "$LIB" "$R/claude/scripts/checker-lib.sh"
  chmod +x "$R/claude/scripts/check-skill-parity.sh"
}

# skill_files — populate a changelog+handoff skill pair under a side.
# usage: skill_files <side> <changelog-extra-headings-off?>  (kept simple below)

# write_skill <side> <skill> <heading>...  — write a SKILL.md with given headings
write_skill() {
  local side="$1" skill="$2"
  shift 2
  local p="$R/$side/skills/$skill/SKILL.md"
  mkdir -p "$(dirname "$p")"
  {
    printf '# %s skill\n\n' "$skill"
    local h
    for h in "$@"; do
      printf '### %s\n\nbody\n\n' "$h"
    done
  } > "$p"
}

# scaffold_good — README claiming N, exactly the changelog+handoff skill dirs,
# a matching "N-agent" claim + agent files, and both sides' SKILL.md with all
# required headings.
scaffold_good() {
  printf '# Dotfiles\n\nProvides 2 slash commands and a 1-agent review orchestra.\n' > "$R/README.md"
  # one agent file to match the "1-agent" claim
  mkdir -p "$R/claude/agents"
  printf '# reviewer\n' > "$R/claude/agents/reviewer.md"
  # exactly two skill dirs under claude/skills: changelog + handoff
  write_skill claude changelog "What changed" "Decisions made" "Known issues"
  write_skill agents changelog "What changed" "Decisions made" "Known issues"
  write_skill claude handoff "What we did" "Where we left off" "Key decisions made" \
    "Open issues" "Next steps" "Context for next session"
  write_skill agents handoff "What we did" "Where we left off" "Key decisions made" \
    "Open issues" "Next steps" "Context for next session"
}

# check <name> <expected-exit> [<required output fragment>]
check() {
  local name="$1" want="$2" frag="${3:-}"
  local out rc
  out="$("$R/claude/scripts/check-skill-parity.sh" 2>&1)"
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

# --- Case 1: GOOD — count matches, both pairs shaped correctly → exit 0 ------
new_repo
scaffold_good
check "good: count matches + shapes present passes" 0 "skill-parity: OK"

# --- Case 2: BAD (count) — README claims 3 but only 2 skill dirs → exit 1 ----
new_repo
scaffold_good
printf '# Dotfiles\n\nProvides 3 slash commands for daily use.\n' > "$R/README.md"
check "bad count: README claim mismatches skill dirs fails" 1 "README claims"

# --- Case 3: BAD (missing heading) — drop a required heading from a pair -----
new_repo
scaffold_good
# shared-agent changelog loses "### Known issues"
write_skill agents changelog "What changed" "Decisions made"
check "bad shape: missing heading fails" 1 "missing heading"

# --- Case 4: BAD (agent count) — README says 1-agent but two agent files ------
new_repo
scaffold_good
printf '# scout\n' > "$R/claude/agents/scout.md"   # now 2 agents, claim still 1
check "bad agent count: README claim mismatches agent files fails" 1 "but claude/agents/ has 2"

echo "---"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
