#!/usr/bin/env bash
# operator-queue-reminder.test.sh — fixture tests for OperatorQueueReminder.hook.sh.
# Runs the SessionStart hook against throwaway HOMEs holding crafted
# ~/.claude/operator-queue.md files and asserts the rendered lines: deadline-
# first ordering with past-due flags (unchanged), the `verified:` freshness
# rule (newest of verified/added; >30d or undated → "[stale — re-verify]"),
# and the header's stale count. Run directly; exit 1 on any failure.
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

# run_hook <queue-content> — HOME is a throwaway; captures stdout+rc.
run_hook() {
  H="$(mktemp -d)"
  mkdir -p "$H/.claude"
  printf '%s\n' "$1" > "$H/.claude/operator-queue.md"
  out="$(HOME="$H" "$HOOK" 2>&1)"
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
out="$(HOME="$H" "$HOOK" 2>&1)"; rc=$?
assert "absent queue: silent" "[ -z \"\$out\" ] && [ $rc -eq 0 ]"
rm -rf "$H"

echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
