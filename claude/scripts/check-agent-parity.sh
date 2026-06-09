#!/usr/bin/env bash
# check-agent-parity.sh — keep the Claude and Codex global rule sets in sync.
#
# Two assistants, two global rule files: claude/CLAUDE.md and codex/AGENTS.md.
# They are written in different voices but must agree on the *durable working
# rules* — scoped edits, read-before-change, verify-your-work, and the public
# safety contract (never commit secrets/auth; private context lives in the
# private memory repos). When a rule is added to one file and forgotten in the
# other, the two agents drift apart. This guard fails CI when that happens.
#
# It does NOT diff prose. It checks that each canonical *concept* below is
# present in BOTH files, matched by a permissive regex (any phrasing that hits
# the pattern counts). Add a concept here when a new cross-agent rule is
# established; the guard then forces it into both files.
#
# Usage:  claude/scripts/check-agent-parity.sh
# Run from anywhere; resolves its own repo root (it is symlinked into ~/.claude).

set -euo pipefail

# --- Locate repo root via the real (symlink-resolved) path -----
# Mirrors check-doc-refs.sh: this script is symlinked into ~/.claude/scripts.
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

CLAUDE_MD="claude/CLAUDE.md"
AGENTS_MD="codex/AGENTS.md"

for f in "$CLAUDE_MD" "$AGENTS_MD"; do
  [[ -f "$f" ]] || { echo "✖ parity: missing $f" >&2; exit 1; }
done

# Canonical cross-agent rules: "label|regex". The regex must match (case-
# insensitive) in BOTH files. Keep patterns permissive — we assert the *idea*
# is present, not exact wording.
RULES=(
  "scoped-edits|scope|scoped|unrelated|leave .*work alone|did not make"
  "read-before-change|read .*(before|surrounding)|existing patterns"
  "verify-changes|verif|smallest .*(test|check)|run the test"
  "report-unrun-tests|report .*(test|failure)|could not run|stop and fix"
  "no-commit-secrets|never (commit|stage) .*(auth|secret|token|credential|\.env)|skip secrets"
  "private-memory-split|claude-memory|codex-memory|private .*(repo|memory)"
)

fail=0
for rule in "${RULES[@]}"; do
  label="${rule%%|*}"
  pattern="${rule#*|}"
  c_hit=0; a_hit=0
  grep -qiE "$pattern" "$CLAUDE_MD" && c_hit=1
  grep -qiE "$pattern" "$AGENTS_MD" && a_hit=1
  if [[ "$c_hit" -eq 0 || "$a_hit" -eq 0 ]]; then
    if [[ "$fail" -eq 0 ]]; then
      echo "✖ Agent rule parity drift — these canonical rules are missing from one side:" >&2
      echo "  (each rule must appear in BOTH $CLAUDE_MD and $AGENTS_MD)" >&2
      echo "" >&2
    fi
    fail=1
    missing=""
    [[ "$c_hit" -eq 0 ]] && missing="$CLAUDE_MD"
    [[ "$a_hit" -eq 0 ]] && missing="${missing:+$missing, }$AGENTS_MD"
    printf '  - %-22s missing from: %s\n' "$label" "$missing" >&2
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "" >&2
  echo "Add the rule to the file(s) above, or relax its pattern in check-agent-parity.sh" >&2
  echo "if the concept is genuinely Claude- or Codex-specific." >&2
  exit 1
fi

echo "✓ agent-parity: all canonical rules present in both CLAUDE.md and AGENTS.md."
