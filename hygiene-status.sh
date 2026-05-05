#!/usr/bin/env bash
# hygiene-status — read cached branch-hygiene state and emit it in one of
# three formats. Used by Claude SessionStart hook, the cc/cx shell wrappers,
# and on-demand from the CLI. Reads only — never calls the network.
#
# Usage:
#   hygiene-status               # (default) human plain text, silent if clean+fresh
#   hygiene-status --reminder    # wrap in <system-reminder> for Claude hooks
#   hygiene-status --cli         # color CLI output for cc/cx, silent if clean+fresh
#   hygiene-status --json        # raw cached JSON (always emits)
#   hygiene-status --status      # short one-line status (always emits)
#
# State file: $HOME/.local/state/hygiene/status.json
#   (written by claude/scripts/hygiene-cron.sh, fired by git-hygiene.timer)

set -uo pipefail

STATE_FILE="$HOME/.local/state/hygiene/status.json"
STALE_HOURS=48
MODE="${1:-text}"

# Map flag aliases to mode names
case "$MODE" in
  --reminder|reminder) MODE=reminder ;;
  --cli|cli)           MODE=cli ;;
  --json|json)         MODE=json ;;
  --status|status)     MODE=status ;;
  --text|text|"")      MODE=text ;;
  -h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *)
    echo "hygiene-status: unknown mode '$MODE'" >&2
    exit 2 ;;
esac

# State file missing — silent except in modes that always emit
if [[ ! -f "$STATE_FILE" ]]; then
  case "$MODE" in
    json)   echo '{"error":"state file not found"}' ;;
    status) echo "no-data" ;;
  esac
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

drift_count=$(jq -r '.drift_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)
checked_at=$(jq -r '.checked_at // empty' "$STATE_FILE" 2>/dev/null || echo "")
mapfile -t drifted_repos < <(jq -r '.drifted_repos[]?' "$STATE_FILE" 2>/dev/null)

# Compute staleness
stale_hours=0
if [[ -n "$checked_at" ]]; then
  checked_epoch=$(date -d "$checked_at" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  if [[ "$checked_epoch" -gt 0 ]]; then
    stale_hours=$(( (now_epoch - checked_epoch) / 3600 ))
  fi
fi

is_stale=0
[[ "$stale_hours" -ge "$STALE_HOURS" ]] && is_stale=1

is_drifted=0
[[ "$drift_count" -gt 0 ]] && is_drifted=1

# JSON / status modes always emit, regardless of cleanliness
case "$MODE" in
  json)
    cat "$STATE_FILE"
    exit 0 ;;
  status)
    if [[ "$is_drifted" -eq 1 ]]; then
      echo "drifted: $drift_count"
    elif [[ "$is_stale" -eq 1 ]]; then
      echo "stale: ${stale_hours}h"
    else
      echo "clean (checked ${stale_hours}h ago)"
    fi
    exit 0 ;;
esac

# Quiet path for text/reminder/cli — silent when clean and fresh
if [[ "$is_drifted" -eq 0 && "$is_stale" -eq 0 ]]; then
  exit 0
fi

# Compose body lines
body=()
if [[ "$is_drifted" -eq 1 ]]; then
  repos_csv=$(printf '%s, ' "${drifted_repos[@]}" | sed 's/, $//')
  body+=("$drift_count repo(s) drifted from canonical auto-hygiene settings: $repos_csv")
  body+=("Run: gh-bootstrap.sh --all ~/dev")
fi
if [[ "$is_stale" -eq 1 ]]; then
  body+=("Hygiene check is stale (${stale_hours}h old, threshold ${STALE_HOURS}h). Daily timer may be down — check: systemctl --user status git-hygiene.timer")
fi

case "$MODE" in
  reminder)
    echo "<system-reminder>"
    echo "## Branch hygiene status"
    echo
    for line in "${body[@]}"; do echo "$line"; done
    echo "</system-reminder>"
    ;;
  cli)
    # Color codes
    yellow=$'\033[33m'; reset=$'\033[0m'
    echo "${yellow}⚠ Branch hygiene${reset}"
    for line in "${body[@]}"; do
      echo "  $line"
    done
    ;;
  text)
    echo "Branch hygiene status:"
    for line in "${body[@]}"; do echo "  $line"; done
    ;;
esac

exit 0
