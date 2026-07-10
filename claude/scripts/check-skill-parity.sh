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
# 2. ARTIFACT SHAPE: the Claude and shared-agent (agents/skills, consumed by
#    Codex + Antigravity) changelog/handoff skills must emit identically-shaped
#    artifacts (same section headings), or cross-tool session resume breaks.
#    Assert the required headings appear in BOTH sides of each pair. (The
#    pairs had drifted to different heading sets.)
#
# 3. GUIDE TABLE: CLAUDE-GUIDE.md's "## Slash Commands" table must list exactly
#    the skill dirs under claude/skills/ — no more, no less. (The table had
#    drifted: it omitted /antigravity-review and listed the built-in /verify;
#    only README's count was asserted, so nothing caught it — issue #210.)
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

# ── 1c. CLAUDE-GUIDE slash-command table vs claude/skills/ ─────────
guide="$REPO_ROOT/CLAUDE-GUIDE.md"
if [ ! -f "$guide" ]; then
  red "CLAUDE-GUIDE.md missing — its Slash Commands table is asserted against claude/skills/"
else
  # Table rows look like "| `/name …` | use |"; only rows inside the
  # "## Slash Commands" section count (other tables list /clear, cc, etc.).
  table_skills=$(awk '/^## Slash Commands/{f=1; next} /^## /{f=0} f' "$guide" \
    | grep -oE '^\| `/[a-z][a-z-]*' | sed 's#^| `/##' | sort -u)
  dir_skills=$(find "$REPO_ROOT/claude/skills" -mindepth 1 -maxdepth 1 -type d \
    -exec basename {} \; | sort)
  if [ -z "$table_skills" ]; then
    red "CLAUDE-GUIDE.md has no parseable '## Slash Commands' table — update this check or the guide."
  else
    guide_drift=0
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      guide_drift=1
      red "skill '/$s' exists in claude/skills/ but is missing from CLAUDE-GUIDE.md's Slash Commands table"
    done < <(comm -23 <(printf '%s\n' "$dir_skills") <(printf '%s\n' "$table_skills"))
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      guide_drift=1
      red "CLAUDE-GUIDE.md's Slash Commands table lists '/$s' but claude/skills/$s/ does not exist (built-ins don't belong in the table)"
    done < <(comm -13 <(printf '%s\n' "$dir_skills") <(printf '%s\n' "$table_skills"))
    [ "$guide_drift" -eq 0 ] \
      && green "guide table: CLAUDE-GUIDE.md Slash Commands table matches claude/skills/ exactly"
  fi
fi

# ── 2. Cross-tool artifact shape (changelog + handoff) ─────────────
require_headings() {
  local skill="$1"; shift
  local side file h
  for side in claude agents; do
    file="$REPO_ROOT/$side/skills/$skill/SKILL.md"
    if [ ! -f "$file" ]; then
      red "$side/skills/$skill/SKILL.md missing"
      continue
    fi
    for h in "$@"; do
      grep -qF "### $h" "$file" \
        || red "$side/skills/$skill/SKILL.md missing heading '### $h' — Claude and shared-agent artifacts must match"
    done
  done
}

require_headings changelog "What changed" "Decisions made" "Known issues"
require_headings handoff "What we did" "Where we left off" "Key decisions made" \
  "Open issues" "Next steps" "Context for next session"

[ "$VIOLATIONS" -eq 0 ] && green "artifact shapes: changelog + handoff headings match across Claude/shared agents"

if [ "$VIOLATIONS" -ne 0 ]; then
  echo ""
  echo "skill-parity: FAILED — see [ERR] lines above."
  exit 1
fi
echo "skill-parity: OK"
