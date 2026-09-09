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
# Freshness: an item is only as true as its last check against live state.
# `verified: YYYY-MM-DD` records that check; an item whose newest of
# verified/added is more than STALE_DAYS old — or that carries no parseable
# date at all — is marked "[stale — re-verify]" and counted in the header, so
# a session that touches its subject knows to re-check before acting on it.
#
# TRIGGER: SessionStart (after HandoffReminder)
# EXIT: 0 always (advisory/warn-only, never blocks)
# FAILURE MODE: open — silent when the queue is absent, empty, or has no
#   parseable item blocks; this hook only reads, never writes, the queue.
# BOUNDED: a queue over MAX_QUEUE_BYTES prints one warning line and exits;
#   at most MAX_ITEMS items are rendered ("…and N more" for the rest), so a
#   grown queue can never flood session context or stall SessionStart.

set -uo pipefail

QUEUE="$HOME/.claude/operator-queue.md"
[ -s "$QUEUE" ] || exit 0

MAX_QUEUE_BYTES=65536
MAX_ITEMS=20
STALE_DAYS=30
STALE_MARK="[stale — re-verify]"

queue_bytes="$(wc -c < "$QUEUE")"
if [ "$queue_bytes" -gt "$MAX_QUEUE_BYTES" ]; then
  echo "Operator action queue: ~/.claude/operator-queue.md is ${queue_bytes} bytes (limit ${MAX_QUEUE_BYTES}) — not rendering; prune done items (see the handoff skill)."
  exit 0
fi

today="$(date +%Y-%m-%d)"

# Single awk pass: flatten each "## <slug>" block, compute age/deadline/stale
# flags (civil-date arithmetic, no per-item forks), and emit "sortkey<TAB>line"
# — deadline items key "0|<deadline>" (soonest first), the rest "1|<added>"
# (oldest first). ISO dates sort lexically, so `sort` finishes the ordering.
rendered="$(LC_ALL=C awk -v today="$today" -v stale_days="$STALE_DAYS" -v stale_mark="$STALE_MARK" '
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
  function flush(    key, flag, age, detail, d, v, fresh, is_stale) {
    if (slug == "") return
    age = ""
    d = iso_days(added)
    v = iso_days(verified)
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
    detail = (project != "") ? "project: " project : ""
    if (age != "") detail = (detail != "") ? detail ", " age : age
    print key "\t  " flag slug " — " action ((detail != "") ? " (" detail ")" : "")
    slug = added = project = deadline = verified = action = ""
  }
  BEGIN { today_days = iso_days(today) }
  { sub(/\r$/, "") }                       # tolerate CRLF queue files
  /^## /                       { flush(); slug = substr($0, 4) }
  slug != "" && /^- added:/    { added = $0;    sub(/^- added:[ \t]*/, "", added) }
  slug != "" && /^- project:/  { project = $0;  sub(/^- project:[ \t]*/, "", project) }
  slug != "" && /^- deadline:/ { deadline = $0; sub(/^- deadline:[ \t]*/, "", deadline) }
  slug != "" && /^- verified:/ { verified = $0; sub(/^- verified:[ \t]*/, "", verified) }
  slug != "" && /^- action:/   { action = $0;   sub(/^- action:[ \t]*/, "", action) }
  END { flush() }
' "$QUEUE" | sort | cut -f2-)"

[ -n "$rendered" ] || exit 0

total="$(printf '%s\n' "$rendered" | wc -l)"
stale="$(printf '%s\n' "$rendered" | grep -cF -- "$STALE_MARK")"
echo "Operator action queue — $total open item(s), $stale stale (>${STALE_DAYS}d since added/verified) in ~/.claude/operator-queue.md:"
printf '%s\n' "$rendered" | head -n "$MAX_ITEMS"
if [ "$total" -gt "$MAX_ITEMS" ]; then
  echo "  …and $((total - MAX_ITEMS)) more — see ~/.claude/operator-queue.md"
fi
echo "These need the operator, not the agent. When a session touches an item's subject, re-check it against live state and set/bump its \`verified:\` date; remove an item only when it is done."
exit 0
