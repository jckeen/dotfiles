#!/usr/bin/env bash
# migrate-operator-queue.test.sh — fixture tests for migrate-operator-queue.sh.
# A fake `gh` first on PATH records every call and answers from fixture files,
# so nothing reaches GitHub. Asserts: a non-private repo is refused in both
# modes; the dry run lists one row per block and makes no write call; --apply
# creates the missing labels and one issue per new block, with the block's
# field lines verbatim in the body and the project label from the first word
# of `project:`; a block whose title already has an issue (whatever its
# labels) is skipped. Run
# directly; exit 1 on any failure.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/migrate-operator-queue.sh"
FX="$(mktemp -d)"
trap 'rm -rf "$FX"' EXIT
mkdir -p "$FX/bin" "$FX/bodies"

# Fake gh: `repo view` prints $FAKE_VIS; `issue list` prints existing titles;
# `label list` prints existing labels; writes are logged, and an issue create
# copies its --body-file so the body can be checked afterwards.
cat > "$FX/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "repo view")    echo "$FAKE_VIS ${FAKE_NWO:-o/r}" ;;
  # The script's -q program emits typed records (see the fixtures below);
  # gh's --label filters, so the second set is listed only without it.
  "issue list")   cat "$FAKE_ISSUES_LABELLED"
                  case " $* " in *" --label "*) ;; *) cat "$FAKE_ISSUES_OTHER" ;; esac ;;
  "issue edit")   [ -z "${FAKE_EDIT_FAIL:-}" ] || { echo "HTTP 403" >&2; exit 1; } ;;
  "label list")   printf 'operator-action\n' ;;
  "label create") : ;;
  "issue create")
    while [ $# -gt 0 ]; do
      if [ "$1" = "--title" ]; then t="$2"; fi
      if [ "$1" = "--body-file" ]; then cp "$2" "$FAKE_BODIES/$t"; fi
      shift
    done
    echo "https://github.com/o/r/issues/$(( $(grep -c '^issue create' "$FAKE_LOG") + 100 ))" ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
GH
chmod +x "$FX/bin/gh"
# Existing issues as the script's -q program renders them: "T title number
# has-operator-action", one "L number label" per label and one "A number
# line" per `- action:` body line, TAB-separated.
rec() { local IFS=$'\t'; printf '%s\n' "$*"; }
{
  rec T already-there 7 true; rec L 7 operator-action; rec L 7 project:stringer; rec A 7 '- action: exists as #7'
  rec T 'rotate-\token' 8 true; rec L 8 operator-action; rec A 8 '- action: exists as #8'
  rec T 001 9 true; rec L 9 operator-action
  rec T 100 10 true; rec L 10 operator-action
} > "$FX/issues-labelled"
{
  rec T unlabelled-dupe 11 false; rec A 11 '- action: exists as #11, label removed'
  rec T half-labelled 12 false; rec L 12 project:dotfiles; rec A 12 '- action: has its project label only'
  # One label whose name contains a comma: not the operator-action label.
  rec T comma-label 13 false; rec L 13 'team,operator-action'; rec A 13 '- action: comma label only'
  # Filed by hand: labelled, but no queue fields in its body.
  rec T hand-filed 14 true; rec L 14 operator-action
} > "$FX/issues-other"
export FAKE_ISSUES_LABELLED="$FX/issues-labelled" FAKE_ISSUES_OTHER="$FX/issues-other"
export PATH="$FX/bin:$PATH" FAKE_LOG="$FX/gh.log" FAKE_BODIES="$FX/bodies"
export XDG_STATE_HOME="$FX/state"
unset OPERATOR_QUEUE_REPO

cat > "$FX/queue.md" <<'Q'
# Operator-action queue

Preamble lines are not an item.

## dot-thing
- added: 2026-07-01
- verified: 2026-10-01 (re-checked)
- project: dotfiles / Codex Remote
- action: do the dotfiles thing

## already-there
- added: 2026-08-01
- project: stringer
- action: exists as #7

## no-project-item
- added: 2026-09-01
- action: unscoped thing
Q

pass=0; failed=0; out=""; rc=0
assert() {
  if eval "$2"; then pass=$((pass + 1)); echo "ok   - $1"
  else failed=$((failed + 1)); echo "FAIL - $1 (condition: $2)"; printf '%s\n' "$out" | sed 's/^/      | /'; fi
}
run() { : > "$FAKE_LOG"; out="$(FAKE_VIS="$1" bash "$SCRIPT" --queue "$FX/queue.md" --repo o/r "${@:2}" 2>&1)"; rc=$?; }
writes() { grep -cE '^(label|issue) create' "$FAKE_LOG"; }

run PUBLIC
assert "public repo refused (dry run)" "[ $rc -eq 1 ] && grep -qF 'refusing: github.com/o/r is PUBLIC' <<<\"\$out\" && [ \"\$(writes)\" -eq 0 ]"
run PUBLIC --apply
assert "public repo refused (apply), nothing written" "[ $rc -eq 1 ] && [ \"\$(writes)\" -eq 0 ]"

run PRIVATE
assert "dry run exits 0" "[ $rc -eq 0 ]"
assert "dry run: no write call" "[ \"\$(writes)\" -eq 0 ]"
assert "dry run: new block with its label" "grep -qE '^dot-thing +project:dotfiles +new$' <<<\"\$out\""
assert "dry run: existing title skipped" "grep -qE '^already-there +project:stringer +#7 \\(exists, skipped\\)$' <<<\"\$out\""
assert "dry run: unscoped block has no label" "grep -qE '^no-project-item +\\(none\\) +new$' <<<\"\$out\""
assert "dry run: summary counts" "grep -qF '3 item(s): 2 would be created, 1 already have an issue (0 would be relabelled, 0 need a manual merge).' <<<\"\$out\""

run PRIVATE --apply
assert "apply exits 0" "[ $rc -eq 0 ]"
assert "apply: missing project labels created, existing operator-action not" "grep -qx 'label create project:dotfiles -R github.com/o/r --color C5DEF5' '$FAKE_LOG' && grep -qx 'label create project:stringer -R github.com/o/r --color C5DEF5' '$FAKE_LOG' && ! grep -q 'label create operator-action' '$FAKE_LOG'"
assert "apply: two issues created, none for the existing title" "[ \"\$(grep -c '^issue create' '$FAKE_LOG')\" -eq 2 ] && ! grep -q -- '--title already-there' '$FAKE_LOG'"
assert "apply: scoped issue carries both labels" "grep -q -- '--title dot-thing --label operator-action --body-file .* --label project:dotfiles' '$FAKE_LOG'"
assert "apply: unscoped issue carries only operator-action" "grep -- '--title no-project-item' '$FAKE_LOG' | grep -qv 'project:'"
assert "apply: body keeps the field lines verbatim" "grep -qxF -- '- verified: 2026-10-01 (re-checked)' '$FX/bodies/dot-thing' && grep -qxF -- '- added: 2026-07-01' '$FX/bodies/dot-thing' && ! grep -q '^## ' '$FX/bodies/dot-thing'"
assert "apply: body notes the migration" "grep -q '^Migrated from ~/.claude/operator-queue.md on ' '$FX/bodies/dot-thing'"

# Same-queue repeats and a backslash title already on GitHub: no duplicate creates.
printf '## repeated\n- action: one\n\n## repeated\n- action: two\n\n## rotate-\\token\n- action: exists as #8\n' > "$FX/dupes.md"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/dupes.md" --repo o/r --apply 2>&1)"; rc=$?
# The second "repeated" block has a different action, so it is not adopted
# into the first one's issue (its action would be lost): manual merge, rc 1.
assert "apply: a title repeated in the queue is created once" "[ $rc -eq 1 ] && [ \"\$(grep -c -- '--title repeated' '$FAKE_LOG')\" -eq 1 ] && grep -qE '^repeated +\\(none\\) +needs manual merge: #[0-9]+ ' <<<\"\$out\""
assert "apply: a backslash title matches its existing issue" "! grep -q -- '--title rotate-' '$FAKE_LOG' && grep -qF '#8 (exists, skipped)' <<<\"\$out\""

# A same-title issue without the operator-action label (removed after a
# partial migration, or filed by hand) is still found: no duplicate, rerun-safe.
printf '## unlabelled-dupe\n- project: stringer\n- action: exists as #11, label removed\n' > "$FX/unlabelled.md"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/unlabelled.md" --repo o/r --apply 2>&1)"; rc=$?
assert "apply: an unlabelled same-title issue is matched, not duplicated" "[ $rc -eq 0 ] && ! grep -q -- '--title unlabelled-dupe' '$FAKE_LOG' && grep -qF '#11 (exists, relabelled #11: operator-action,project:stringer)' <<<\"\$out\""
assert "the title check lists issues regardless of label" "grep '^issue list' '$FAKE_LOG' | grep -qv -- '--label'"
# The hook reads only operator-action issues, so a matched issue lacking the
# migration's labels gets them: otherwise retiring the file would drop the
# item silently.
assert "apply: the matched issue gets operator-action and its project label, pinned host" "grep -qx 'issue edit 11 -R github.com/o/r --add-label operator-action,project:stringer' '$FAKE_LOG'"
assert "apply: the summary counts the relabel and still offers retirement" "grep -qF '1 relabelled' <<<\"\$out\" && grep -qF 'Then retire the file' <<<\"\$out\""
printf '## half-labelled\n- project: dotfiles\n- action: has its project label only\n\n## already-there\n- project: stringer\n- action: exists as #7\n' > "$FX/half.md"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/half.md" --repo o/r 2>&1)"; rc=$?
assert "dry run: only reports 'would relabel #N', no write" "[ $rc -eq 0 ] && grep -qF 'would relabel #12: operator-action)' <<<\"\$out\" && ! grep -q '^issue edit' '$FAKE_LOG'"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/half.md" --repo o/r --apply 2>&1)"; rc=$?
assert "apply: only the missing labels are added; a fully labelled issue is left alone" "[ $rc -eq 0 ] && grep -qx 'issue edit 12 -R github.com/o/r --add-label operator-action' '$FAKE_LOG' && ! grep -q '^issue edit 7 ' '$FAKE_LOG'"
# A relabel that fails is a failed migration: non-zero exit, and no
# instruction to retire the file over an item the hook would not show.
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE FAKE_EDIT_FAIL=1 bash "$SCRIPT" --queue "$FX/half.md" --repo o/r --apply 2>&1)"; rc=$?
assert "apply: a failed relabel fails the run and suppresses the retire message" "[ $rc -eq 1 ] && grep -qF 'could not relabel #12' <<<\"\$out\" && ! grep -qF 'retire the file' <<<\"\$out\""

# Label boundaries: a label named "team,operator-action" is not operator-action.
printf '## comma-label\n- action: comma label only\n' > "$FX/comma.md"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/comma.md" --repo o/r --apply 2>&1)"; rc=$?
assert "apply: a comma-containing label does not count as operator-action" "[ $rc -eq 0 ] && grep -qx 'issue edit 13 -R github.com/o/r --add-label operator-action' '$FAKE_LOG'"

# A hand-filed same-title issue without the block's action line is never
# adopted: reported for a manual merge, left unmigrated, run fails on apply.
printf '## hand-filed\n- deadline: 2026-12-01\n- action: do the hand-filed thing\n' > "$FX/hand.md"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/hand.md" --repo o/r 2>&1)"; rc=$?
assert "dry run: a hand-filed match is reported as needing a manual merge" "[ $rc -eq 0 ] && grep -qF 'needs manual merge: #14' <<<\"\$out\" && ! grep -q '^issue edit' '$FAKE_LOG'"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/hand.md" --repo o/r --apply 2>&1)"; rc=$?
assert "apply: a hand-filed match fails the run, is not edited or recreated, no retire message" "[ $rc -eq 1 ] && grep -qF 'needs manual merge: #14' <<<\"\$out\" && ! grep -qE '^issue (edit|create)' '$FAKE_LOG' && ! grep -qF 'retire the file' <<<\"\$out\""

# Numeric-looking titles compare as strings: "1" is not "001", "1e2" is not "100".
printf '## 1\n- action: one\n\n## 1e2\n- action: hundred\n' > "$FX/numeric.md"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/numeric.md" --repo o/r --apply 2>&1)"; rc=$?
assert "apply: numeric-looking titles are not matched numerically" "[ $rc -eq 0 ] && grep -q -- '--title 1 --label' '$FAKE_LOG' && grep -q -- '--title 1e2 --label' '$FAKE_LOG'"

assert "a bare owner/name is pinned to github.com for every gh call" "! grep -qE -- '-R o/r( |$)' '$FAKE_LOG' && grep -qF -- 'repo view github.com/o/r' '$FAKE_LOG'"

# A queue with no project anywhere: --apply must not abort on the empty label list.
printf '## lone\n- added: 2026-09-01\n- action: unscoped only\n' > "$FX/unscoped.md"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/unscoped.md" --repo o/r --apply 2>&1)"; rc=$?
assert "apply: all-unscoped queue creates its issue" "[ $rc -eq 0 ] && grep -q -- '--title lone --label operator-action' '$FAKE_LOG'"

# With no --repo, the hook's OPERATOR_QUEUE_REPO is the target.
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE OPERATOR_QUEUE_REPO=o/hook-repo bash "$SCRIPT" --queue "$FX/queue.md" 2>&1)"; rc=$?
assert "no --repo: OPERATOR_QUEUE_REPO is the target" "[ $rc -eq 0 ] && grep -qF 'repo view github.com/o/hook-repo' '$FAKE_LOG'"

# A second --apply for the same repo refuses while one holds the lock, before
# any write; a dry run is unaffected.
key="$(printf '%s' github.com/o/r | sha256sum | cut -c1-64)"   # GitHub's lowercased name
mkdir -p "$XDG_STATE_HOME/operator-queue"
( exec 8>> "$XDG_STATE_HOME/operator-queue/migrate-$key.lock"; flock 8; exec sleep 30 ) & holder=$!
for _ in $(seq 1 50); do flock -n "$XDG_STATE_HOME/operator-queue/migrate-$key.lock" true || break; sleep 0.05; done
run PRIVATE --apply
assert "concurrent apply refused with no write" "[ $rc -eq 1 ] && grep -qF 'another --apply for github.com/o/r is running' <<<\"\$out\" && [ \"\$(writes)\" -eq 0 ]"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE FAKE_NWO=O/R bash "$SCRIPT" --queue "$FX/queue.md" --repo O/R --apply 2>&1)"; rc=$?
assert "a case variant of the repo shares the lock" "[ $rc -eq 1 ] && grep -qF 'is running' <<<\"\$out\" && [ \"\$(writes)\" -eq 0 ]"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE FAKE_NWO=o/r bash "$SCRIPT" --queue "$FX/queue.md" --repo o/old-name --apply 2>&1)"; rc=$?
assert "a renamed repo's old name shares the lock" "[ $rc -eq 1 ] && grep -qF 'is running' <<<\"\$out\" && [ \"\$(writes)\" -eq 0 ]"
run PRIVATE
assert "dry run ignores the apply lock" "[ $rc -eq 0 ]"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
run PRIVATE --apply
assert "apply runs once the lock is free" "[ $rc -eq 0 ] && [ \"\$(grep -c '^issue create' '$FAKE_LOG')\" -eq 2 ]"

echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
