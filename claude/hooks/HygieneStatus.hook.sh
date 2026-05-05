#!/usr/bin/env bash
# SessionStart hook: surface branch-hygiene drift if the daily systemd timer
# detected any. Reads the cached state file written by hygiene-cron.sh — does
# NOT call the network. Designed to be <50ms.
#
# Triggers a <system-reminder> only when:
#   - drift_count > 0 (one or more repos out of compliance), OR
#   - the state file is older than 48h (timer hasn't run; check is stale)
#
# Otherwise silent (exit 0 with no output).

set -uo pipefail

STATE_FILE="$HOME/.claude/state/hygiene-status.json"
STALE_HOURS=48

# State file missing entirely — likely first run before timer fires; stay silent.
if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

# Need jq to parse JSON; if not present, fail quietly.
command -v jq >/dev/null 2>&1 || exit 0

drift_count=$(jq -r '.drift_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)
checked_at=$(jq -r '.checked_at // empty' "$STATE_FILE" 2>/dev/null || echo "")

# Compute staleness in hours
stale_hours=0
if [[ -n "$checked_at" ]]; then
  checked_epoch=$(date -d "$checked_at" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  if [[ "$checked_epoch" -gt 0 ]]; then
    stale_hours=$(( (now_epoch - checked_epoch) / 3600 ))
  fi
fi

# Quiet path: clean and fresh
if [[ "$drift_count" -eq 0 && "$stale_hours" -lt "$STALE_HOURS" ]]; then
  exit 0
fi

# Build a minimal system-reminder
{
  echo "<system-reminder>"
  echo "## Branch hygiene status"
  echo
  if [[ "$drift_count" -gt 0 ]]; then
    repos=$(jq -r '.drifted_repos[]?' "$STATE_FILE" 2>/dev/null | paste -sd ', ')
    echo "$drift_count repo(s) drifted from canonical auto-hygiene settings: $repos"
    echo "Suggest mentioning to user, then running: gh-bootstrap.sh --all ~/dev"
  fi
  if [[ "$stale_hours" -ge "$STALE_HOURS" ]]; then
    echo "Hygiene check is stale ($stale_hours h old, threshold ${STALE_HOURS}h). Timer may not be running — check: systemctl --user status git-hygiene.timer"
  fi
  echo "</system-reminder>"
} 2>/dev/null

exit 0
