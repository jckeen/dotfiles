#!/usr/bin/env bash
# hygiene-cron — daily systemd-fired wrapper that:
#   1. Runs `gh-bootstrap --check --all ~/dev`, writes JSON status for hooks
#   2. On Sundays, also runs `git-hygiene clean ~/dev --yes`
#
# Triggered by git-hygiene.timer. Logs to ~/.local/share/git-hygiene/cron.log.

set -uo pipefail

DEV_DIR="${HYGIENE_DEV_DIR:-$HOME/dev}"
# State file is XDG-neutral (not under ~/.claude/) so Codex/Claude/CLI all share one source
STATE_FILE="$HOME/.local/state/hygiene/status.json"
LOG_DIR="$HOME/.local/state/hygiene"
LOG_FILE="$LOG_DIR/cron.log"
SCRIPT_DIR="$DEV_DIR/dotfiles"

mkdir -p "$LOG_DIR"

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Append all output to the log file
exec >>"$LOG_FILE" 2>&1
echo
echo "═══ hygiene-cron $(now_iso) ═══"

# Layer A — daily drift check
echo "── gh-bootstrap --check --all $DEV_DIR ──"
check_output=$("$SCRIPT_DIR/gh-bootstrap.sh" --check --all "$DEV_DIR" 2>&1 || true)
echo "$check_output"

# Parse output for drifted repos (lines containing "drift:")
mapfile -t drifted < <(echo "$check_output" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | grep -E ' — [0-9]+ drift:' | awk -F' — ' '{print $1}' | sed 's/^[^A-Za-z0-9]*//')
drift_count=${#drifted[@]}

# Build JSON status
{
  echo "{"
  echo "  \"checked_at\": \"$(now_iso)\","
  echo "  \"dev_dir\": \"$DEV_DIR\","
  echo "  \"drift_count\": $drift_count,"
  echo "  \"drifted_repos\": ["
  for i in "${!drifted[@]}"; do
    sep=","; [[ $i -eq $((drift_count-1)) ]] && sep=""
    echo "    \"${drifted[$i]}\"$sep"
  done
  echo "  ]"
  echo "}"
} > "$STATE_FILE"
echo "wrote $STATE_FILE (drift_count=$drift_count)"

# Layer B — weekly clean (Sundays only)
dow=$(date +%u)  # 1=Mon ... 7=Sun
if [[ "$dow" == "7" ]]; then
  echo "── git-hygiene clean $DEV_DIR --yes (Sunday weekly) ──"
  "$SCRIPT_DIR/git-hygiene.sh" clean "$DEV_DIR" --yes 2>&1 || echo "git-hygiene exited $?"
else
  echo "── skipping git-hygiene clean (today is dow=$dow, not Sunday) ──"
fi

echo "═══ hygiene-cron done ═══"
