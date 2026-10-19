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
  # gh's --label filters: an issue whose label was removed is listed only
  # by a query without it.
  "issue list")   printf 'already-there\t7\nrotate-\\token\t8\n001\t9\n100\t10\n'
                  case " $* " in *" --label "*) ;; *) printf 'unlabelled-dupe\t11\n' ;; esac ;;
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
assert "dry run: summary counts" "grep -qF '3 item(s): 2 would be created, 1 already have an issue.' <<<\"\$out\""

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
assert "apply: a title repeated in the queue is created once" "[ $rc -eq 0 ] && [ \"\$(grep -c -- '--title repeated' '$FAKE_LOG')\" -eq 1 ] && grep -qE '^repeated +\\(none\\) +#[0-9]+ \\(exists, skipped\\)$' <<<\"\$out\""
assert "apply: a backslash title matches its existing issue" "! grep -q -- '--title rotate-' '$FAKE_LOG' && grep -qF '#8 (exists, skipped)' <<<\"\$out\""

# A same-title issue without the operator-action label (removed after a
# partial migration, or filed by hand) is still found: no duplicate, rerun-safe.
printf '## unlabelled-dupe\n- action: exists as #11, label removed\n' > "$FX/unlabelled.md"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/unlabelled.md" --repo o/r --apply 2>&1)"; rc=$?
assert "apply: an unlabelled same-title issue is matched, not duplicated" "[ $rc -eq 0 ] && ! grep -q -- '--title unlabelled-dupe' '$FAKE_LOG' && grep -qF '#11 (exists, skipped)' <<<\"\$out\""
assert "the title check lists issues regardless of label" "grep '^issue list' '$FAKE_LOG' | grep -qv -- '--label'"

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
