#!/usr/bin/env bash
# Claude Code status line — multi-line with GitHub links and git status
# Line 1: model | context bar | tokens | session
# Line 2: repo link | branch | git status indicators | worktree

# No set -e — statusline must never silently die
set -o pipefail

# Bail gracefully if jq isn't installed
if ! command -v jq &>/dev/null; then echo "?"; exit 0; fi

input=$(cat)

# --- Parse JSON (single jq call, one field per line to preserve empties) ---
readarray -t _fields < <(echo "$input" | jq -r '
  (.model.display_name // "?"),
  (.context_window.used_percentage // 0 | floor | tostring),
  (.context_window.total_input_tokens // 0 | tostring),
  (.context_window.total_output_tokens // 0 | tostring),
  (.context_window.context_window_size // 0 | tostring),
  (.worktree.name // ""),
  (.worktree.branch // ""),
  (.vim.mode // ""),
  (.session_name // ""),
  (.cwd // ""),
  (.version // ""),
  (.session_id // ""),
  (.cost.total_cost_usd // 0 | tostring),
  (.cost.total_duration_ms // 0 | tostring),
  (.cost.total_lines_added // 0 | tostring),
  (.cost.total_lines_removed // 0 | tostring),
  (.transcript_path // "")
' 2>/dev/null) || { echo "?"; exit 0; }

MODEL="${_fields[0]}"
PCT="${_fields[1]}"
IN_TOK="${_fields[2]}"
OUT_TOK="${_fields[3]}"
# shellcheck disable=SC2034  # unused, kept so the _fields index map stays complete
WIN_SIZE="${_fields[4]}"
WORKTREE="${_fields[5]}"
# shellcheck disable=SC2034  # unused, kept so the _fields index map stays complete
WT_BRANCH="${_fields[6]}"
VIM_MODE="${_fields[7]}"
SESSION="${_fields[8]}"
CWD="${_fields[9]}"
VERSION="${_fields[10]}"
SESSION_ID="${_fields[11]}"
COST_USD="${_fields[12]}"
DUR_MS="${_fields[13]}"
LINES_ADD="${_fields[14]}"
LINES_DEL="${_fields[15]}"
TRANSCRIPT="${_fields[16]}"

# Switch to the project CWD so git operations reflect the right repo
if [ -n "${CWD:-}" ] && [ -d "$CWD" ]; then
  # || true: statusline must never die — on cd failure keep rendering from the current dir
  cd "$CWD" || true
fi

# Ensure PCT is numeric
PCT="${PCT:-0}"
[[ "$PCT" =~ ^[0-9]+$ ]] || PCT=0

# --- Colors (raw escape bytes so we can use printf %s safely) ---
ESC=$'\033'
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
RED="${ESC}[31m"
CYAN="${ESC}[36m"
BLUE="${ESC}[34m"
MAGENTA="${ESC}[35m"
DIM="${ESC}[2m"
BOLD="${ESC}[1m"
RESET="${ESC}[0m"

# --- OSC 8 clickable link helper ---
# Usage: link URL TEXT
link() {
  printf '%s]8;;%s%s\\%s%s]8;;%s\\' "$ESC" "$1" "$ESC" "$2" "$ESC" "$ESC"
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
CACHE_DIR="${XDG_RUNTIME_DIR:-${HOME}/.cache}/claude-statusline"
mkdir -p "$CACHE_DIR" 2>/dev/null || true
CACHE_KEY=$(echo "$PWD" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "default")
CACHE_FILE="${CACHE_DIR}/${CACHE_KEY}"
printf -v NOW '%(%s)T' -1
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

  # Write cache (tab-delimited data, no executable code)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$BRANCH" "$REMOTE_URL" "$STAGED" "$MODIFIED" "$UNTRACKED" \
    "$CONFLICTS" "$AHEAD" "$BEHIND" "$STASH_COUNT" \
    > "$CACHE_FILE" 2>/dev/null
elif [ -f "$CACHE_FILE" ]; then
  IFS=$'\t' read -r BRANCH REMOTE_URL STAGED MODIFIED UNTRACKED CONFLICTS AHEAD BEHIND STASH_COUNT < "$CACHE_FILE" 2>/dev/null || true
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

# --- Per-repo color (from .claude-color file) ---
REPO_COLOR=""
REPO_COLOR_HEX=""
if [ -n "${CWD:-}" ] && [ -f "${CWD}/.claude-color" ]; then
  REPO_COLOR_HEX=$(head -1 "${CWD}/.claude-color" 2>/dev/null | tr -d '[:space:]#')
elif [ -f ".claude-color" ]; then
  REPO_COLOR_HEX=$(head -1 ".claude-color" 2>/dev/null | tr -d '[:space:]#')
fi
if [[ "${REPO_COLOR_HEX:-}" =~ ^[0-9a-fA-F]{6}$ ]]; then
  # Convert hex to true color escape
  R=$((16#${REPO_COLOR_HEX:0:2}))
  G=$((16#${REPO_COLOR_HEX:2:2}))
  B=$((16#${REPO_COLOR_HEX:4:2}))
  REPO_COLOR="${ESC}[38;2;${R};${G};${B}m"
fi

# --- Running agents (subagent transcripts written to in the last minute) ---
AGENTS=0
if [ -n "${TRANSCRIPT:-}" ]; then
  SUBAGENT_DIR="${TRANSCRIPT%.jsonl}/subagents"
  if [ -d "$SUBAGENT_DIR" ]; then
    AGENTS=$(find "$SUBAGENT_DIR" -name 'agent-*.jsonl' -mmin -1 2>/dev/null | wc -l)
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

# Running agents
[ "${AGENTS:-0}" -gt 0 ] && L1="${L1}  ${CYAN}${BOLD}⚙${AGENTS} agent$([ "$AGENTS" -gt 1 ] && echo s)${RESET}"

# Lines changed this session
if [ "${LINES_ADD:-0}" != "0" ] || [ "${LINES_DEL:-0}" != "0" ]; then
  L1="${L1}  ${GREEN}+${LINES_ADD}${RESET} ${RED}-${LINES_DEL}${RESET}"
fi

# Session cost (and ledger — one tiny file per session, aggregated by the
# `ledger` shell function; ~/.claude/ledger/ is machine-local, never tracked)
if [ -n "${COST_USD:-}" ] && [ "$COST_USD" != "0" ]; then
  COST_FMT=$(LC_NUMERIC=C printf '%.2f' "$COST_USD" 2>/dev/null || echo "$COST_USD")
  L1="${L1}  ${DIM}\$${COST_FMT}${RESET}"
  if [ -n "${SESSION_ID:-}" ]; then
    LEDGER_DIR="$HOME/.claude/ledger"
    mkdir -p "$LEDGER_DIR" 2>/dev/null || true
    printf '%(%Y-%m-%d)T\t%s\t%s\t%s\n' -1 "$(basename "$PWD")" "$COST_USD" "$(( ${DUR_MS:-0} / 60000 ))" \
      > "$LEDGER_DIR/${SESSION_ID}.tsv" 2>/dev/null || true
  fi
fi

# Version (far right, very dim)
[ -n "${VERSION:-}" ] && L1="${L1}  ${DIM}v${VERSION}${RESET}"

# =============================================
# LINE 2: Repo | Branch | Git status | Worktree
# =============================================
L2=""

# Working directory (~-abbreviated, bold blue like the bash PS1)
if [ -n "${CWD:-}" ]; then
  DISP_CWD="$CWD"
  case "$DISP_CWD" in
    "$HOME") DISP_CWD="~" ;;
    "$HOME"/*) DISP_CWD="~${DISP_CWD#"$HOME"}" ;;
  esac
  L2="${ESC}[01;34m${DISP_CWD}${RESET}"
fi

# Repo name (clickable link to GitHub, colored per project)
REPO_NAME_COLOR="${REPO_COLOR:-$BLUE}"
if [ -n "$REPO_NAME" ]; then
  [ -n "$L2" ] && L2="${L2}  ${DIM}·${RESET}  "
  if [ -n "$GITHUB_URL" ]; then
    REPO_LINK=$(link "$GITHUB_URL" "$REPO_NAME")
    L2="${L2}${REPO_NAME_COLOR}${BOLD}${REPO_LINK}${RESET}"
  else
    L2="${L2}${REPO_NAME_COLOR}${BOLD}${REPO_NAME}${RESET}"
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
printf '%s\n' "$L1"

# Only show line 2 if we have git info
if [ -n "$L2" ]; then
  printf '%s' "$L2"
else
  printf '%s' "${DIM}(no git repo)${RESET}"
fi

# Context warning on third line when getting full
if [ "$PCT" -ge 80 ]; then
  printf '\n%s' "${RED}⚠ Context ${PCT}% full — consider /clear or /handoff${RESET}"
fi
