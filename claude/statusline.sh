#!/usr/bin/env bash
# Claude Code status line — optimized for parallel worktree workflows
# Shows: model | context bar | git branch | lines changed | cost | worktree
set -euo pipefail

# Bail gracefully if jq isn't installed
if ! command -v jq &>/dev/null; then echo "?"; exit 0; fi

input=$(cat)

# --- Parse JSON ---
MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
ADDED=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
REMOVED=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
WORKTREE=$(echo "$input" | jq -r '.worktree.name // empty')
VIM_MODE=$(echo "$input" | jq -r '.vim.mode // empty')

# --- Colors ---
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
DIM='\033[2m'
RESET='\033[0m'

# --- Context bar (10 chars) ---
BAR_WIDTH=10
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
BAR=""
if [ "$FILLED" -gt 0 ]; then
  printf -v FILL "%${FILLED}s"
  BAR="${FILL// /▓}"
fi
if [ "$EMPTY" -gt 0 ]; then
  printf -v PAD "%${EMPTY}s"
  BAR="${BAR}${PAD// /░}"
fi

if [ "$PCT" -ge 80 ]; then
  BAR_COLOR="$RED"
elif [ "$PCT" -ge 50 ]; then
  BAR_COLOR="$YELLOW"
else
  BAR_COLOR="$GREEN"
fi

# --- Git branch (cached 5s to avoid lag) ---
CACHE_FILE="/tmp/.claude-statusline-git-$(echo "$PWD" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "default")"
BRANCH=""
NOW=$(date +%s)
if [ -f "$CACHE_FILE" ]; then
  # BSD stat (macOS) uses -f %m, GNU stat (Linux) uses -c %Y
  CACHE_AGE=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  if [ $((NOW - CACHE_AGE)) -lt 5 ]; then
    BRANCH=$(cat "$CACHE_FILE")
  fi
fi
if [ -z "$BRANCH" ]; then
  BRANCH=$(git branch --show-current 2>/dev/null || true)
  echo "$BRANCH" > "$CACHE_FILE" 2>/dev/null || true
fi

# --- Build output ---
LINE=""

# Vim mode indicator
[ -n "$VIM_MODE" ] && LINE="${LINE}${DIM}${VIM_MODE}${RESET} "

# Model name (dimmed — it's context, not the focus)
LINE="${LINE}${DIM}${MODEL}${RESET}"

# Context usage bar — the thing you need to watch most
LINE="${LINE} ${BAR_COLOR}${BAR}${RESET} ${PCT}%"

# Git branch
[ -n "$BRANCH" ] && LINE="${LINE}  ${CYAN}${BRANCH}${RESET}"

# Worktree name — critical when running 3-5 parallel sessions
[ -n "$WORKTREE" ] && LINE="${LINE} ${DIM}[wt:${WORKTREE}]${RESET}"

# Lines changed this session
LINE="${LINE}  ${GREEN}+${ADDED}${RESET}/${RED}-${REMOVED}${RESET}"

# Session cost
COST_FMT=$(printf '$%.2f' "$COST")
LINE="${LINE}  ${DIM}${COST_FMT}${RESET}"

# Context warning on second line when getting full
if [ "$PCT" -ge 80 ]; then
  printf '%b\n' "$LINE"
  printf '%b' "${RED}⚠ Context ${PCT}% full — consider /clear or /handoff${RESET}"
else
  printf '%b' "$LINE"
fi
