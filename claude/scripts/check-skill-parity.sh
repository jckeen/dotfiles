#!/usr/bin/env bash
# check-skill-parity.sh — drift guards for the skill layer (CI + local).
#
# Three checks, all born from real drift audits found:
#
# 1. COUNT: README advertises "N slash commands", "N-agent", and
#    "N specialized" — assert EVERY occurrence of each pattern matches the
#    actual number of skill dirs under claude/skills/ and agent files under
#    claude/agents/. (README said 12 while 14 skills shipped; nothing caught
#    it. The agent count was hardcoded 8x with no guard at all, and a
#    first-match-only check would let a partial bump through.)
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

# ── 1. Skill count vs README claims (every occurrence) ─────────────
actual=$(find "$REPO_ROOT/claude/skills" -mindepth 1 -maxdepth 1 -type d | wc -l)
skill_claims=$(grep -oE '[0-9]+ slash commands' "$REPO_ROOT/README.md" | grep -oE '^[0-9]+' | sort -u || true)
if [ -z "$skill_claims" ]; then
  red "README.md no longer contains an 'N slash commands' claim — update this check or the README."
else
  skill_drift=0
  while IFS= read -r c; do
    if [ "$c" != "$actual" ]; then
      skill_drift=1
      red "README claims '$c slash commands' but claude/skills/ has $actual — update every stale count, not just the first."
    fi
  done <<<"$skill_claims"
  [ "$skill_drift" -eq 0 ] \
    && green "skill count: every README claim matches claude/skills/ ($actual)"
fi

# ── 1b. Agent count vs README "N-agent" / "N specialized" claims ───
agents_actual=$(find "$REPO_ROOT/claude/agents" -mindepth 1 -maxdepth 1 -name '*.md' | wc -l)
agent_claims=$(grep -oE '[0-9]+-agent|[0-9]+ specialized' "$REPO_ROOT/README.md" | grep -oE '^[0-9]+' | sort -u || true)
if [ -z "$agent_claims" ]; then
  red "README.md no longer contains an 'N-agent' or 'N specialized' claim — update this check or the README."
else
  agent_drift=0
  while IFS= read -r c; do
    if [ "$c" != "$agents_actual" ]; then
      agent_drift=1
      red "README claims '$c' agents (an 'N-agent' or 'N specialized' mention) but claude/agents/ has $agents_actual — update every mention, not just the first."
    fi
  done <<<"$agent_claims"
  [ "$agent_drift" -eq 0 ] \
    && green "agent count: every README claim matches claude/agents/ ($agents_actual)"
fi

# ── 1c. CLAUDE-GUIDE slash-command table vs claude/skills/ ─────────
guide="$REPO_ROOT/CLAUDE-GUIDE.md"
if [ ! -f "$guide" ]; then
  red "CLAUDE-GUIDE.md missing — its Slash Commands table is asserted against claude/skills/"
else
  # Table rows look like "| `/name …` | use |"; only rows inside the
  # "## Slash Commands" section count (other tables list /clear, cc, etc.).
  # HTML comments are stripped first so a commented-out row can't false-
  # positive: same-line "<!-- … -->" is deleted, then any remaining block
  # comment spans whole lines and the range delete removes it. A nested
  # "###"-subheading table inside the section would still be counted —
  # that fails closed (noisy, not silent), which is acceptable here.
  # The trailing "|| true" keeps the empty-table guard below reachable:
  # under pipefail a matchless grep would otherwise abort the whole script
  # with zero output.
  table_skills=$(sed -e 's#<!--.*-->##g' -e '/<!--/,/-->/d' "$guide" \
    | awk '/^## Slash Commands/{f=1; next} /^## /{f=0} f' \
    | grep -oE '^\| `/[a-z][a-z-]*' | sed 's#^| `/##' | sort -u || true)
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

# ── 2. Explicit Claude/shared-agent workflow coverage ──────────────
coverage="$REPO_ROOT/agents/skill-coverage.tsv"
if [ ! -f "$coverage" ]; then
  red "agents/skill-coverage.tsv missing — every workflow needs a shared/runtime-specific disposition"
else
  coverage_names=$(awk -F '\t' 'NF && $1 !~ /^#/ {print $1}' "$coverage" | sort)
  duplicate_names=$(printf '%s\n' "$coverage_names" | uniq -d)
  [ -z "$duplicate_names" ] \
    || red "agents/skill-coverage.tsv contains duplicate skill names: $(tr '\n' ' ' <<<"$duplicate_names")"

  claude_skills=$(find "$REPO_ROOT/claude/skills" -mindepth 1 -maxdepth 1 -type d \
    -exec basename {} \; | sort)
  shared_skills=$(find "$REPO_ROOT/agents/skills" -mindepth 1 -maxdepth 1 -type d \
    -exec basename {} \; | sort)
  all_skills=$(printf '%s\n%s\n' "$claude_skills" "$shared_skills" | sed '/^$/d' | sort -u)
  missing_coverage=$(comm -23 <(printf '%s\n' "$all_skills") <(printf '%s\n' "$coverage_names"))
  stale_coverage=$(comm -13 <(printf '%s\n' "$all_skills") <(printf '%s\n' "$coverage_names"))
  [ -z "$missing_coverage" ] \
    || red "skill(s) missing from agents/skill-coverage.tsv: $(tr '\n' ' ' <<<"$missing_coverage")"
  [ -z "$stale_coverage" ] \
    || red "agents/skill-coverage.tsv names missing skill(s): $(tr '\n' ' ' <<<"$stale_coverage")"

  while IFS=$'\t' read -r skill scope rationale; do
    [ -n "$skill" ] || continue
    [[ "$skill" == \#* ]] && continue
    case "$scope" in
      shared)
        [ -d "$REPO_ROOT/claude/skills/$skill" ] \
          || red "coverage marks '$skill' shared but claude/skills/$skill is missing"
        [ -d "$REPO_ROOT/agents/skills/$skill" ] \
          || red "coverage marks '$skill' shared but agents/skills/$skill is missing"
        ;;
      claude-only)
        [ -d "$REPO_ROOT/claude/skills/$skill" ] \
          || red "coverage marks '$skill' claude-only but its Claude skill is missing"
        [ ! -d "$REPO_ROOT/agents/skills/$skill" ] \
          || red "coverage marks '$skill' claude-only but a shared-agent skill exists"
        [ -n "$rationale" ] \
          || red "coverage marks '$skill' claude-only without a rationale"
        ;;
      agent-only)
        [ -d "$REPO_ROOT/agents/skills/$skill" ] \
          || red "coverage marks '$skill' agent-only but its shared-agent skill is missing"
        [ ! -d "$REPO_ROOT/claude/skills/$skill" ] \
          || red "coverage marks '$skill' agent-only but a Claude skill exists"
        [ -n "$rationale" ] \
          || red "coverage marks '$skill' agent-only without a rationale"
        ;;
      *) red "agents/skill-coverage.tsv has invalid scope '$scope' for '$skill'" ;;
    esac
  done < "$coverage"

  [ "$VIOLATIONS" -eq 0 ] \
    && green "workflow coverage: every Claude/shared-agent skill has an explicit disposition"
fi

# ── 3. Cross-tool artifact shape (changelog + handoff) ─────────────
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
# "Operator-action queue" is a skill-body section, not an artifact heading, but
# both sides must carry it so the queue contract can't drift one-sided (#213).
require_headings handoff "What we did" "Where we left off" "Key decisions made" \
  "Open issues" "Next steps" "Context for next session" "Operator-action queue"

[ "$VIOLATIONS" -eq 0 ] && green "artifact shapes: changelog + handoff headings match across Claude/shared agents"

if [ "$VIOLATIONS" -ne 0 ]; then
  echo ""
  echo "skill-parity: FAILED — see [ERR] lines above."
  exit 1
fi
echo "skill-parity: OK"
