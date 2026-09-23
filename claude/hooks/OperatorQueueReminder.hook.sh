#!/usr/bin/env bash
# OperatorQueueReminder.hook.sh — surface open operator-action items at session start.
#
# The handoff skills (claude/ and agents/) append USER ACTION items to
# ~/.claude/operator-queue.md — one "## <slug>" block per item with
# added/project/deadline/verified/action lines; items are removed only when
# done. Without a surface, queued items rot the way handoff prose did (each
# new handoff buries the last). A SessionStart hook's stdout is added to
# Claude's context, so every session starts knowing what only the operator can
# unblock: open items print with their age, deadline-carrying items first
# (soonest deadline at the top), past-due items flagged.
#
# Project filter (#558): the queue spans every repo, and printing all of it
# into every session buried the few items that concern the session and pushed
# the output past the persisted-output threshold (so the agent saw a preview,
# not the queue). Only items for the session's project print in full, plus
# every item past due or due today whatever its project. Each other project
# collapses to one line — `<project>: N items (oldest Xd, next deadline
# YYYY-MM-DD)` — and a footer names the queue file and the show-all switch.
#   Session project: the basename of the main checkout of the git repo holding
#   $CLAUDE_PROJECT_DIR (else the cwd) — resolved through --git-common-dir so a
#   linked worktree (.claude/worktrees/agent-…) still counts as its repo; the
#   plain directory basename outside git.
#   Item match: case-insensitive, on any word of the item's `project:` value,
#   since the queue names projects by repo basename and sometimes lists several
#   ("keen-media, operator-commons", "dotfiles / Codex Remote"). The summary
#   groups by the value's first word.
#
# Freshness: an item is only as true as its last check against live state.
# `verified: YYYY-MM-DD` records that check; an item whose newest of
# verified/added is more than STALE_DAYS old — or that carries no parseable
# date at all — is marked "[stale — re-verify]" and counted in the header, so
# a session that touches its subject knows to re-check before acting on it.
#
# ENV:
#   OPERATOR_QUEUE_SHOW_ALL=1  print every item in full (the pre-#558 view).
#   OPERATOR_QUEUE_FILE=<path> read this queue instead of
#                              ~/.claude/operator-queue.md (test fixtures).
#
# TRIGGER: SessionStart (after HandoffReminder)
# EXIT: 0 always (advisory/warn-only, never blocks)
# FAILURE MODE: open — silent when the queue is absent, empty, or has no
#   parseable item blocks; one warning line if the parse itself fails. This
#   hook only reads, never writes, the queue.
# BOUNDED: a queue over MAX_QUEUE_BYTES prints one warning line and exits;
#   at most MAX_ITEMS items are rendered ("…and N more" for the rest) and each
#   action is cut at MAX_ACTION_CHARS bytes, so a grown queue can never flood
#   session context or stall SessionStart.
# SELF-TEST: claude/scripts/tests/operator-queue-reminder.test.sh

set -uo pipefail

QUEUE="${OPERATOR_QUEUE_FILE:-$HOME/.claude/operator-queue.md}"
[ -s "$QUEUE" ] || exit 0
if [ "$QUEUE" = "$HOME/.claude/operator-queue.md" ]; then
  # shellcheck disable=SC2088 # a display string, deliberately unexpanded
  QUEUE_SHOWN="~/.claude/operator-queue.md"
else
  QUEUE_SHOWN="$QUEUE"
fi

MAX_QUEUE_BYTES=65536
MAX_ITEMS=20
MAX_ACTION_CHARS=600
STALE_DAYS=30
STALE_MARK="[stale — re-verify]"
SHOW_ALL=0
[ "${OPERATOR_QUEUE_SHOW_ALL:-}" = "1" ] && SHOW_ALL=1

queue_bytes="$(wc -c < "$QUEUE")"
if [ "$queue_bytes" -gt "$MAX_QUEUE_BYTES" ]; then
  echo "Operator action queue: $QUEUE_SHOWN is ${queue_bytes} bytes (limit ${MAX_QUEUE_BYTES}) — not rendering; prune done items (see the handoff skill)."
  exit 0
fi

# Session project (see header). A bare repo or a submodule has no "<repo>/.git"
# common dir; those fall back to the toplevel basename.
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
repo=""
if common="$(git -C "$project_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  case "$common" in
    */.git) repo="$(basename "$(dirname "$common")")" ;;
  esac
  if [ -z "$repo" ]; then
    top="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)" && repo="$(basename "$top")"
  fi
fi
[ -n "$repo" ] || repo="$(basename "$project_dir")"

today="$(date +%Y-%m-%d)"

# Single awk pass: flatten each "## <slug>" block, compute age/deadline/stale
# flags (civil-date arithmetic, no per-item forks), and emit one record per item:
#   sortkey TAB full TAB project TAB age_days TAB next_deadline TAB line
# full=1 marks an item printed in full (session project, past due / due today,
# or show-all). Empty fields carry the "-" sentinel so no field is ever empty.
# Deadline items key "0|<deadline>" (soonest first), the rest "1|<added>"
# (oldest first). ISO dates sort lexically, so `sort` finishes the ordering.
records="$(LC_ALL=C awk -v today="$today" -v stale_days="$STALE_DAYS" -v stale_mark="$STALE_MARK" \
  -v repo="$repo" -v show_all="$SHOW_ALL" -v max_action="$MAX_ACTION_CHARS" '
  # days_from_civil — days since 1970-01-01 (Howard Hinnant era algorithm).
  function days_from_civil(y, m, d,    era, yoe, doy, doe) {
    y -= (m <= 2)
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
  }
  # iso_days — day number of the ISO date that STARTS s; "" when there is
  # none. Prefix, not whole-line: handoffs annotate dates in place
  # ("added: 2026-07-13 (re-verified 2026-09-02)"), and the leading date is
  # still the date.
  function iso_days(s,    p, y, m, d, last_day) {
    if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return ""
    split(substr(s, 1, 10), p, "-")
    y = p[1] + 0; m = p[2] + 0; d = p[3] + 0
    if (m < 1 || m > 12 || d < 1) return ""
    last_day = (m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31
    if (m == 2) last_day = 28 + (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))
    if (d > last_day) return ""
    return days_from_civil(y, m, d)
  }
  # utf8_trim — drop the incomplete UTF-8 sequence a byte cut left at the end
  # of s, if any; complete characters stay. Byte-wise under LC_ALL=C.
  function utf8_trim(s,    n, k, c, need) {
    n = length(s); k = 0
    while (k < 3 && k < n && substr(s, n - k, 1) ~ /[\200-\277]/) k++
    if (k == n) return s
    c = substr(s, n - k, 1)
    if (c ~ /[\300-\337]/)      need = 2
    else if (c ~ /[\340-\357]/) need = 3
    else if (c ~ /[\360-\367]/) need = 4
    else return s
    return (k + 1 < need) ? substr(s, 1, n - k - 1) : s
  }
  # project_matches — any word of the project value equals the session repo.
  function project_matches(p,    n, w, i) {
    if (repo == "") return 0
    n = split(tolower(p), w, /[^a-z0-9._-]+/)
    for (i = 1; i <= n; i++) if (w[i] == tolower(repo)) return 1
    return 0
  }
  function flush(    key, flag, age, detail, d, v, dd, fresh, is_stale, full, age_days, next_dl, line, group) {
    if (slug == "") return
    age = ""
    d = iso_days(added)
    v = iso_days(verified)
    dd = iso_days(deadline)
    if (added != "") age = (d != "") ? "added " (today_days - d) "d ago" : "added " added
    if (v != "") age = ((age != "") ? age ", " : "") "verified " (today_days - v) "d ago"
    # Freshness is the newest parseable date; none at all is stale by definition.
    fresh = (d != "" && (v == "" || d > v)) ? d : v
    is_stale = (fresh == "" || today_days - fresh > stale_days)
    if (deadline != "") {
      key = "0|" deadline
      if (deadline < today)       flag = "[PAST DUE " deadline "] "
      else if (deadline == today) flag = "[DUE TODAY] "
      else                        flag = "[due " deadline "] "
    } else {
      key = "1|" ((added != "") ? added : "9999-99-99")
      flag = ""
    }
    if (is_stale) flag = flag stale_mark " "
    if (action == "") action = "(no action line)"
    if (length(action) > max_action) {
      action = utf8_trim(substr(action, 1, max_action)) "… [truncated; full text in the queue file]"
    }
    detail = (project != "") ? "project: " project : ""
    if (age != "") detail = (detail != "") ? detail ", " age : age
    line = "  " flag slug " — " action ((detail != "") ? " (" detail ")" : "")
    full = (show_all == 1 || project_matches(project) || (dd != "" && dd <= today_days)) ? 1 : 0
    age_days = (d != "") ? today_days - d : "-"
    next_dl = (dd != "" && dd >= today_days) ? substr(deadline, 1, 10) : "-"
    # Summary groups by the first word of the value ("dotfiles / Codex Remote" and
    # "dotfiles" are one project), so the summary stays one line per project.
    group = (match(project, /[A-Za-z0-9._-]+/)) ? substr(project, RSTART, RLENGTH) : "(no project)"
    print key "\t" full "\t" group "\t" age_days "\t" next_dl "\t" line
    slug = added = project = deadline = verified = action = ""
  }
  BEGIN { today_days = iso_days(today) }
  # Tolerate CRLF queue files; a tab in any value would shift the TAB-separated
  # record columns (hiding the item), so tabs become spaces on input.
  { sub(/\r$/, ""); gsub(/\t/, " ") }
  /^## /                       { flush(); slug = substr($0, 4) }
  slug != "" && /^- added:/    { added = $0;    sub(/^- added:[ \t]*/, "", added) }
  slug != "" && /^- project:/  { project = $0;  sub(/^- project:[ \t]*/, "", project) }
  slug != "" && /^- deadline:/ { deadline = $0; sub(/^- deadline:[ \t]*/, "", deadline) }
  slug != "" && /^- verified:/ { verified = $0; sub(/^- verified:[ \t]*/, "", verified) }
  slug != "" && /^- action:/   { action = $0;   sub(/^- action:[ \t]*/, "", action) }
  END { flush() }
' "$QUEUE" | LC_ALL=C sort)"
parse_rc=$?
if [ "$parse_rc" -ne 0 ]; then
  echo "Operator action queue: could not parse $QUEUE_SHOWN (rc $parse_rc) — read it directly."
  exit 0
fi

[ -n "$records" ] || exit 0

total="$(printf '%s\n' "$records" | wc -l)"
stale="$(printf '%s\n' "$records" | grep -cF -- "$STALE_MARK")"
full_lines="$(printf '%s\n' "$records" | awk -F'\t' '$2 == 1' | cut -f6-)"
full_count=0
[ -n "$full_lines" ] && full_count="$(printf '%s\n' "$full_lines" | wc -l)"

echo "Operator action queue — $total open item(s), $stale stale (>${STALE_DAYS}d since added/verified) in $QUEUE_SHOWN:"
if [ "$SHOW_ALL" -ne 1 ]; then
  echo "Items for $repo, plus any past due or due today:"
  [ "$full_count" -gt 0 ] || echo "  (none for $repo)"
fi
if [ "$full_count" -gt 0 ]; then
  printf '%s\n' "$full_lines" | head -n "$MAX_ITEMS"
  if [ "$full_count" -gt "$MAX_ITEMS" ]; then
    echo "  …and $((full_count - MAX_ITEMS)) more — see $QUEUE_SHOWN"
  fi
fi
if [ "$SHOW_ALL" -ne 1 ] && [ "$full_count" -lt "$total" ]; then
  echo "Other projects (summary):"
  # One line per project: count, oldest added age, soonest upcoming deadline.
  printf '%s\n' "$records" | LC_ALL=C awk -F'\t' '
    $2 == 0 {
      p = $3; n[p]++
      if ($4 != "-" && (!(p in oldest) || $4 + 0 > oldest[p])) oldest[p] = $4 + 0
      if ($5 != "-" && (!(p in next_dl) || $5 < next_dl[p])) next_dl[p] = $5
    }
    END {
      for (p in n) {
        extra = (p in oldest) ? "oldest " oldest[p] "d" : ""
        if (p in next_dl) extra = ((extra != "") ? extra ", " : "") "next deadline " next_dl[p]
        print "  " p ": " n[p] " item" ((n[p] == 1) ? "" : "s") ((extra != "") ? " (" extra ")" : "")
      }
    }' | LC_ALL=C sort
  echo "Full queue: $QUEUE_SHOWN — read it, or start a session with OPERATOR_QUEUE_SHOW_ALL=1, to see every item."
fi
echo "These need the operator, not the agent. When a session touches an item's subject, re-check it against live state and set/bump its \`verified:\` date; remove an item only when it is done."
exit 0
