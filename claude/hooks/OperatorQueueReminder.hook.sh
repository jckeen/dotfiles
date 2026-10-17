#!/usr/bin/env bash
# OperatorQueueReminder.hook.sh — surface open operator-action items at session start.
#
# Two sources, one renderer. The handoff skills (claude/ and agents/) record
# USER ACTION items either as "## <slug>" blocks in ~/.claude/operator-queue.md
# (added/project/deadline/verified/action lines; removed only when done) or as
# open issues labelled `operator-action` in the private OPERATOR_QUEUE_REPO,
# which a phone or a cloud session can read too. The file stays the source
# until its first lines carry the "> **Historical**" banner; after that the
# issues are listed with `gh` (bounded by FETCH_TIMEOUT), turned into the same
# blocks (see fetch_issues) and cached owner-only under
# ${XDG_STATE_HOME:-~/.local/state}/operator-queue/ for CACHE_TTL seconds.
# Without a surface, queued items rot the way handoff prose did (each
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
#   OPERATOR_QUEUE_REPO=<o/r>  the issue source's repo (default
#                              jckeen/claude-memory; keep it private — items
#                              name credentials and providers).
#   OPERATOR_QUEUE_FETCH_TIMEOUT=<s>  the gh fetch ceiling (default 8).
#
# TRIGGER: SessionStart (after HandoffReminder)
# EXIT: 0 always (advisory/warn-only, never blocks)
# FAILURE MODE: open — silent when the file queue is empty or has no parseable
#   item blocks, or when GitHub answers with no open issues; one warning line
#   if the parse itself fails. An unreachable GitHub is never silent: the
#   header says the items come from a cache of a given age, or, with no cache,
#   one line names the gh command to run. This hook only reads the queue; its
#   one write is the issue cache.
# BOUNDED: a queue over MAX_QUEUE_BYTES prints one warning line and exits;
#   at most MAX_ITEMS items (every item under OPERATOR_QUEUE_SHOW_ALL=1) and
#   MAX_ITEMS project summaries are rendered ("…and N more" for the rest),
#   each action is cut at MAX_ACTION_CHARS bytes, each item line at
#   MAX_LINE_CHARS and each summary label at 80, so a grown queue can never
#   flood session context or stall SessionStart.
# SELF-TEST: claude/scripts/tests/operator-queue-reminder.test.sh

set -uo pipefail

LEGACY="$HOME/.claude/operator-queue.md"
ISSUE_REPO="${OPERATOR_QUEUE_REPO:-jckeen/claude-memory}"
# One cache per source repo, so switching OPERATOR_QUEUE_REPO never shows the
# previous repo's items under the new name.
CACHE="${XDG_STATE_HOME:-$HOME/.local/state}/operator-queue/issues-$(printf '%s' "$ISSUE_REPO" | tr -c 'A-Za-z0-9._-' '_').md"
CACHE_TTL=600
FETCH_TIMEOUT="${OPERATOR_QUEUE_FETCH_TIMEOUT:-8}"
FETCH_LIMIT=500
SOURCE="file"
CACHE_NOTE=""

# Bounded run: GNU `timeout` (Linux), `gtimeout` (macOS coreutils), else a
# watchdog subshell that kills the command, so the fetch ceiling holds on every
# path and a stalled gh can never hold SessionStart.
tmo() {
  local secs="$1"; shift
  if   command -v timeout  >/dev/null 2>&1; then timeout "$secs" "$@"; return
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return
  fi
  "$@" & local pid=$!
  # Children first: one left alive keeps the caller's $(...) pipe open, and the
  # capture would wait on it past the ceiling.
  ( sleep "$secs"; pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & local dog=$!
  wait "$pid"; local rc=$?
  kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  return "$rc"
}

# fetch_issues — open operator-action issues rendered as the same "## <slug>"
# blocks the file queue uses, so one renderer serves both sources. added is the
# body's `- added:` line (migrated items keep their real age), else the issue's
# creation date. verified is the newer of the body's `- verified:` date and the
# latest comment, so a re-verify comment bumps it but a label edit does not.
# project is the body's full `- project:` value (a migrated "keen-media,
# operator-commons" item still matches either session), else a
# `project:<name>` label; deadline and action come from the body's
# `- deadline:` / `- action:` lines (the action falls back to the first
# non-empty body line that is not a field). A result that fills FETCH_LIMIT is
# marked "# truncated" so the header can say the list is incomplete.
fetch_issues() {
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  local json
  json="$(tmo "$FETCH_TIMEOUT" gh issue list -R "$ISSUE_REPO" --label operator-action \
    --state open --limit "$FETCH_LIMIT" --json number,title,body,createdAt,labels,comments 2>/dev/null)" || return 1
  jq -r --argjson limit "$FETCH_LIMIT" '
    def field($k): [ .[] | select(startswith("- " + $k + ":")) | sub("^- " + $k + ":[ \t]*"; "") ][0] // "";
    "# Operator-action issues",
    (if length >= $limit then "# truncated" else empty end),
    ( .[] | (.body // "" | gsub("\r"; "") | split("\n")) as $lines
      | (($lines | field("project")) as $p
          | if $p != "" then $p
            else ([ .labels[].name | select(startswith("project:")) | sub("^project:"; "") ][0] // "") end) as $project
      | ($lines | field("deadline")) as $deadline
      | (($lines | field("added")) as $a | if $a != "" then $a else .createdAt[0:10] end) as $added
      | ([ ($lines | field("verified") | .[0:10]), ((.comments // [])[].createdAt[0:10]) ]
          | map(select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))) | max // "") as $verified
      | (($lines | field("action")) as $a
          | if $a != "" then $a else ([ $lines[] | select(test("\\S") and (test("^- [a-z]+:") | not)) ][0] // "") end) as $action
      | "", "## \(.title) (#\(.number))",
        "- added: \($added)",
        (if $verified != "" then "- verified: \($verified)" else empty end),
        (if $project != "" then "- project: \($project)" else empty end),
        (if $deadline != "" then "- deadline: \($deadline)" else empty end),
        "- action: \($action)" )' <<<"$json"
}

# Source: the file queue is migrating to operator-action issues in the private
# ISSUE_REPO, which the phone and cloud sessions can read. A queue file that
# exists — even empty — stays authoritative until a line of its first five
# STARTS with the historical banner (an action merely mentioning the banner
# does not count), so no item goes dark mid-migration. OPERATOR_QUEUE_FILE
# (test fixtures) always wins.
if [ -n "${OPERATOR_QUEUE_FILE:-}" ]; then
  QUEUE="$OPERATOR_QUEUE_FILE"
elif [ -f "$LEGACY" ] && ! head -n 5 "$LEGACY" | grep -q '^> \*\*Historical\*\*'; then
  QUEUE="$LEGACY"
else
  SOURCE="issues"
  QUEUE="$CACHE"
  cache_age=-1
  if [ -f "$CACHE" ]; then
    cache_age=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE") ))
  fi
  if [ "$cache_age" -lt 0 ] || [ "$cache_age" -gt "$CACHE_TTL" ]; then
    mkdir -p "$(dirname "$CACHE")"
    tmp="$(mktemp "$CACHE.XXXXXX")"
    if fetch_issues > "$tmp"; then
      chmod 600 "$tmp"; mv -f "$tmp" "$CACHE"
    else
      rm -f "$tmp"
      # A failed fetch must never read as "no open items": say so, and fall
      # back to the last good cache when there is one.
      if [ "$cache_age" -lt 0 ]; then
        echo "Operator action queue: could not list operator-action issues in $ISSUE_REPO (offline, gh unauthenticated, or gh/jq missing) and no cache exists — run \`gh issue list -R $ISSUE_REPO --label operator-action\`."
        exit 0
      fi
      CACHE_NOTE=" (GitHub unreachable — cached $((cache_age / 60)) min ago)"
    fi
  fi
  if grep -qx '# truncated' "$CACHE" 2>/dev/null; then
    CACHE_NOTE="$CACHE_NOTE (first $FETCH_LIMIT only — more are open)"
  fi
  if ! grep -q '^## ' "$CACHE" 2>/dev/null; then
    # An empty answer is only "nothing open" when it is fresh.
    [ -n "$CACHE_NOTE" ] && echo "Operator action queue: no open operator-action issues in $ISSUE_REPO as of the last good fetch$CACHE_NOTE."
    exit 0
  fi
fi
[ -s "$QUEUE" ] || exit 0
if [ "$SOURCE" = issues ]; then
  QUEUE_SHOWN="operator-action issues in $ISSUE_REPO$CACHE_NOTE"
  FULL_REF="the issue"
elif [ "$QUEUE" = "$LEGACY" ]; then
  # shellcheck disable=SC2088 # a display string, deliberately unexpanded
  QUEUE_SHOWN="~/.claude/operator-queue.md"
  FULL_REF="the queue file"
else
  QUEUE_SHOWN="$QUEUE"
  FULL_REF="the queue file"
fi

MAX_QUEUE_BYTES=65536
MAX_ITEMS=20
MAX_ACTION_CHARS=600
MAX_LINE_CHARS=1000
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
  -v repo="$repo" -v show_all="$SHOW_ALL" -v full_ref="$FULL_REF" -v max_action="$MAX_ACTION_CHARS" -v max_line="$MAX_LINE_CHARS" '
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
      action = utf8_trim(substr(action, 1, max_action)) "… [truncated; full text in " full_ref "]"
    }
    detail = (project != "") ? "project: " project : ""
    if (age != "") detail = (detail != "") ? detail ", " age : age
    line = "  " flag slug " — " action ((detail != "") ? " (" detail ")" : "")
    # Backstop for the other fields (slug, project): no line exceeds the cap.
    if (length(line) > max_line) line = utf8_trim(substr(line, 1, max_line)) "… [truncated]"
    full = (show_all == 1 || project_matches(project) || (dd != "" && dd <= today_days)) ? 1 : 0
    age_days = (d != "") ? today_days - d : "-"
    next_dl = (dd != "" && dd >= today_days) ? substr(deadline, 1, 10) : "-"
    # Summary groups by the first word of the value ("dotfiles / Codex Remote" and
    # "dotfiles" are one project), so the summary stays one line per project.
    group = (match(project, /[A-Za-z0-9._-]+/)) ? substr(project, RSTART, (RLENGTH < 80) ? RLENGTH : 80) : "(no project)"
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
  # Show-all is the explicit opt-out of the item cap; each line stays bounded.
  if [ "$SHOW_ALL" -eq 1 ]; then
    printf '%s\n' "$full_lines"
  else
    printf '%s\n' "$full_lines" | head -n "$MAX_ITEMS"
  fi
  if [ "$SHOW_ALL" -ne 1 ] && [ "$full_count" -gt "$MAX_ITEMS" ]; then
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
    }' | LC_ALL=C sort | awk -v max="$MAX_ITEMS" -v src="$QUEUE_SHOWN" '
      # The summary is bounded like the item list: many distinct projects must
      # not flood session context either.
      NR <= max { print; next }
      { extra++ }
      END { if (extra) print "  …and " extra " more projects — see " src }'
  if [ "$SOURCE" = issues ]; then
    echo "Full queue: \`gh issue list -R $ISSUE_REPO --label operator-action\`, or start a session with OPERATOR_QUEUE_SHOW_ALL=1, to see every item."
  else
    echo "Full queue: $QUEUE_SHOWN — read it, or start a session with OPERATOR_QUEUE_SHOW_ALL=1, to see every item."
  fi
fi
if [ "$SOURCE" = issues ]; then
  echo "These need the operator, not the agent. When a session touches an item's subject, re-check it against live state and comment on the issue with what it found (that bumps its verified date); close it only when it is done."
else
  echo "These need the operator, not the agent. When a session touches an item's subject, re-check it against live state and set/bump its \`verified:\` date; remove an item only when it is done."
fi
exit 0
