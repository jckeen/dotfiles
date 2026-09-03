#!/usr/bin/env bash
# hygiene-cron — daily systemd-fired wrapper that:
#   1. Runs `gh-bootstrap --check --all ~/dev`, writes JSON status for hooks
#   2. Runs `git-hygiene prune ~/dev --yes --gh` — deletes only safely-dead
#      local branches (see git-hygiene.sh for the SAFE class), logs each
#      deletion with its SHA, and pushes an ntfy summary when ≥1 was deleted.
#      The summary carries counts only — ntfy topics are effectively public,
#      so repo and branch names stay in the local log.
#
# Triggered by git-hygiene.timer. Logs to ~/.local/state/hygiene/cron.log;
# the last run's deletions land in last-prune.tsv, all of them in deletions.tsv
# (repo, branch, sha, reason — recover with `git branch <name> <sha>`).
#
# Env:
#   HYGIENE_DELETE=0      audit + status only; skip the prune (default: on)
#   HYGIENE_GH_CHECK=0    prune without the GitHub merged-PR check (default: on)
#   HYGIENE_DEV_DIR       root scanned (default: ~/dev)
#   HYGIENE_SCRIPT_DIR    where gh-bootstrap.sh / git-hygiene.sh live
#                         (default: $HYGIENE_DEV_DIR/dotfiles; tests point it at
#                         a stub directory)
#   NTFY_TOPIC / NTFY_SERVER  as for ntfy-awaiting-input.sh; NTFY_TOPIC falls
#                         back to the settings.json env block (systemd units do
#                         not inherit the Claude env)

set -uo pipefail

DEV_DIR="${HYGIENE_DEV_DIR:-$HOME/dev}"
# State file is XDG-neutral (not under ~/.claude/) so Codex/Claude/CLI all share one source
STATE_FILE="$HOME/.local/state/hygiene/status.json"
LOG_DIR="$HOME/.local/state/hygiene"
LOG_FILE="$LOG_DIR/cron.log"
SCRIPT_DIR="${HYGIENE_SCRIPT_DIR:-$DEV_DIR/dotfiles}"

mkdir -p "$LOG_DIR"

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Push a summary via ntfy. Mirrors ntfy-awaiting-input.sh: https-only server
# matching a strict pattern, topic charset [A-Za-z0-9_-], body sanitized and
# piped (never an argv), silent skip on any validation miss. Body on stdin.
notify_ntfy() {
  local title="$1"
  local server="${NTFY_SERVER:-https://ntfy.sh}" topic="${NTFY_TOPIC:-}"
  if [[ -z "$topic" && -r "$HOME/.claude/settings.json" ]] && command -v jq >/dev/null 2>&1; then
    topic=$(jq -r '.env.NTFY_TOPIC // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)
  fi
  if [[ -z "$topic" ]]; then
    echo "ntfy: NTFY_TOPIC unset — summary not sent"; cat >/dev/null; return 0
  fi
  local server_re='^https://[a-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9_/-]*)?$'
  if ! [[ "$server" =~ $server_re && "$topic" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ntfy: NTFY_SERVER/NTFY_TOPIC failed validation — summary not sent"; cat >/dev/null; return 0
  fi
  if tr -cd '[:print:]\n' | head -c 2000 | curl -s -o /dev/null --max-time 15 \
       -H "Title: $title" -H "Priority: default" -H "Tags: broom" \
       --data-binary "@-" "${server}/${topic}"; then
    echo "ntfy: summary sent"
  else
    echo "ntfy: send failed (curl exit $?)"
  fi
}

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

# Layer B — daily safe prune
if [[ "${HYGIENE_DELETE:-1}" == "0" ]]; then
  echo "── HYGIENE_DELETE=0 — skipping git-hygiene prune ──"
else
  REPORT="$LOG_DIR/last-prune.tsv"
  : > "$REPORT"
  gh_flag=()
  [[ "${HYGIENE_GH_CHECK:-1}" != "0" ]] && gh_flag=(--gh)
  echo "── git-hygiene prune $DEV_DIR --yes ${gh_flag[*]:-} ──"
  HYGIENE_REPORT="$REPORT" "$SCRIPT_DIR/git-hygiene.sh" prune "$DEV_DIR" --yes "${gh_flag[@]}" 2>&1 \
    || echo "git-hygiene exited $?"

  deleted_count=$(grep -c . "$REPORT" || true)
  if [[ "$deleted_count" -gt 0 ]]; then
    cat "$REPORT" >> "$LOG_DIR/deletions.tsv"
    repo_count=$(cut -f1 "$REPORT" | sort -u | wc -l)
    echo "pruned $deleted_count branch(es) across $repo_count repo(s) — recovery SHAs in $LOG_DIR/deletions.tsv"
    # Counts only: an ntfy topic is readable by anyone who guesses it, so the
    # private repo/branch names (and $HOME) never leave this machine.
    echo "git-hygiene pruned $deleted_count branch(es) across $repo_count repo(s); details and recovery SHAs in ${LOG_FILE/#"$HOME"/\~}" \
      | notify_ntfy "git-hygiene: pruned $deleted_count branch(es)"
  else
    echo "pruned 0 branches — no notification"
  fi
fi

echo "═══ hygiene-cron done ═══"
