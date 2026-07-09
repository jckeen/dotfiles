#!/usr/bin/env bash
# agent-parity.test.sh — fixture tests for check-agent-parity.sh.
# Builds throwaway repos under mktemp, COPIES the real checker into each fixture
# (the checker resolves REPO_ROOT from its own location, so the copy roots on the
# fixture), runs it, and asserts exit code + an output fragment. Run directly;
# exit 1 on any failure. Mirrors doc-truth.test.sh / install-integrity.test.sh.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
REAL_CHECKER="$SCRIPT_DIR/../check-agent-parity.sh"
LIB="$SCRIPT_DIR/../checker-lib.sh"

pass=0
failed=0
R=""

# new_repo — fresh fixture repo with a copy of the checker at the path the
# checker itself expects (claude/scripts/), so its REPO_ROOT resolves to $R.
new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q
  mkdir -p "$R/claude/scripts" "$R/codex" "$R/antigravity"
  cp "$REAL_CHECKER" "$R/claude/scripts/check-agent-parity.sh"
  cp "$LIB" "$R/claude/scripts/checker-lib.sh"
  chmod +x "$R/claude/scripts/check-agent-parity.sh"
}

# w <repo-relative path> <line>...  — write a file, one arg per line
w() {
  local p="$R/$1"
  shift
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" > "$p"
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

# Lines crafted to satisfy every RULES regex in check-agent-parity.sh:
#   scoped-edits        -> "scope"
#   read-before-change  -> "read the surrounding"
#   verify-changes      -> "verif(y)"
#   report-unrun-tests  -> "report ... test"
#   no-commit-secrets   -> "never commit ... secret"
#   private-memory-split-> "claude-memory"
#   doc-contract        -> "doc-contract"
claude_full() {
  w claude/CLAUDE.md \
    '# Claude global rules' \
    '- Keep changes scoped to the request.' \
    '- Read the surrounding code before changing behavior.' \
    '- Verify your work by running the smallest test.' \
    '- Report any test you could not run.' \
    '- Never commit secrets, tokens, or credentials.' \
    '- Private context lives in the claude-memory repo.' \
    '- A doc-contract is asserted in CI by check-doc-truth.'
}

# Antigravity side, same seven concepts in a different voice.
gemini_full() {
  w antigravity/GEMINI.md \
    '# Antigravity global rules' \
    '- Keep edits scoped to the requested behavior.' \
    '- Read the surrounding code before changing it.' \
    '- Verify with the smallest useful check.' \
    '- Report any test you could not run.' \
    '- Never commit secrets, auth tokens, or credentials.' \
    '- Private notes live in the agy-memory and claude-memory repos.' \
    '- Respect the doc-contract enforced by check-doc-truth.'
}

# Codex side, same seven concepts in a different voice.
agents_full() {
  w codex/AGENTS.md \
    '# Codex global rules' \
    '- Keep the change scope tight and focused.' \
    '- Read the surrounding code before you edit it.' \
    '- Verify edits with a quick check before finishing.' \
    '- Report any test that failed or you skipped.' \
    '- Never commit secrets or API tokens to the repo.' \
    '- Personal notes live in the codex-memory and claude-memory repos.' \
    '- Respect the doc-contract enforced by check-doc-truth.'
}

# --- Case 1: all files complete → pass ---------------------------------------
new_repo
claude_full
agents_full
gemini_full
check "all files carry all 7 concepts passes" 0 "agent-parity"

# --- Case 2: one concept dropped from AGENTS.md → drift fail ----------------
# Same as the good case but the codex side omits the doc-contract line.
new_repo
claude_full
gemini_full
w codex/AGENTS.md \
  '# Codex global rules' \
  '- Keep the change scope tight and focused.' \
  '- Read the surrounding code before you edit it.' \
  '- Verify edits with a quick check before finishing.' \
  '- Report any test that failed or you skipped.' \
  '- Never commit secrets or API tokens to the repo.' \
  '- Personal notes live in the codex-memory and claude-memory repos.'
check "concept missing from one side fails as drift" 1 "missing from"

# --- Case 3: AGENTS.md absent entirely → missing-file fail ------------------
new_repo
claude_full
gemini_full
check "absent codex/AGENTS.md fails as missing" 1 "missing"

# --- Case 4: GEMINI.md absent entirely → missing-file fail -------------------
new_repo
claude_full
agents_full
check "absent antigravity/GEMINI.md fails as missing" 1 "missing"

echo "---"
echo "$pass passed, $failed failed"
[[ "$failed" -eq 0 ]]
