#!/usr/bin/env bash
# Claude Code status line — multi-line with GitHub links and git status
# Line 1: model | context bar | tokens | session
# Line 2: repo link | branch | git status indicators | worktree

# No set -e — statusline must never silently die
set -o pipefail

# Bail gracefully if jq isn't installed
if ! command -v jq &>/dev/null; then echo "?"; exit 0; fi

input=$(cat)

# --- Parse JSON (single jq call for performance) ---
eval "$(echo "$input" | jq -r '
  @sh "MODEL=\(.model.display_name // "?")",
  @sh "PCT=\(.context_window.used_percentage // 0 | floor)",
  @sh "IN_TOK=\(.context_window.total_input_tokens // 0)",
  @sh "OUT_TOK=\(.context_window.total_output_tokens // 0)",
  @sh "WIN_SIZE=\(.context_window.context_window_size // 0)",
  @sh "WORKTREE=\(.worktree.name // "")",
  @sh "WT_BRANCH=\(.worktree.branch // "")",
  @sh "VIM_MODE=\(.vim.mode // "")",
  @sh "SESSION=\(.session_name // "")",
  @sh "CWD=\(.cwd // "")",
  @sh "VERSION=\(.version // "")"
' 2>/dev/null)" 2>/dev/null || {
  echo "?"; exit 0
}

# Ensure PCT is numeric
PCT="${PCT:-0}"
[[ "$PCT" =~ ^[0-9]+$ ]] || PCT=0

# --- Colors ---
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
BLUE='\033[34m'
MAGENTA='\033[35m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# --- OSC 8 clickable link helper ---
# Usage: link URL TEXT
link() {
  printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"
}

# --- Context bar (12 chars, finer granularity) ---
BAR_WIDTH=12
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

# --- Token count formatting ---
fmt_tokens() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    printf '%s.%sM' "$((n / 1000000))" "$((n % 1000000 / 100000))"
  elif [ "$n" -ge 1000 ]; then
    printf '%s.%sk' "$((n / 1000))" "$((n % 1000 / 100))"
  else
    printf '%s' "$n"
  fi
}

# --- Git info (cached 5s) ---
CACHE_DIR="/tmp/.claude-statusline"
mkdir -p "$CACHE_DIR" 2>/dev/null || true
CACHE_KEY=$(echo "$PWD" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "default")
CACHE_FILE="${CACHE_DIR}/${CACHE_KEY}"
NOW=$(date +%s)
NEED_REFRESH=1

if [ -f "$CACHE_FILE" ]; then
  CACHE_AGE=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  if [ $((NOW - CACHE_AGE)) -lt 5 ]; then
    NEED_REFRESH=0
  fi
fi

IN_GIT_REPO=0
if [ "$NEED_REFRESH" -eq 1 ] && git rev-parse --is-inside-work-tree &>/dev/null; then
  IN_GIT_REPO=1
  # Gather all git info in one shot
  BRANCH=$(git branch --show-current 2>/dev/null || true)
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)

  # Git status counts
  STAGED=0; MODIFIED=0; UNTRACKED=0; CONFLICTS=0
  while IFS= read -r status_line; do
    case "${status_line:0:2}" in
      "UU"|"AA"|"DD") ((CONFLICTS++)) ;;
      "? "|"??")      ((UNTRACKED++)) ;;
      " M"|" D"|" R") ((MODIFIED++)) ;;
      *)
        [[ "${status_line:0:1}" =~ [MADRC] ]] && ((STAGED++))
        [[ "${status_line:1:1}" =~ [MD] ]] && ((MODIFIED++))
        ;;
    esac
  done < <(git status --porcelain 2>/dev/null || true)

  # Ahead/behind
  AHEAD=0; BEHIND=0
  if upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    read -r AHEAD BEHIND < <(git rev-list --left-right --count HEAD..."$upstream" 2>/dev/null || echo "0 0")
  fi

  # Stash count
  STASH_COUNT=$(git stash list 2>/dev/null | wc -l)

  # Write cache
  cat > "$CACHE_FILE" 2>/dev/null <<CACHE_EOF
BRANCH=${BRANCH}
REMOTE_URL=${REMOTE_URL}
STAGED=${STAGED}
MODIFIED=${MODIFIED}
UNTRACKED=${UNTRACKED}
CONFLICTS=${CONFLICTS}
AHEAD=${AHEAD}
BEHIND=${BEHIND}
STASH_COUNT=${STASH_COUNT}
IN_GIT_REPO=1
CACHE_EOF
elif [ -f "$CACHE_FILE" ]; then
  source "$CACHE_FILE" 2>/dev/null || true
  IN_GIT_REPO=1
fi

# If we just refreshed, vars are already set; if we sourced, they're loaded
if [ "$NEED_REFRESH" -ne 1 ] && [ -f "$CACHE_FILE" ]; then
  source "$CACHE_FILE" 2>/dev/null || true
  IN_GIT_REPO=1
fi

# Defaults for non-git directories
BRANCH="${BRANCH:-}"
REMOTE_URL="${REMOTE_URL:-}"
STAGED="${STAGED:-0}"
MODIFIED="${MODIFIED:-0}"
UNTRACKED="${UNTRACKED:-0}"
CONFLICTS="${CONFLICTS:-0}"
AHEAD="${AHEAD:-0}"
BEHIND="${BEHIND:-0}"
STASH_COUNT="${STASH_COUNT:-0}"

# --- Parse GitHub URL for clickable link ---
GITHUB_URL=""
REPO_NAME=""
if [ "$IN_GIT_REPO" -eq 1 ] && [ -n "$REMOTE_URL" ]; then
  # Handle SSH (git@github.com:user/repo.git) and HTTPS
  CLEAN_URL="${REMOTE_URL%.git}"
  if [[ "$CLEAN_URL" =~ github\.com[:/](.+) ]]; then
    REPO_SLUG="${BASH_REMATCH[1]}"
    GITHUB_URL="https://github.com/${REPO_SLUG}"
    REPO_NAME="${REPO_SLUG##*/}"
  else
    # Non-GitHub remote — just show repo name
    REPO_NAME=$(basename "$CLEAN_URL")
  fi
fi

# =============================================
# LINE 1: Model | Context | Tokens | Session
# =============================================
L1=""

# Vim mode
[ -n "${VIM_MODE:-}" ] && L1="${L1}${BOLD}${VIM_MODE}${RESET} "

# Model (dimmed)
L1="${L1}${DIM}${MODEL}${RESET}"

# Context bar
L1="${L1} ${BAR_COLOR}${BAR}${RESET} ${PCT}%"

# Token counts
IN_FMT=$(fmt_tokens "${IN_TOK:-0}")
OUT_FMT=$(fmt_tokens "${OUT_TOK:-0}")
L1="${L1}  ${DIM}↑${OUT_FMT} ↓${IN_FMT}${RESET}"

# Session name
[ -n "${SESSION:-}" ] && L1="${L1}  ${MAGENTA}${SESSION}${RESET}"

# Version (far right, very dim)
[ -n "${VERSION:-}" ] && L1="${L1}  ${DIM}v${VERSION}${RESET}"

# =============================================
# LINE 2: Repo | Branch | Git status | Worktree
# =============================================
L2=""

# Repo name (clickable link to GitHub if available)
if [ -n "$REPO_NAME" ]; then
  if [ -n "$GITHUB_URL" ]; then
    REPO_LINK=$(link "$GITHUB_URL" "$REPO_NAME")
    L2="${L2}${BLUE}${REPO_LINK}${RESET}"
  else
    L2="${L2}${BLUE}${REPO_NAME}${RESET}"
  fi
fi

# Branch (clickable to branch on GitHub)
if [ -n "$BRANCH" ]; then
  [ -n "$L2" ] && L2="${L2} ${DIM}/${RESET} "
  if [ -n "$GITHUB_URL" ]; then
    BRANCH_LINK=$(link "${GITHUB_URL}/tree/${BRANCH}" "$BRANCH")
    L2="${L2}${CYAN}${BRANCH_LINK}${RESET}"
  else
    L2="${L2}${CYAN}${BRANCH}${RESET}"
  fi
fi

# Git status indicators (only in git repos)
if [ "$IN_GIT_REPO" -eq 1 ]; then
  STATUS_PARTS=""
  [ "$STAGED" -gt 0 ]    && STATUS_PARTS="${STATUS_PARTS} ${GREEN}●${STAGED}${RESET}"
  [ "$MODIFIED" -gt 0 ]  && STATUS_PARTS="${STATUS_PARTS} ${YELLOW}●${MODIFIED}${RESET}"
  [ "$UNTRACKED" -gt 0 ] && STATUS_PARTS="${STATUS_PARTS} ${RED}●${UNTRACKED}${RESET}"
  [ "$CONFLICTS" -gt 0 ] && STATUS_PARTS="${STATUS_PARTS} ${RED}✖${CONFLICTS}${RESET}"

  # Ahead/behind
  [ "$AHEAD" -gt 0 ]  && STATUS_PARTS="${STATUS_PARTS} ${GREEN}↑${AHEAD}${RESET}"
  [ "$BEHIND" -gt 0 ] && STATUS_PARTS="${STATUS_PARTS} ${RED}↓${BEHIND}${RESET}"

  # Stashes
  [ "$STASH_COUNT" -gt 0 ] && STATUS_PARTS="${STATUS_PARTS} ${DIM}⚑${STASH_COUNT}${RESET}"

  # Clean indicator
  if [ "$STAGED" -eq 0 ] && [ "$MODIFIED" -eq 0 ] && [ "$UNTRACKED" -eq 0 ] && [ "$CONFLICTS" -eq 0 ]; then
    STATUS_PARTS=" ${GREEN}✓${RESET}"
  fi

  [ -n "$STATUS_PARTS" ] && L2="${L2} ${STATUS_PARTS}"
fi

# Worktree indicator
[ -n "${WORKTREE:-}" ] && L2="${L2}  ${DIM}[wt:${WORKTREE}]${RESET}"

# =============================================
# OUTPUT
# =============================================
printf '%b\n' "$L1"

# Only show line 2 if we have git info
if [ -n "$L2" ]; then
  printf '%b' "$L2"
else
  printf '%b' "${DIM}(no git repo)${RESET}"
fi

# Context warning on third line when getting full
if [ "$PCT" -ge 80 ]; then
  printf '\n%b' "${RED}⚠ Context ${PCT}% full — consider /clear or /handoff${RESET}"
fi
