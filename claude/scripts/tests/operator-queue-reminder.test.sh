#!/usr/bin/env bash
# operator-queue-reminder.test.sh — fixture tests for OperatorQueueReminder.hook.sh.
# Runs the SessionStart hook against throwaway HOMEs holding crafted
# ~/.claude/operator-queue.md files and asserts the rendered lines: deadline-
# first ordering with past-due flags (unchanged), the `verified:` freshness
# rule (newest of verified/added; >30d or undated → "[stale — re-verify]"),
# and the header's stale count; then the per-project filter (#558): only the
# session repo's items plus past-due ones print in full, every other project
# collapses to one summary line, OPERATOR_QUEUE_SHOW_ALL=1 restores the full
# list, and the repo name falls back to the cwd basename outside git. Run
# directly; exit 1 on any failure.
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
run_hook ""
assert "empty queue: silent" "[ -z \"\$out\" ] && [ $rc -eq 0 ]"
H="$(mktemp -d)"
out="$(env -u CLAUDE_PROJECT_DIR -u OPERATOR_QUEUE_FILE HOME="$H" "$HOOK" 2>&1)"; rc=$?
assert "absent queue: silent" "[ -z \"\$out\" ] && [ $rc -eq 0 ]"
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

echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
