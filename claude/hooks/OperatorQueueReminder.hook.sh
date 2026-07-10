#!/usr/bin/env bash
# OperatorQueueReminder.hook.sh — surface open operator-action items at session start.
#
# The handoff skills (claude/ and agents/) append USER ACTION items to
# ~/.claude/operator-queue.md — one "## <slug>" block per item with
# added/project/deadline/action lines; items are removed only when done.
# Without a surface, queued items rot the way handoff prose did (each new
# handoff buries the last). A SessionStart hook's stdout is added to Claude's
# context, so every session starts knowing what only the operator can unblock:
# open items print with their age, deadline-carrying items first (soonest
# deadline at the top), past-due items flagged.
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

queue_bytes="$(wc -c < "$QUEUE")"
if [ "$queue_bytes" -gt "$MAX_QUEUE_BYTES" ]; then
  echo "Operator action queue: ~/.claude/operator-queue.md is ${queue_bytes} bytes (limit ${MAX_QUEUE_BYTES}) — not rendering; prune done items (see the handoff skill)."
  exit 0
fi

today="$(date +%Y-%m-%d)"

# Single awk pass: flatten each "## <slug>" block, compute age/deadline flags
# (civil-date arithmetic, no per-item forks), and emit "sortkey<TAB>line" —
# deadline items key "0|<deadline>" (soonest first), the rest "1|<added>"
# (oldest first). ISO dates sort lexically, so `sort` finishes the ordering.
rendered="$(LC_ALL=C awk -v today="$today" '
  # days_from_civil — days since 1970-01-01 (Howard Hinnant era algorithm).
  function days_from_civil(y, m, d,    era, yoe, doy, doe) {
    y -= (m <= 2)
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
  }
  function iso_days(s,    p) {
    if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return ""
    split(s, p, "-")
    return days_from_civil(p[1] + 0, p[2] + 0, p[3] + 0)
  }
  function flush(    key, flag, age, detail, d) {
    if (slug == "") return
    age = ""
    if (added != "") {
      d = iso_days(added)
      age = (d != "") ? "added " (today_days - d) "d ago" : "added " added
    }
    if (deadline != "") {
      key = "0|" deadline
      if (deadline < today)       flag = "[PAST DUE " deadline "] "
      else if (deadline == today) flag = "[DUE TODAY] "
      else                        flag = "[due " deadline "] "
    } else {
      key = "1|" ((added != "") ? added : "9999-99-99")
      flag = ""
    }
    if (action == "") action = "(no action line)"
    detail = (project != "") ? "project: " project : ""
    if (age != "") detail = (detail != "") ? detail ", " age : age
    print key "\t  " flag slug " — " action ((detail != "") ? " (" detail ")" : "")
    slug = added = project = deadline = action = ""
  }
  BEGIN { today_days = iso_days(today) }
  { sub(/\r$/, "") }                       # tolerate CRLF queue files
  /^## /                       { flush(); slug = substr($0, 4) }
  slug != "" && /^- added:/    { added = $0;    sub(/^- added:[ \t]*/, "", added) }
  slug != "" && /^- project:/  { project = $0;  sub(/^- project:[ \t]*/, "", project) }
  slug != "" && /^- deadline:/ { deadline = $0; sub(/^- deadline:[ \t]*/, "", deadline) }
  slug != "" && /^- action:/   { action = $0;   sub(/^- action:[ \t]*/, "", action) }
  END { flush() }
' "$QUEUE" | sort | cut -f2-)"

[ -n "$rendered" ] || exit 0

total="$(printf '%s\n' "$rendered" | wc -l)"
echo "Operator action queue — $total open item(s) in ~/.claude/operator-queue.md:"
printf '%s\n' "$rendered" | head -n "$MAX_ITEMS"
if [ "$total" -gt "$MAX_ITEMS" ]; then
  echo "  …and $((total - MAX_ITEMS)) more — see ~/.claude/operator-queue.md"
fi
echo "These need the operator, not the agent. Remove an item from the queue only when it is done."
exit 0
