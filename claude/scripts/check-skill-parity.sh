#!/usr/bin/env bash
# check-skill-parity.sh — drift guards for the skill layer (CI + local).
#
# Two checks, both born from real drift the 2026-06 audit found:
#
# 1. COUNT: README advertises "N slash commands" and "N-agent" — assert each N
#    matches the actual number of skill dirs under claude/skills/ and agent
#    files under claude/agents/. (README said 12 while 14 skills shipped;
#    nothing caught it. The agent count was hardcoded 8x with no guard at all.)
#
# 2. ARTIFACT SHAPE: the Claude and Codex changelog/handoff skills must emit
#    identically-shaped artifacts (same section headings), or cross-tool
#    session resume breaks. Assert the required headings appear in BOTH sides
#    of each pair. (The pairs had drifted to different heading sets.)
#
# Usage: check-skill-parity.sh        exit 1 on any drift

set -euo pipefail

# Shared helpers (resolve_script_path, checker_repo_root, red/green + the
# VIOLATIONS counter that red() bumps) live beside this script in checker-lib.sh.
# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
REPO_ROOT="$(checker_repo_root "${BASH_SOURCE[0]}")"

# ── 1. Skill count vs README claim ─────────────────────────────────
actual=$(find "$REPO_ROOT/claude/skills" -mindepth 1 -maxdepth 1 -type d | wc -l)
claimed=$(grep -oE '[0-9]+ slash commands' "$REPO_ROOT/README.md" | head -1 | grep -oE '^[0-9]+' || echo "")
if [ -z "$claimed" ]; then
  red "README.md no longer contains an 'N slash commands' claim — update this check or the README."
elif [ "$claimed" != "$actual" ]; then
  red "README claims '$claimed slash commands' but claude/skills/ has $actual — update the README count and table."
else
  green "skill count: README claim ($claimed) matches claude/skills/ ($actual)"
fi

# ── 1b. Agent count vs README "N-agent" claim ──────────────────────
agents_actual=$(find "$REPO_ROOT/claude/agents" -mindepth 1 -maxdepth 1 -name '*.md' | wc -l)
agents_claimed=$(grep -oE '[0-9]+-agent' "$REPO_ROOT/README.md" | head -1 | grep -oE '^[0-9]+' || echo "")
if [ -z "$agents_claimed" ]; then
  red "README.md no longer contains an 'N-agent' claim — update this check or the README."
elif [ "$agents_claimed" != "$agents_actual" ]; then
  red "README claims '$agents_claimed-agent' but claude/agents/ has $agents_actual — update every '$agents_claimed-agent' mention."
else
  green "agent count: README claim ($agents_claimed) matches claude/agents/ ($agents_actual)"
fi

# ── 2. Cross-tool artifact shape (changelog + handoff) ─────────────
require_headings() {
  local skill="$1"; shift
  local side file h
  for side in claude codex; do
    file="$REPO_ROOT/$side/skills/$skill/SKILL.md"
    if [ ! -f "$file" ]; then
      red "$side/skills/$skill/SKILL.md missing"
      continue
    fi
    for h in "$@"; do
      grep -qF "### $h" "$file" \
        || red "$side/skills/$skill/SKILL.md missing heading '### $h' — Claude/Codex artifacts must match"
    done
  done
}

require_headings changelog "What changed" "Decisions made" "Known issues"
require_headings handoff "What we did" "Where we left off" "Key decisions made" \
  "Open issues" "Next steps" "Context for next session"

[ "$VIOLATIONS" -eq 0 ] && green "artifact shapes: changelog + handoff headings match across Claude/Codex"

if [ "$VIOLATIONS" -ne 0 ]; then
  echo ""
  echo "skill-parity: FAILED — see [ERR] lines above."
  exit 1
fi
echo "skill-parity: OK"
