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

set -uo pipefail

QUEUE="$HOME/.claude/operator-queue.md"
[ -s "$QUEUE" ] || exit 0

today="$(date +%Y-%m-%d)"
today_epoch="$(date +%s)"

# Flatten each "## <slug>" block to one line: slug, added, project, deadline,
# action — delimited by the ASCII unit separator (\037), which unlike tab is
# not IFS whitespace, so empty fields survive the bash `read` below.
items="$(awk '
  function flush() {
    if (slug != "") printf "%s\037%s\037%s\037%s\037%s\n", slug, added, project, deadline, action
    slug = added = project = deadline = action = ""
  }
  /^## /                       { flush(); slug = substr($0, 4) }
  slug != "" && /^- added:/    { added = $0;    sub(/^- added:[ \t]*/, "", added) }
  slug != "" && /^- project:/  { project = $0;  sub(/^- project:[ \t]*/, "", project) }
  slug != "" && /^- deadline:/ { deadline = $0; sub(/^- deadline:[ \t]*/, "", deadline) }
  slug != "" && /^- action:/   { action = $0;   sub(/^- action:[ \t]*/, "", action) }
  END { flush() }
' "$QUEUE")"

[ -n "$items" ] || exit 0

# Render each item behind a sort key: deadline items first (soonest first),
# then no-deadline items oldest-added first. ISO dates sort lexically.
rendered="$(while IFS=$'\037' read -r slug added project deadline action; do
  [ -n "$slug" ] || continue

  age=""
  if [ -n "$added" ]; then
    if added_epoch="$(date -d "$added" +%s 2>/dev/null)"; then
      age="added $(((today_epoch - added_epoch) / 86400))d ago"
    else
      age="added $added"
    fi
  fi

  if [ -n "$deadline" ]; then
    key="0|$deadline"
    if [ "$deadline" \< "$today" ]; then
      flag="[PAST DUE $deadline]"
    elif [ "$deadline" = "$today" ]; then
      flag="[DUE TODAY]"
    else
      flag="[due $deadline]"
    fi
  else
    key="1|${added:-9999-99-99}"
    flag=""
  fi

  detail="${project:+project: $project}"
  detail="${detail:+$detail${age:+, }}$age"
  printf '%s\t  %s%s — %s%s\n' "$key" "${flag:+$flag }" "$slug" \
    "${action:-(no action line)}" "${detail:+ ($detail)}"
done <<<"$items" | sort | cut -f2-)"

[ -n "$rendered" ] || exit 0

count="$(printf '%s\n' "$rendered" | wc -l)"
echo "Operator action queue — $count open item(s) in ~/.claude/operator-queue.md:"
printf '%s\n' "$rendered"
echo "These need the operator, not the agent. Remove an item from the queue only when it is done."
exit 0
