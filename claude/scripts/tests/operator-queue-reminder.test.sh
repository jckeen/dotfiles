#!/usr/bin/env bash
# operator-queue-reminder.test.sh — fixture tests for OperatorQueueReminder.hook.sh.
# Runs the SessionStart hook against throwaway HOMEs holding crafted
# ~/.claude/operator-queue.md files and asserts the rendered lines: deadline-
# first ordering with past-due flags (unchanged), the `verified:` freshness
# rule (newest of verified/added; >30d or undated → "[stale — re-verify]"),
# and the header's stale count; then the per-project filter (#558): only the
# session repo's items plus past-due ones print in full, every other project
# collapses to one summary line, OPERATOR_QUEUE_SHOW_ALL=1 restores the full
# list, and the repo name falls back to the cwd basename outside git. Then the
# issue source: with no queue file (or one carrying the historical banner) the
# hook lists operator-action issues through a fake `gh`, caches them, falls
# back to the cache when GitHub is unreachable, and says so instead of going
# silent when there is neither. Run directly; exit 1 on any failure.
set -uo pipefail

resolve_script_path() {
  local target="$1" dir
  while [[ -L "$target" ]]; do
    dir="$(cd -P "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    [[ "$target" != /* ]] && target="$dir/$target"
  done
  cd -P "$(dirname "$target")" && pwd
}
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
HOOK="$SCRIPT_DIR/../../hooks/OperatorQueueReminder.hook.sh"

pass=0
failed=0
out=""

# Hermetic gh: every case runs with a fake `gh` first on PATH, so no test ever
# reaches the real GitHub. It logs its argv to $FAKE_GH_LOG and prints the
# file named by $FAKE_GH_JSON, or exits 1 (unreachable) when that is unset.
FAKEBIN="$(mktemp -d)"
cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
# Answers `gh api graphql --paginate` with one page wrapping the fixture array:
# labels and comments as GraphQL connections, comments cut to the newest one
# the way comments(last: 1) is. FAKE_GH_SLEEP stalls first (a slow GitHub).
[ -n "${FAKE_GH_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_GH_LOG"
[ -n "${FAKE_GH_SLEEP:-}" ] && sleep "$FAKE_GH_SLEEP"
[ -n "${FAKE_GH_LOG:-}" ] && echo "gh-done" >> "$FAKE_GH_LOG"
[ -n "${FAKE_GH_JSON:-}" ] || exit 1
jq '{data: {repository: {issues: {pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [ .[] | .labels = {nodes: (.labels // [])}
                | .comments = {nodes: ((.comments // []) | .[-1:])} ]}}}}' "$FAKE_GH_JSON"
GH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"
unset XDG_STATE_HOME FAKE_GH_JSON FAKE_GH_LOG OPERATOR_QUEUE_REPO GH_HOST

# Dates relative to the real today, so the assertions hold on any run date.
# GNU date (Linux CI + WSL); the hook itself uses only `date +%Y-%m-%d`.
day() { date -d "$1 days" +%Y-%m-%d; }
TODAY="$(day 0)"
D5="$(day -5)"      # fresh
D29="$(day -29)"    # inside the window (30 days is the boundary, not stale)
D31="$(day -31)"    # one past the boundary
D45="$(day -45)"    # stale
D90="$(day -90)"    # old
F10="$(day 10)"     # future deadline
P3="$(day -3)"      # past deadline
STALE='[stale — re-verify]'

# run_hook <queue-content> — HOME is a throwaway; captures stdout+rc. The
# rendering sections below predate the project filter, so they ask for the
# full list with OPERATOR_QUEUE_SHOW_ALL=1.
run_hook() {
  H="$(mktemp -d)"
  mkdir -p "$H/.claude"
  printf '%s\n' "$1" > "$H/.claude/operator-queue.md"
  out="$(env -u CLAUDE_PROJECT_DIR -u OPERATOR_QUEUE_FILE HOME="$H" OPERATOR_QUEUE_SHOW_ALL=1 "$HOOK" 2>&1)"
  rc=$?
  rm -rf "$H"
}

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (condition: $cond)"
    printf '%s\n' "$out" | sed 's/^/      | /'
  fi
}
line_for() { printf '%s\n' "$out" | grep -F -- " $1 — "; }   # the rendered line of one slug
outgrep() { grep -qF -- "$1" <<<"$out"; }

# ── freshness rule ──────────────────────────────────────────────────────
run_hook "# queue

## fresh-item
- added: $D5
- project: p
- action: do the fresh thing

## verified-recently
- added: $D90
- project: p
- verified: $D5
- action: re-checked lately

## stale-item
- added: $D45
- project: p
- action: nobody looked

## verified-long-ago
- added: $D90
- verified: $D45
- action: checked once, long ago

## boundary-29
- added: $D29
- action: inside the window

## boundary-31
- added: $D31
- action: just outside

## undated
- project: p
- action: no dates at all

## annotated-added
- added: $D5 (re-verified today; see handoff)
- action: date prefix with prose after it
"
assert "hook exits 0" "[ $rc -eq 0 ]"
assert "fresh item: no stale marker" "! line_for fresh-item | grep -qF -- '$STALE'"
assert "fresh item: age shown" "line_for fresh-item | grep -qF 'added 5d ago'"
assert "verified recently, added long ago: not stale" "! line_for verified-recently | grep -qF -- '$STALE'"
assert "verified recently: both ages shown" "line_for verified-recently | grep -qF 'added 90d ago, verified 5d ago'"
assert "stale item: marked" "line_for stale-item | grep -qF -- '$STALE'"
assert "stale marker precedes the slug" "line_for stale-item | grep -qF -- '$STALE stale-item — nobody looked'"
assert "verified long ago: marked" "line_for verified-long-ago | grep -qF -- '$STALE'"
assert "29d: not stale" "! line_for boundary-29 | grep -qF -- '$STALE'"
assert "31d: stale" "line_for boundary-31 | grep -qF -- '$STALE'"
assert "undated item: stale" "line_for undated | grep -qF -- '$STALE'"
assert "annotated added: date prefix parsed" "line_for annotated-added | grep -qF 'added 5d ago' && ! line_for annotated-added | grep -qF -- '$STALE'"
assert "header counts items and stale ones" "outgrep 'Operator action queue — 8 open item(s), 4 stale (>30d since added/verified)'"
assert "trailer asks for a verified bump" "outgrep 'set/bump its \`verified:\` date'"

# ── deadline ordering and flags unchanged ───────────────────────────────
run_hook "## no-deadline-old
- added: $D90
- action: old, no deadline

## due-later
- added: $D5
- deadline: $F10
- action: later

## past-due
- added: $D5
- deadline: $P3
- action: overdue

## due-today
- added: $D5
- deadline: $TODAY
- action: today

## no-deadline-new
- added: $D5
- action: new, no deadline
"
slug_order() { printf '%s\n' "$out" | grep -oE ' (no-deadline-old|due-later|past-due|due-today|no-deadline-new) — ' | tr -d ' —' | tr '\n' ' '; }
assert "deadline items first, soonest first; then by added" "[ \"\$(slug_order)\" = 'past-due due-today due-later no-deadline-old no-deadline-new ' ]"
assert "past-due flag retained" "outgrep '[PAST DUE $P3] past-due — overdue'"
assert "due-today flag retained" "outgrep '[DUE TODAY] due-today — today'"
assert "future deadline flag retained" "outgrep '[due $F10] due-later — later'"
assert "stale marker sits after the deadline flag" "outgrep '  $STALE no-deadline-old — old'"
assert "header: 5 items, 1 stale" "outgrep '5 open item(s), 1 stale'"

# ── calendar validity, including Gregorian leap-year rules ───────────────
for invalid in 2026-99-99 2026-00-10 2026-09-00 2026-04-31 2100-02-29; do
  run_hook "## invalid-date
- added: $invalid
- verified: $invalid
- action: re-check the typo
"
  assert "invalid $invalid is stale" "line_for invalid-date | grep -qF -- '$STALE'"
  assert "invalid $invalid has no normalized age" "line_for invalid-date | grep -qF 'added $invalid)'"
done
run_hook "## invalid-verification
- added: $D90
- verified: 9999-99-99
- action: old item with a date typo
"
assert "invalid verified date cannot mask old added date" "line_for invalid-verification | grep -qF -- '$STALE'"
for valid in 2400-02-29 2404-02-29; do
  run_hook "## valid-leap-day
- added: $valid (annotation retained)
- action: valid future date
"
  assert "valid leap day $valid is parsed" "line_for valid-leap-day | grep -q 'added -[0-9]*d ago'"
done

# ── silence when empty / absent ─────────────────────────────────────────
FAKE_GH_JSON="$FAKEBIN/none.json"; printf '[]' > "$FAKE_GH_JSON"; export FAKE_GH_JSON
run_hook ""
unset FAKE_GH_JSON
assert "empty queue, no open issues: silent" "[ -z \"\$out\" ] && [ $rc -eq 0 ]"
H="$(mktemp -d)"
out="$(env -u CLAUDE_PROJECT_DIR -u OPERATOR_QUEUE_FILE HOME="$H" OPERATOR_QUEUE_REFRESH_SYNC=1 "$HOOK" 2>&1)"; rc=$?
assert "absent queue, GitHub unreachable, no cache: one warning line" "[ $rc -eq 0 ] && [ \"\$(printf '%s\n' \"\$out\" | wc -l)\" -eq 1 ] && outgrep 'could not list operator-action issues in github.com/jckeen/claude-memory'"
rm -rf "$H"

# ── project filter (#558) ───────────────────────────────────────────────
# run_in <dir> <queue-content> [VAR=val...] — the queue lives in a fixture file
# named by OPERATOR_QUEUE_FILE; the hook runs with <dir> as its cwd and no
# CLAUDE_PROJECT_DIR (unless passed), so the repo name comes from <dir> alone.
FX="$(mktemp -d)"
trap 'rm -rf "$FX"' EXIT
run_in() {
  local dir="$1" content="$2"
  shift 2
  printf '%s\n' "$content" > "$FX/queue.md"
  out="$(cd "$dir" && env -u CLAUDE_PROJECT_DIR -u OPERATOR_QUEUE_SHOW_ALL HOME="$FX/nohome" OPERATOR_QUEUE_FILE="$FX/queue.md" "$@" "$HOOK" 2>&1)"
  rc=$?
}
# A throwaway repo named "dotfiles" plus a linked worktree whose directory name
# differs: the worktree still belongs to the dotfiles project.
git init -q "$FX/dotfiles"
git -C "$FX/dotfiles" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$FX/dotfiles" worktree add -q "$FX/wt-agent-123" 2>/dev/null
mkdir -p "$FX/dotfiles/sub/dir" "$FX/plain/stringer"

MIXED="## dot-one
- added: $D5
- project: dotfiles
- action: dotfiles thing one

## dot-compound
- added: $D45
- project: dotfiles / Codex Remote
- action: compound project names match on any word

## str-old
- added: $D90
- project: stringer
- action: stringer old thing

## str-due
- added: $D5
- project: stringer
- deadline: $F10
- action: stringer upcoming

## str-overdue
- added: $D29
- project: stringer
- deadline: $P3
- action: stringer overdue

## atlas-one
- added: $D31
- project: atlas
- action: atlas thing

## orphan
- added: $D5
- action: no project line"

run_in "$FX/dotfiles" "$MIXED"
assert "filter: exits 0" "[ $rc -eq 0 ]"
assert "filter: own project items print in full" "line_for dot-one | grep -qF 'dotfiles thing one'"
assert "filter: compound project value matches a word" "line_for dot-compound | grep -qF 'compound project'"
assert "filter: other project's past-due item prints in full" "outgrep '[PAST DUE $P3] str-overdue — stringer overdue'"
assert "filter: other project's current items do not print" "! line_for str-old && ! line_for str-due && ! line_for atlas-one"
assert "filter: summary line with oldest age and next deadline" "outgrep '  stringer: 2 items (oldest 90d, next deadline $F10)'"
assert "filter: summary line without a deadline omits it" "outgrep '  atlas: 1 item (oldest 31d)'"
assert "filter: item with no project is summarized" "outgrep '  (no project): 1 item (oldest 5d)'"
assert "filter: header still counts the whole queue" "outgrep 'Operator action queue — 7 open item(s)'"
assert "filter: names the session project" "outgrep 'for dotfiles'"
assert "filter: footer names the queue file and the show-all switch" "outgrep \"$FX/queue.md\" && outgrep 'OPERATOR_QUEUE_SHOW_ALL=1'"
summary_order() { printf '%s\n' "$out" | grep -E '^  [^ ].*: [0-9]+ items? ' | cut -d: -f1 | tr -d ' ' | tr '\n' ,; }
assert "filter: summarized projects sorted by name" "[ \"\$(summary_order)\" = '(noproject),atlas,stringer,' ]"

run_in "$FX/wt-agent-123" "$MIXED"
assert "worktree: repo name comes from the main checkout" "line_for dot-one && ! line_for str-old"
run_in "$FX/dotfiles/sub/dir" "$MIXED"
assert "subdirectory: repo name comes from the toplevel" "line_for dot-one && ! line_for str-old"

run_in "$FX/plain/stringer" "$MIXED"
assert "no git repo: cwd basename is the project" "line_for str-old && line_for str-due && ! line_for dot-one"
assert "no git repo: dotfiles summarized" "outgrep '  dotfiles: 2 items (oldest 45d)'"

run_in "$FX/dotfiles" "$MIXED" CLAUDE_PROJECT_DIR="$FX/plain/stringer"
assert "CLAUDE_PROJECT_DIR wins over the cwd" "line_for str-old && ! line_for dot-one"

run_in "$FX/dotfiles" "$MIXED" OPERATOR_QUEUE_SHOW_ALL=1
assert "show-all: every item prints" "line_for str-old && line_for atlas-one && line_for orphan && line_for dot-one"
assert "show-all: no summary lines" "! outgrep '  stringer: '"

run_in "$FX/plain/stringer" "## only-dotfiles
- added: $D5
- project: dotfiles
- action: nothing for this repo"
assert "no matching items: says so and summarizes" "outgrep 'none for stringer' && outgrep '  dotfiles: 1 item (oldest 5d)'"

run_in "$FX/dotfiles" ""
assert "filter: empty queue stays silent" "[ -z \"\$out\" ] && [ $rc -eq 0 ]"

run_in "$FX/dotfiles" "## broken-item
garbage line without a field
- project:
- added: not-a-date
- deadline: someday

## dot-ok
- added: $D5
- project: dotfiles
- action: still rendered"
assert "malformed: exits 0" "[ $rc -eq 0 ]"
assert "malformed: good item still rendered" "line_for dot-ok | grep -qF 'still rendered'"
assert "malformed: bad item summarized without an age" "outgrep '  (no project): 1 item' && ! outgrep '(no project): 1 item (oldest'"

# A tab inside a field value must not shift the record columns (Codex gate).
run_in "$FX/dotfiles" "## tab-annotated
- added: $D5	(checked)
- project: atlas
- deadline: $F10	(soft)
- action: tab	separated" OPERATOR_QUEUE_SHOW_ALL=1
assert "tab in a field: item still rendered" "line_for tab-annotated | grep -qF 'tab separated'"

# Truncation keeps whole multi-byte characters: "a" + 3-byte characters puts
# the byte cut mid-character, and only that partial character may go.
cjk_action="a$(printf '確認%.0s' $(seq 1 200))"
run_in "$FX/dotfiles" "## dot-cjk
- added: $D5
- project: dotfiles
- action: $cjk_action"
assert "utf-8 truncation keeps complete characters" "line_for dot-cjk | grep -qF 'a確認確認' && line_for dot-cjk | grep -qF '… [truncated'"
assert "utf-8 truncation leaves valid UTF-8" "line_for dot-cjk | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1"

# Summary lines are capped like item lines (Codex gate): many distinct
# projects collapse to a bounded list plus one "…and N more" line.
many=""
for i in $(seq 1 40); do many="$many
## many-$i
- added: $D5
- project: proj$(printf '%02d' "$i")
- action: x"; done
run_in "$FX/dotfiles" "$many"
assert "summary: capped at the item cap" "[ \"\$(summary_order | tr ',' '\n' | grep -c .)\" -eq 20 ]"
assert "summary: overflow line counts the rest" "outgrep '  …and 20 more projects'"
# Show-all is not capped (Codex thread on #567): every item past MAX_ITEMS prints.
run_in "$FX/dotfiles" "$many" OPERATOR_QUEUE_SHOW_ALL=1
assert "show-all: items past the cap still print" "line_for many-21 && line_for many-40 && ! outgrep 'more — see'"

# Every line is bounded, not only the action: a huge slug or project name.
long_word="$(printf 'y%.0s' $(seq 1 3000))"
run_in "$FX/dotfiles" "## dot-$long_word
- added: $D5
- project: dotfiles
- action: short

## other
- added: $D5
- project: $long_word
- action: short"
assert "line cap: no output line over the cap" "[ \"\$(printf '%s\n' \"\$out\" | awk '{ if (length(\$0) > m) m = length(\$0) } END { print m + 0 }')\" -lt 1200 ]"

# A parse that fails outright degrades to one warning line, still exit 0.
mkdir -p "$FX/brokenawk"
printf '#!/bin/sh\nexit 2\n' > "$FX/brokenawk/awk"
chmod +x "$FX/brokenawk/awk"
run_in "$FX/dotfiles" "$MIXED" PATH="$FX/brokenawk:$PATH"
assert "parse failure: one warning line, exit 0" "[ $rc -eq 0 ] && [ \"\$(printf '%s\n' \"\$out\" | wc -l)\" -eq 1 ] && outgrep 'could not parse'"

long_action="$(printf 'x%.0s' $(seq 1 900))"
run_in "$FX/dotfiles" "## dot-long
- added: $D5
- project: dotfiles
- action: $long_action"
assert "long action truncated" "line_for dot-long | grep -qF '… [truncated; full text in the queue file]' && [ \"\$(line_for dot-long | wc -c)\" -lt 800 ]"

# ── issue source ────────────────────────────────────────────────────────
iso() { date -u -d "$1 days" +%Y-%m-%dT%H:%M:%SZ; }
ISSUES="$FX/issues.json"
cat > "$ISSUES" <<JSON
[
  {"number": 12, "title": "dot-issue", "createdAt": "$(iso -45)",
   "labels": [{"name": "operator-action"}, {"name": "project:dotfiles"}],
   "comments": [{"createdAt": "$(iso -20)"}, {"createdAt": "$(iso -5)"}],
   "body": "- action: approve the dotfiles thing\r\n- deadline: $P3\r\n\r\nMore context."},
  {"number": 13, "title": "str-issue", "createdAt": "$(iso -1)",
   "labels": [{"name": "operator-action"}], "comments": [],
   "body": "- added: $D90\n- verified: $(day -60) (owning issue open)\n- project: stringer\nRotate the stringer credential."},
  {"number": 14, "title": "bare-issue", "createdAt": "$(iso -2)",
   "labels": [{"name": "operator-action"}], "body": null}
]
JSON
IH="$FX/ihome"
# run_issues [VAR=val...] — no OPERATOR_QUEUE_FILE, HOME=$IH, cwd = the dotfiles
# fixture, refresh inline (OPERATOR_QUEUE_REFRESH_SYNC=1) unless a case
# overrides it, so each assertion sees the refresh's result.
run_issues() {
  out="$(cd "$FX/dotfiles" && env -u CLAUDE_PROJECT_DIR -u OPERATOR_QUEUE_SHOW_ALL -u OPERATOR_QUEUE_FILE \
    HOME="$IH" FAKE_GH_LOG="$FX/gh.log" OPERATOR_QUEUE_REFRESH_SYNC=1 "$@" "$HOOK" 2>&1)"
  rc=$?
}
hexkey() { printf '%s' "$1" | sha256sum | cut -c1-64; }
CACHEF="$IH/.local/state/operator-queue/issues-$(hexkey github.com/jckeen/claude-memory).md"
fresh_home() { rm -rf "$IH"; mkdir -p "$IH/.claude"; : > "$FX/gh.log"; }

fresh_home
run_issues FAKE_GH_JSON="$ISSUES"
assert "issues: exits 0" "[ $rc -eq 0 ]"
assert "issues: one GraphQL query against the explicit host and repo" "grep -qF 'api graphql --hostname github.com --paginate -f owner=jckeen -f name=claude-memory' '$FX/gh.log' && grep -qF 'labels: [\"operator-action\"]' '$FX/gh.log'"
assert "issues: header names the issue source; stale count uses body and comment dates" "outgrep '3 open item(s), 1 stale (>30d since added/verified) in operator-action issues in github.com/jckeen/claude-memory:'"
assert "issues: project label, body deadline/action, newest comment as verified" "outgrep '[PAST DUE $P3] dot-issue (#12) — approve the dotfiles thing (project: dotfiles, added 45d ago, verified 5d ago)'"
assert "issues: body project line and first-line action" "outgrep '  stringer: 1 item (oldest 90d)'"
assert "issues: null body renders a placeholder action, unscoped" "outgrep '  (no project): 1 item (oldest 2d)'"
assert "issues: footer names the gh command" "outgrep 'gh issue list -R github.com/jckeen/claude-memory --label operator-action --limit 1000'"
assert "issues: trailer asks for a comment and close-when-done" "outgrep 'comment on the issue' && outgrep 'close it only when it is done'"
assert "issues: cache written owner-only" "[ -f '$CACHEF' ] && [ \"\$(stat -c %a '$CACHEF')\" = 600 ]"

run_issues FAKE_GH_JSON="$ISSUES" OPERATOR_QUEUE_SHOW_ALL=1
assert "issues: show-all renders the stale body-project item" "outgrep '$STALE str-issue (#13) — Rotate the stringer credential. (project: stringer, added 90d ago, verified 60d ago)'"
assert "issues: show-all renders the bodiless item, fresh by creation date" "outgrep '  bare-issue (#14) — (no action line) (added 2d ago)'"

: > "$FX/gh.log"
run_issues
assert "issues: fresh cache is rendered without calling gh" "[ ! -s '$FX/gh.log' ] && outgrep 'dot-issue (#12)' && ! outgrep 'cached'"

touch -d '2 hours ago' "$CACHEF"
run_issues
assert "issues: old cache + failed refresh says GitHub is unreachable" "outgrep 'cached 120 min ago; the last refresh failed' && outgrep 'dot-issue (#12)'"
touch -d '2 hours ago' "$CACHEF"
run_issues FAKE_GH_JSON="$ISSUES"
assert "issues: a successful refresh replaces the old cache and clears the failure" "! outgrep 'cached' && [ ! -e '$CACHEF.failed' ] && [ \"\$(( \$(date +%s) - \$(stat -c %Y '$CACHEF') ))\" -lt 60 ]"

printf '> **Historical** — point-in-time record (2026-10-17). Do not act on this.\n\n## old-file-item\n- added: %s\n- project: dotfiles\n- action: from the retired file\n' "$D5" > "$IH/.claude/operator-queue.md"
rm -f "$CACHEF"
run_issues FAKE_GH_JSON="$ISSUES"
assert "historical queue file: issues are the source" "outgrep 'dot-issue (#12)' && ! outgrep 'old-file-item'"
printf '# queue\n\n## live-file-item\n- added: %s\n- project: dotfiles\n- action: from the live file\n' "$D5" > "$IH/.claude/operator-queue.md"
: > "$FX/gh.log"
run_issues FAKE_GH_JSON="$ISSUES"
assert "live queue file: stays the source, gh not called" "outgrep 'live-file-item' && ! outgrep 'dot-issue' && [ ! -s '$FX/gh.log' ]"
printf '## live-first\n- added: %s\n- project: dotfiles\n- action: Add the > **Historical** banner to the retired guide.\n' "$D5" > "$IH/.claude/operator-queue.md"
: > "$FX/gh.log"
run_issues FAKE_GH_JSON="$ISSUES"
assert "a banner mention inside an action does not retire the file" "outgrep 'live-first' && [ ! -s '$FX/gh.log' ]"
: > "$IH/.claude/operator-queue.md"
run_issues FAKE_GH_JSON="$ISSUES"
assert "a zero-byte live file stays the source (silent, gh not called)" "[ -z \"\$out\" ] && [ ! -s '$FX/gh.log' ]"

fresh_home
run_issues
assert "no cache, refresh failed: one warning line" "[ \"\$(printf '%s\n' \"\$out\" | wc -l)\" -eq 1 ] && outgrep 'could not list operator-action issues in github.com/jckeen/claude-memory'"

fresh_home
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
assert "issues: no open issues, fresh: silent" "[ -z \"\$out\" ] && [ $rc -eq 0 ]"
touch -d '2 hours ago' "$CACHEF"
run_issues
assert "empty old cache + failed refresh is not silent" "outgrep 'no open operator-action issues in github.com/jckeen/claude-memory as of the last good fetch (cached 120 min ago; the last refresh failed'"

# A failure in the same second as the success before it still shows: the
# marker's existence, not its timestamp, says the latest refresh failed.
fresh_home
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
( cd "$FX/dotfiles" && env -u FAKE_GH_JSON HOME="$IH" "$HOOK" --refresh )
run_issues
assert "same-second failure after an empty success is not silent" "outgrep 'as of the last good fetch (cached 0 min ago; the last refresh failed'"

# A marker or cache stamped after the hook read the clock (a refresh running
# alongside it) still counts: presence decides, not a possibly negative age.
fresh_home
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
touch "$CACHEF.failed"; touch -d '+1 minute' "$CACHEF.failed"
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
assert "a future-stamped failure marker is not ignored" "outgrep 'the last refresh failed'"
fresh_home
run_issues FAKE_GH_JSON="$ISSUES"
touch -d '+1 minute' "$CACHEF"
: > "$FX/gh.log"
run_issues
assert "a future-stamped cache is a cache, not 'no cache'" "outgrep 'dot-issue (#12)' && ! outgrep 'no cache'"

# Killing the refresh shell mid-fetch does not free the lock while its gh
# still runs, so no second fetch overlaps it.
fresh_home
( cd "$FX/dotfiles" && exec env HOME="$IH" FAKE_GH_JSON="$ISSUES" FAKE_GH_SLEEP=7 FAKE_GH_LOG="$FX/gh.log" bash "$HOOK" --refresh ) &
victim=$!
for _ in $(seq 1 60); do [ -s "$FX/gh.log" ] && break; sleep 0.05; done
kill -9 "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
( cd "$FX/dotfiles" && env HOME="$IH" FAKE_GH_JSON="$ISSUES" FAKE_GH_LOG="$FX/gh.log" bash "$HOOK" --refresh )
assert "a killed refresh's live gh still holds the lock" "[ \"\$(grep -c graphql '$FX/gh.log')\" -eq 1 ]"
# Let the orphaned gh finish before the next case touches the same paths.
for _ in $(seq 1 200); do grep -q gh-done "$FX/gh.log" && break; sleep 0.05; done

# A refresh killed mid-fetch whose gh then fails leaves no FAILED, but its
# INFLIGHT marker keeps the empty cache from reading as "nothing open".
fresh_home
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
: > "$FX/gh.log"
( cd "$FX/dotfiles" && exec env -u FAKE_GH_JSON HOME="$IH" FAKE_GH_SLEEP=1 FAKE_GH_LOG="$FX/gh.log" bash "$HOOK" --refresh ) &
victim=$!
for _ in $(seq 1 60); do grep -q graphql "$FX/gh.log" && break; sleep 0.05; done
kill -9 "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
for _ in $(seq 1 80); do flock -n "$CACHEF.lock" true && break; sleep 0.05; done
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
assert "a killed refresh whose gh failed is reported, not silent" "[ ! -f '$CACHEF.failed' ] && [ -f '$CACHEF.inflight' ] && outgrep 'as of the last good fetch (cached 0 min ago; a refresh is running or was interrupted)'"

# Many sessions starting at once all see the orphaned marker (readers take no
# lock, so none can mistake another for a running refresh).
mkdir -p "$FX/readers"
for i in $(seq 1 24); do
  ( cd "$FX/dotfiles" && env -u CLAUDE_PROJECT_DIR -u OPERATOR_QUEUE_SHOW_ALL -u OPERATOR_QUEUE_FILE \
      HOME="$IH" OPERATOR_QUEUE_REFRESH_SYNC=1 "$HOOK" > "$FX/readers/$i" 2>&1 ) &
done
wait
assert "concurrent readers all report the killed refresh" "[ \"\$(grep -l 'a refresh is running or was interrupted' '$FX'/readers/* | wc -l)\" -eq 24 ]"

# GitHub names are case-insensitive: O/R and o/r share one cache.
fresh_home
run_issues FAKE_GH_JSON="$ISSUES" OPERATOR_QUEUE_REPO=JCKEEN/Claude-Memory
: > "$FX/gh.log"
run_issues
assert "a case variant of the repo reuses its cache" "[ -f '$CACHEF' ] && [ ! -s '$FX/gh.log' ] && outgrep 'dot-issue (#12)'"

fresh_home
run_issues FAKE_GH_JSON="$ISSUES"
run_issues OPERATOR_QUEUE_REPO=other/queue
assert "cache is per repo: another repo never shows the first one's items" "! outgrep 'dot-issue' && outgrep 'could not list operator-action issues in github.com/other/queue'"
run_issues OPERATOR_QUEUE_REPO=ghe.example.com/jckeen/claude-memory
assert "cache is per host: another host never shows the first one's items" "! outgrep 'dot-issue' && outgrep 'could not list' && grep -qF -- '--hostname ghe.example.com' '$FX/gh.log'"

# Names a character substitution would merge get separate caches.
cat > "$FX/one.json" <<JSON
[{"number": 50, "title": "only-in-first", "createdAt": "$(iso -1)", "labels": [], "comments": [], "body": "- action: a"}]
JSON
fresh_home
run_issues FAKE_GH_JSON="$FX/one.json" OPERATOR_QUEUE_REPO=mona-cat_octo/queue
: > "$FX/gh.log"
run_issues OPERATOR_QUEUE_REPO=mona-cat/octo_queue
assert "cache key is injective: a_b/c and a/b_c never share a cache" "! outgrep 'only-in-first' && [ -s '$FX/gh.log' ]"

# Long repo names: the key is fixed-length (a hex dump would pass NAME_MAX),
# and names sharing a long prefix never share a cache (od folds repeated rows).
long_a="github.com/o/$(printf 'a%.0s' $(seq 1 200))"
long_b="github.com/o/$(printf 'a%.0s' $(seq 1 199))b"
fresh_home
run_issues FAKE_GH_JSON="$FX/one.json" OPERATOR_QUEUE_REPO="$long_a" OPERATOR_QUEUE_SHOW_ALL=1
assert "a 200-char repo name still gets a cache" "outgrep 'only-in-first (#50)'"
: > "$FX/gh.log"
run_issues FAKE_GH_JSON="$ISSUES" OPERATOR_QUEUE_REPO="$long_b" OPERATOR_QUEUE_SHOW_ALL=1
assert "long names with a shared prefix never share a cache" "! outgrep 'only-in-first' && outgrep 'dot-issue (#12)' && [ -s '$FX/gh.log' ]"

# A held lock is never taken over, however old it is; once its holder exits
# the kernel drops it and the next refresh runs.
LOCKF="$IH/.local/state/operator-queue/issues-$(hexkey github.com/jckeen/claude-memory).md.lock"
fresh_home
mkdir -p "${LOCKF%/*}"
( exec 8>> "$LOCKF"; flock 8; exec sleep 30 ) & holder=$!   # the sleep itself holds the lock
for _ in $(seq 1 50); do flock -n "$LOCKF" true || break; sleep 0.05; done
touch -d '1 hour ago' "$LOCKF"
: > "$FX/gh.log"
run_issues FAKE_GH_JSON="$ISSUES"
assert "a held lock blocks a second refresh" "[ ! -s '$FX/gh.log' ] && [ ! -f '$CACHEF' ]"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
for _ in $(seq 1 50); do flock -n "$LOCKF" true && break; sleep 0.05; done
run_issues FAKE_GH_JSON="$ISSUES"
assert "a dead holder's lock is free again" "[ -s '$FX/gh.log' ] && outgrep 'dot-issue (#12)'"

# Refreshes never overlap: one started while a slow one is fetching waits for
# it, then fetches, so the newer fetch is the one that lands.
fresh_home
run_issues FAKE_GH_JSON="$ISSUES"
touch -d '2 hours ago' "$CACHEF"
: > "$FX/gh.log"
( cd "$FX/dotfiles" && HOME="$IH" PATH="$FAKEBIN:$PATH" FAKE_GH_JSON="$FX/one.json" FAKE_GH_SLEEP=1.5 FAKE_GH_LOG="$FX/gh.log" "$HOOK" --refresh ) &
slow=$!
for _ in $(seq 1 50); do [ -s "$FX/gh.log" ] && break; sleep 0.05; done
( cd "$FX/dotfiles" && HOME="$IH" PATH="$FAKEBIN:$PATH" FAKE_GH_JSON="$ISSUES" FAKE_GH_LOG="$FX/gh.log" "$HOOK" --refresh )
wait "$slow"
run_issues OPERATOR_QUEUE_SHOW_ALL=1
assert "a refresh during another one waits, then its newer fetch lands" "[ \"\$(grep -oE '^(api graphql|gh-done)' '$FX/gh.log' | cut -c1-6 | tr '\\n' ' ')\" = 'api gr gh-don api gr gh-don ' ] && outgrep 'dot-issue (#12)' && ! outgrep 'only-in-first'"

# While a killed refresh's gh still holds the lock, and while a successor
# holds it before recording the orphan, the marker is reported at once.
fresh_home
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
: > "$FX/gh.log"
( cd "$FX/dotfiles" && exec env -u FAKE_GH_JSON HOME="$IH" FAKE_GH_SLEEP=3 FAKE_GH_LOG="$FX/gh.log" bash "$HOOK" --refresh ) &
victim=$!
for _ in $(seq 1 60); do grep -q graphql "$FX/gh.log" && break; sleep 0.05; done
kill -9 "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
assert "a killed refresh whose gh still runs is reported, not silent" "! flock -n '$CACHEF.lock' true && outgrep 'a refresh is running or was interrupted'"
for _ in $(seq 1 200); do grep -q gh-done "$FX/gh.log" && break; sleep 0.05; done
fresh_home
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
touch "$CACHEF.inflight"
( exec 8>> "$CACHEF.lock"; flock 8; exec sleep 30 ) & holder=$!
for _ in $(seq 1 50); do flock -n "$CACHEF.lock" true || break; sleep 0.05; done
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
assert "an orphan under a successor's lock is reported, not silent" "outgrep 'a refresh is running or was interrupted'"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# A refresh that swaps in an empty cache and dies after the hook's emptiness
# check cannot silence it: the hook renders the snapshot it checked. The
# swap is injected deterministically by a `wc` wrapper (the renderer's first
# read after the check).
fresh_home
run_issues FAKE_GH_JSON="$ISSUES"
mkdir -p "$FX/swapbin"
cat > "$FX/swapbin/wc" <<SWAP
#!/usr/bin/env bash
if [ ! -e "$FX/swapped" ]; then
  : > "$FX/swapped"
  printf '# Operator-action issues\n' > "$CACHEF.swap" && mv -f "$CACHEF.swap" "$CACHEF"
  touch "$CACHEF.inflight"
fi
exec "$(command -v wc)" "\$@"
SWAP
chmod +x "$FX/swapbin/wc"
run_issues PATH="$FX/swapbin:$PATH"
assert "a cache swapped mid-render does not silence the hook" "[ -e '$FX/swapped' ] && outgrep 'dot-issue (#12)'"
rm -rf "$FX/swapbin" "$FX/swapped"

# A refresh that replaces the cache just before the hook's copy and then dies
# is seen in flight: the state is read after the copy. A `cp` wrapper injects
# the replacement at exactly that point.
fresh_home
run_issues FAKE_GH_JSON="$ISSUES"
mkdir -p "$FX/cpbin"
cat > "$FX/cpbin/cp" <<SWAP
#!/usr/bin/env bash
if [ ! -e "$FX/swapped" ]; then
  : > "$FX/swapped"
  touch "$CACHEF.inflight"
  printf '# Operator-action issues\n' > "$CACHEF.swap" && mv -f "$CACHEF.swap" "$CACHEF"
fi
exec "$(command -v cp)" "\$@"
SWAP
chmod +x "$FX/cpbin/cp"
run_issues PATH="$FX/cpbin:$PATH"
assert "a dead refresh's replacement before the copy is not shown as settled" "[ -e '$FX/swapped' ] && outgrep 'a refresh is running or was interrupted'"
rm -rf "$FX/cpbin" "$FX/swapped"

# No temp dir for the snapshot: a warning line, never silence over a known
# failure.
fresh_home
run_issues FAKE_GH_JSON="$ISSUES"
touch "$CACHEF.failed"
run_issues TMPDIR="$FX/no-such-dir"
assert "snapshot allocation failure is reported" "outgrep 'could not snapshot the operator-action cache'"

# A failed refresh that cannot write FAILED (disk full) keeps INFLIGHT, so
# the failure is still signalled. A `touch` wrapper refuses the marker.
fresh_home
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
touch -d '2 hours ago' "$CACHEF"
mkdir -p "$FX/nofail"
cat > "$FX/nofail/touch" <<'TOUCH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *.failed) exit 1 ;; esac; done
exec /usr/bin/touch "$@"
TOUCH
chmod +x "$FX/nofail/touch"
( cd "$FX/dotfiles" && env -u FAKE_GH_JSON HOME="$IH" PATH="$FX/nofail:$PATH" bash "$HOOK" --refresh )
touch "$CACHEF"
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
assert "a failure that cannot be recorded leaves the in-flight signal" "[ ! -e '$CACHEF.failed' ] && [ -e '$CACHEF.inflight' ] && outgrep 'a refresh is running or was interrupted'"
rm -rf "$FX/nofail"

# The next refresh starting over an orphaned INFLIGHT records its failure
# first, so readers keep reporting it while the new fetch is still running.
fresh_home
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
touch "$CACHEF.inflight"
: > "$FX/gh.log"
( cd "$FX/dotfiles" && exec env HOME="$IH" FAKE_GH_JSON="$FAKEBIN/none.json" FAKE_GH_SLEEP=2 FAKE_GH_LOG="$FX/gh.log" bash "$HOOK" --refresh ) &
next=$!
for _ in $(seq 1 60); do grep -q graphql "$FX/gh.log" && break; sleep 0.05; done
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
assert "during the next fetch, the killed refresh is still reported" "outgrep 'the last refresh failed'"
wait "$next"
run_issues FAKE_GH_JSON="$FAKEBIN/none.json"
assert "once that fetch succeeds, the failure clears" "[ -z \"\$out\" ] && [ ! -e '$CACHEF.failed' ] && [ ! -e '$CACHEF.inflight' ]"

# No digest tool: refused with a warning, never one cache name for every repo.
mkdir -p "$FX/nohash"
for t in bash env cat date mkdir touch rm mv chmod mktemp stat grep sed awk head tr cut sort uniq wc printf jq od seq dirname basename readlink setsid nohup flock timeout; do
  p="$(command -v "$t" 2>/dev/null)" && [ "${p#/}" != "$p" ] && ln -sf "$p" "$FX/nohash/$t"
done
ln -sf "$FAKEBIN/gh" "$FX/nohash/gh"
fresh_home
run_issues FAKE_GH_JSON="$ISSUES" PATH="$FX/nohash"
assert "no sha256sum/shasum: refused, no gh call, no shared cache" "outgrep 'cannot name the operator-action cache' && [ ! -s '$FX/gh.log' ] && [ ! -e '$IH/.local/state/operator-queue/issues-.md' ]"

# No flock: the refresh fails and says so, rather than running unserialised.
mkdir -p "$FX/noflock"
for t in bash env cat date mkdir touch rm mv chmod mktemp stat grep sed awk head tr cut sort uniq wc printf sha256sum jq od seq dirname basename readlink setsid nohup; do
  p="$(command -v "$t" 2>/dev/null)" && [ "${p#/}" != "$p" ] && ln -sf "$p" "$FX/noflock/$t"
done
ln -sf "$FAKEBIN/gh" "$FX/noflock/gh"
fresh_home
: > "$FX/gh.log"
run_issues FAKE_GH_JSON="$ISSUES" PATH="$FX/noflock"
assert "no flock: refresh fails loudly, no gh call" "outgrep 'could not list' && outgrep 'flock missing' && [ ! -s '$FX/gh.log' ]"

cat > "$FX/multi.json" <<JSON
[{"number": 30, "title": "shared-item", "createdAt": "$(iso -3)", "comments": [],
  "labels": [{"name": "operator-action"}, {"name": "project:keen-media"}],
  "body": "- project: keen-media, operator-commons\n- action: shared between two repos"}]
JSON
mkdir -p "$FX/plain/operator-commons"
fresh_home
run_issues FAKE_GH_JSON="$FX/multi.json" CLAUDE_PROJECT_DIR="$FX/plain/operator-commons"
assert "secondary project word in the body still matches its session" "outgrep 'shared-item (#30) — shared between two repos (project: keen-media, operator-commons'"

cat > "$FX/baddate.json" <<JSON
[{"number": 40, "title": "bad-date", "createdAt": "$(iso -90)", "labels": [],
  "comments": [{"createdAt": "$(iso -3)"}],
  "body": "- verified: 2026-99-99\n- action: body date is garbage"}]
JSON
fresh_home
run_issues FAKE_GH_JSON="$FX/baddate.json" OPERATOR_QUEUE_SHOW_ALL=1
assert "an impossible body date does not outrank a real comment" "outgrep 'bad-date (#40) — body date is garbage (added 90d ago, verified 3d ago)' && ! outgrep '$STALE bad-date'"

# Detached refresh: a stalled GitHub costs SessionStart nothing. The hook
# returns at once (its capture is not held by the refresh), says a refresh is
# running, and a later session sees what the refresh wrote.
fresh_home
# shellcheck disable=SC2034 # read inside the eval-ed assert condition
start=$(date +%s)
run_issues OPERATOR_QUEUE_REFRESH_SYNC=0 FAKE_GH_JSON="$ISSUES" FAKE_GH_SLEEP=2
assert "async: the hook returns before a slow refresh finishes" "[ \$(( \$(date +%s) - start )) -lt 2 ] && outgrep 'a refresh is running in the background'"
for _ in $(seq 1 50); do [ -f "$CACHEF" ] && [ ! -e "$CACHEF.inflight" ] && break; sleep 0.1; done
run_issues OPERATOR_QUEUE_REFRESH_SYNC=0
assert "async: the detached refresh wrote the cache for the next session" "outgrep 'dot-issue (#12)' && ! outgrep 'cached'"
touch -d '2 hours ago' "$CACHEF"
: > "$FX/gh.log"
run_issues OPERATOR_QUEUE_REFRESH_SYNC=0 FAKE_GH_JSON="$ISSUES" FAKE_GH_SLEEP=2
# Whether the detached child has marked itself in flight yet is a race; both
# notes are correct, and neither presents the old cache as current.
assert "async: an old cache renders at once, marked as refreshing" "{ outgrep 'cached 120 min ago; refreshing in the background' || outgrep 'cached 120 min ago; a refresh is running or was interrupted'; } && outgrep 'dot-issue (#12)'"
for _ in $(seq 1 50); do [ "$(( $(date +%s) - $(stat -c %Y "$CACHEF") ))" -lt 60 ] && break; sleep 0.1; done

rm -rf "$FAKEBIN"
echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
