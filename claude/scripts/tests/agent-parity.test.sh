#!/usr/bin/env bash
# agent-parity.test.sh — fixture tests for check-agent-parity.sh and
# gen-instruction-files.sh (ADR-0007).
# Builds throwaway repos under mktemp, COPIES the real checker + generator into
# each fixture (both resolve REPO_ROOT from their own location, so the copies
# root on the fixture), writes canon sources, generates the three instruction
# files, runs the checker, and asserts exit code + an output fragment. Run
# directly; exit 1 on any failure. Mirrors doc-truth.test.sh.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
REAL_CHECKER="$SCRIPT_DIR/../check-agent-parity.sh"
REAL_GEN="$SCRIPT_DIR/../gen-instruction-files.sh"
LIB="$SCRIPT_DIR/../checker-lib.sh"

pass=0
failed=0
R=""

# new_repo — fresh fixture repo with copies of the checker, generator, and lib
# at the paths they expect (claude/scripts/), so REPO_ROOT resolves to $R.
new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q
  mkdir -p "$R/claude/scripts" "$R/codex" "$R/antigravity" \
    "$R/agents/canon/fragments"
  cp "$REAL_CHECKER" "$R/claude/scripts/check-agent-parity.sh"
  cp "$REAL_GEN" "$R/claude/scripts/gen-instruction-files.sh"
  cp "$LIB" "$R/claude/scripts/checker-lib.sh"
  chmod +x "$R/claude/scripts/check-agent-parity.sh" \
    "$R/claude/scripts/gen-instruction-files.sh"
  # Empty canon (no shared blocks): fragments then pass through verbatim.
  printf '%s\n' '# Canon (fixture)' > "$R/agents/canon/CANON.md"
}

# w <repo-relative path> <line>...  — write a file, one arg per line
w() {
  local p="$R/$1"
  shift
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" > "$p"
}

# gen — run the generator inside the fixture; returns its exit code and
# leaves stderr in $R/gen.err for message assertions.
gen() {
  (cd "$R" && ./claude/scripts/gen-instruction-files.sh > /dev/null 2> "$R/gen.err")
}

# check <name> <expected-exit> [<required output fragment>]
check() {
  local name="$1" want="$2" frag="${3:-}"
  local out rc
  out="$(cd "$R" && ./claude/scripts/check-agent-parity.sh 2>&1)"
  rc=$?
  local ok=1
  [[ "$rc" -eq "$want" ]] || ok=0
  if [[ -n "$frag" ]] && ! grep -qF -- "$frag" <<<"$out"; then ok=0; fi
  if [[ "$ok" -eq 1 ]]; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (want rc=$want frag='$frag'; got rc=$rc)"
    echo "$out" | sed 's/^/      | /'
  fi
  rm -rf "$R"
}

# assert <name> <condition-exit-code(0=pass)> — direct assertion helper for
# generator-only cases (no checker run).
assert() {
  local name="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name"
  fi
  rm -rf "$R"
}

# Lines crafted to satisfy every RULES regex in check-agent-parity.sh:
#   scoped-edits            -> "changes scoped to the request"
#   read-before-change      -> "read the surrounding code before"
#   verify-changes          -> "way to check the work" / "smallest useful test"
#   report-unrun-tests      -> "test you could not run"
#   no-commit-secrets       -> "never commit ... secret"
#   private-memory-split    -> "claude-memory"
#   doc-contract            -> "doc-contract"
#   one-owner-worktree      -> "one owner of the working tree"
#   adversarial-verification-> "verification is adversarial"
#   handoff-claim-repro     -> "claim to disprove"
#   two-floor-grounding     -> "two-floor grounding"
claude_frag() {
  w agents/canon/fragments/claude.md \
    '# Claude global rules' \
    '- Keep changes scoped to the request.' \
    '- Read the surrounding code before changing behavior.' \
    '- Give yourself a way to check the work: run the smallest useful test.' \
    '- Report any test you could not run.' \
    '- Never commit secrets, tokens, or credentials.' \
    '- Private context lives in the claude-memory repo.' \
    '- A doc-contract is asserted in CI by check-doc-truth.' \
    '- One owner of the working tree at a time.' \
    '- Verification is adversarial, not an echo chamber.' \
    '- A handoff carries the claim to disprove and the exact repro command.' \
    '- Two-floor grounding: a project floor plus an external floor.'
}

# Antigravity side, same concepts in a different voice.
gemini_frag() {
  w agents/canon/fragments/antigravity.md \
    '# Antigravity global rules' \
    '- Keep edits scoped to the requested behavior.' \
    '- Read the surrounding code before changing it.' \
    '- Verify your changes with the smallest useful check.' \
    '- Report any test that could not be run.' \
    '- Never commit secrets, auth tokens, or credentials.' \
    '- Private notes live in the agy-memory and claude-memory repos.' \
    '- Respect the doc-contract enforced by check-doc-truth.' \
    '- One owner of the working tree at a time; use a separate worktree.' \
    '- Verification is adversarial: try to break the claim.' \
    '- Ask for the claim to disprove and the exact repro command.' \
    '- Two-floor grounding: verify a project floor and an external floor.'
}

# Codex side, same concepts in a third voice. $1 optionally names a rule
# label to OMIT (for the per-rule drift cases).
codex_frag() {
  local omit="${1:-}"
  local lines=('# Codex global rules')
  [[ "$omit" == scoped-edits ]] \
    || lines+=('- Keep the change scope tight: edits scoped to the request only.')
  [[ "$omit" == read-before-change ]] \
    || lines+=('- Read the surrounding code before you edit it.')
  [[ "$omit" == verify-changes ]] \
    || lines+=('- Verify meaningful changes with the smallest useful check.')
  [[ "$omit" == report-unrun-tests ]] \
    || lines+=('- Report any test you could not run.')
  [[ "$omit" == no-commit-secrets ]] \
    || lines+=('- Never commit secrets or API tokens to the repo.')
  [[ "$omit" == private-memory-split ]] \
    || lines+=('- Personal notes live in the codex-memory and claude-memory repos.')
  [[ "$omit" == doc-contract ]] \
    || lines+=('- Respect the doc-contract enforced by check-doc-truth.')
  [[ "$omit" == one-owner-worktree ]] \
    || lines+=('- One owner of the working tree at a time.')
  [[ "$omit" == adversarial-verification ]] \
    || lines+=('- Verification is adversarial, never an echo chamber.')
  [[ "$omit" == handoff-claim-repro ]] \
    || lines+=('- A handoff carries the claim to disprove and the repro command.')
  [[ "$omit" == two-floor-grounding ]] \
    || lines+=('- Two-floor grounding: a project floor and an external floor.')
  w agents/canon/fragments/codex.md "${lines[@]}"
}

all_frags() {
  claude_frag
  gemini_frag
  codex_frag "${1:-}"
}

# --- Case 1: all files complete → pass ---------------------------------------
new_repo
all_frags
gen
check "all files carry all concepts passes" 0 "agent-parity"

# --- Case 2: concept dropped from one side → drift fail ----------------------
new_repo
all_frags doc-contract
gen
check "concept missing from one side fails as drift" 1 "doc-contract"

# --- Case 3/4: a generated file absent entirely → missing-file fail ----------
new_repo
claude_frag
gemini_frag
gen 2> /dev/null # fails: codex fragment missing, so codex/AGENTS.md never built
check "absent codex/AGENTS.md fails as missing" 1 "missing"

new_repo
claude_frag
codex_frag
gen 2> /dev/null
check "absent antigravity/GEMINI.md fails as missing" 1 "missing"

# --- Case 5: tightened regex — a bare keyword no longer satisfies a rule ----
# Old pattern matched the word "scope" anywhere; the sentence below contains
# "scope"/"scoped" talk but not the rule, and must now fail scoped-edits.
new_repo
all_frags scoped-edits
{
  echo '- The scope of this project is intentionally wide in scoped areas.'
} >> "$R/agents/canon/fragments/codex.md"
gen
check "bare 'scope' keyword no longer satisfies scoped-edits" 1 "scoped-edits"

# --- Cases 6-9: each lane-contract / two-floor rule can fail independently ---
for rule in one-owner-worktree adversarial-verification handoff-claim-repro \
  two-floor-grounding; do
  new_repo
  all_frags "$rule"
  gen
  check "missing $rule fails as drift" 1 "$rule"
done

# --- Case 10: hand-edit to a generated file → currency fail ------------------
new_repo
all_frags
gen
echo '- Sneaky hand-edited rule.' >> "$R/codex/AGENTS.md"
check "hand-edit to generated file fails currency check" 1 "stale or hand-edited"

# --- Case 11: canon edit without regeneration → currency fail ----------------
new_repo
all_frags
gen
echo '- New rule added to fragment but never regenerated.' \
  >> "$R/agents/canon/fragments/claude.md"
check "canon edit without regeneration fails currency check" 1 "stale or hand-edited"

# --- Case 12: include expansion — canon block lands in the output ------------
new_repo
w agents/canon/CANON.md \
  '# Canon (fixture)' \
  '<!-- canon:canary -->' \
  '- Canary rule from the canon block.' \
  '<!-- /canon:canary -->'
all_frags
printf '%s\n' '<!-- include:canary -->' >> "$R/agents/canon/fragments/codex.md"
gen
grep -qF -- '- Canary rule from the canon block.' "$R/codex/AGENTS.md"
assert "include marker expands to canon block content" $?

# --- Case 13: unknown include id → generator fails ---------------------------
new_repo
all_frags
printf '%s\n' '<!-- include:no-such-block -->' \
  >> "$R/agents/canon/fragments/codex.md"
gen
[[ $? -ne 0 ]]
assert "unknown canon block id fails generation" $?

# --- Case 14: canon block included by no fragment → generator fails ----------
new_repo
w agents/canon/CANON.md \
  '# Canon (fixture)' \
  '<!-- canon:orphan -->' \
  '- Orphaned shared rule reaching no agent.' \
  '<!-- /canon:orphan -->'
all_frags
gen
[[ $? -ne 0 ]]
assert "orphaned canon block fails generation" $?

# --- Case 15: malformed marker (trailing space) → generator fails loudly -----
# `<!-- include:canary -->␠` doesn't parse as a marker; without the leak guard
# it would ship literally in the instruction file with rc=0 — a shared rule
# silently reaching no agent (ADR-0007's named worst failure mode).
new_repo
w agents/canon/CANON.md \
  '# Canon (fixture)' \
  '<!-- canon:canary -->' \
  '- Canary rule from the canon block.' \
  '<!-- /canon:canary -->'
all_frags
printf '%s\n' '<!-- include:canary -->' >> "$R/agents/canon/fragments/codex.md"
printf '%s\n' '<!-- include:canary --> ' >> "$R/agents/canon/fragments/claude.md"
gen
[[ $? -ne 0 ]] && grep -q 'unexpanded' "$R/gen.err"
assert "trailing-space include marker fails generation loudly" $?

# --- Case 16: include marker inside a canon block → generator fails ----------
# Only fragment lines are expanded; a marker inside a block's content would
# otherwise be emitted literally into the shipped file.
new_repo
w agents/canon/CANON.md \
  '# Canon (fixture)' \
  '<!-- canon:canary -->' \
  '- Canary rule from the canon block.' \
  '<!-- include:smuggled -->' \
  '<!-- /canon:canary -->'
all_frags
printf '%s\n' '<!-- include:canary -->' >> "$R/agents/canon/fragments/codex.md"
gen
[[ $? -ne 0 ]] && grep -q 'unexpanded' "$R/gen.err"
assert "include marker inside a canon block fails generation loudly" $?

# --- Case 17: generator is idempotent -----------------------------------------
new_repo
all_frags
gen
h1="$(cat "$R/claude/CLAUDE.md" "$R/codex/AGENTS.md" "$R/antigravity/GEMINI.md" | sha256sum)"
gen
h2="$(cat "$R/claude/CLAUDE.md" "$R/codex/AGENTS.md" "$R/antigravity/GEMINI.md" | sha256sum)"
[[ "$h1" == "$h2" ]]
assert "running the generator twice changes nothing" $?

echo "---"
echo "$pass passed, $failed failed"
[[ "$failed" -eq 0 ]]
