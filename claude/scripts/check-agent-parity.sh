#!/usr/bin/env bash
# check-agent-parity.sh — keep the Claude, Codex, and Antigravity global rule
# sets in sync.
#
# Three assistants, three global rule files: claude/CLAUDE.md, codex/AGENTS.md,
# and antigravity/GEMINI.md. Since ADR-0007 those three files are GENERATED
# artifacts, built by gen-instruction-files.sh from agents/canon/CANON.md
# (shared rule blocks) plus agents/canon/fragments/<tool>.md (per-tool voice).
#
# Two checks, both required:
#
#  1. Concept parity — each canonical *concept* below must be present in ALL
#     three generated files, matched by a rule-shaped regex (a phrase from the
#     rule, not a bare keyword). The files are written in different voices but
#     must agree on the durable working rules: scoped edits, read-before-change,
#     verify-your-work, the public safety contract, and the multi-agent lane
#     contract (one owner of the working tree, adversarial verification, the
#     claim-to-disprove handoff payload, two-floor grounding). Add a concept
#     here when a new cross-agent rule is established.
#
#  2. Generation currency — the three files must be byte-identical to what
#     gen-instruction-files.sh produces from agents/canon/. A hand-edit to a
#     generated file, or a canon edit without regeneration, fails CI.
#
# Usage:  claude/scripts/check-agent-parity.sh
# Run from anywhere; resolves its own repo root (it is symlinked into ~/.claude).

set -euo pipefail

# --- Load shared helpers, then locate repo root via the real path -----
# checker-lib.sh sits beside this script (setup.sh symlinks both into
# ~/.claude/scripts; self-tests copy both into the fixture). It provides
# resolve_script_path, which follows symlinks so REPO_ROOT lands on the
# dotfiles checkout rather than ~/.claude.
# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
REPO_ROOT="$(checker_repo_root "${BASH_SOURCE[0]}")"
cd "$REPO_ROOT"

CLAUDE_MD="claude/CLAUDE.md"
AGENTS_MD="codex/AGENTS.md"
GEMINI_MD="antigravity/GEMINI.md"

for f in "$CLAUDE_MD" "$AGENTS_MD" "$GEMINI_MD"; do
  [[ -f "$f" ]] || { echo "✖ parity: missing $f" >&2; exit 1; }
done

# Canonical cross-agent rules: "label|regex". The regex must match (case-
# insensitive) in ALL three files. Patterns are *rule-shaped* — each
# alternative is a phrase from the rule itself, so a stray keyword ("scope",
# "verification") can no longer satisfy a concept (#206). Wording stays free
# per file; the phrase list grows when a file legitimately rephrases a rule.
RULES=(
  "scoped-edits|(changes|edits|the change) scoped to the request|change scope tight"
  "read-before-change|read the surrounding code before"
  "verify-changes|way to check the work|verify (meaningful|your) (changes|work)|smallest useful (test|check)"
  "report-unrun-tests|test (you|that) could not (be )?run"
  "no-commit-secrets|never (commit|stage) .*(auth|secret|token|credential|\.env)"
  "private-memory-split|claude-memory|codex-memory|agy-memory|private .*(repo|memory)"
  "doc-contract|doc.?contract|check-doc-truth"
  # Lane contract (#206) — the multi-agent rules from claude/MULTI-AGENT.md:
  "one-owner-worktree|one owner of the working tree"
  "adversarial-verification|verification is adversarial"
  "handoff-claim-repro|claim to disprove"
  # Two-floor grounding (#219, ADR-0006):
  "two-floor-grounding|two-floor grounding|project floor.*external floor"
)

# Markdown wraps rule sentences across lines; join indented continuation
# lines onto their bullet/paragraph start so rule-shaped phrases match
# regardless of where the 80-column wrap falls. A pattern's `.*` therefore
# spans at most one bullet, never the whole file.
unwrap() {
  awk '
    NR == 1                      { buf = $0; next }
    /^[[:space:]]+[^[:space:]]/  { sub(/^[[:space:]]+/, " "); buf = buf $0; next }
                                 { print buf; buf = $0 }
    END                          { print buf }
  ' "$1"
}
C_TEXT="$(unwrap "$CLAUDE_MD")"
A_TEXT="$(unwrap "$AGENTS_MD")"
G_TEXT="$(unwrap "$GEMINI_MD")"

fail=0
for rule in "${RULES[@]}"; do
  label="${rule%%|*}"
  pattern="${rule#*|}"
  c_hit=0; a_hit=0; g_hit=0
  grep -qiE "$pattern" <<<"$C_TEXT" && c_hit=1
  grep -qiE "$pattern" <<<"$A_TEXT" && a_hit=1
  grep -qiE "$pattern" <<<"$G_TEXT" && g_hit=1
  if [[ "$c_hit" -eq 0 || "$a_hit" -eq 0 || "$g_hit" -eq 0 ]]; then
    if [[ "$fail" -eq 0 ]]; then
      echo "✖ Agent rule parity drift — these canonical rules are missing from one side:" >&2
      echo "  (each rule must appear in ALL of $CLAUDE_MD, $AGENTS_MD, and $GEMINI_MD)" >&2
      echo "" >&2
    fi
    fail=1
    missing=""
    [[ "$c_hit" -eq 0 ]] && missing="$CLAUDE_MD"
    [[ "$a_hit" -eq 0 ]] && missing="${missing:+$missing, }$AGENTS_MD"
    [[ "$g_hit" -eq 0 ]] && missing="${missing:+$missing, }$GEMINI_MD"
    printf '  - %-22s missing from: %s\n' "$label" "$missing" >&2
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "" >&2
  echo "Add the rule to the canon source (agents/canon/) and regenerate, or extend its" >&2
  echo "phrase list in check-agent-parity.sh if a file legitimately rephrases the rule." >&2
  exit 1
fi

# --- Generation currency (ADR-0007) ------------------------------------
# The three files are build artifacts of agents/canon/. A hand-edit to any of
# them, or a canon edit without regeneration, is drift — fail CI.
GEN="$REPO_ROOT/claude/scripts/gen-instruction-files.sh"
if [[ ! -f "$GEN" ]]; then
  echo "✖ parity: missing generator $GEN (ADR-0007)" >&2
  exit 1
fi
if ! bash "$GEN" --check; then
  echo "✖ parity: generated instruction files drift from agents/canon/ sources." >&2
  exit 1
fi

echo "✓ agent-parity: all canonical rules present in CLAUDE.md, AGENTS.md, and GEMINI.md."
