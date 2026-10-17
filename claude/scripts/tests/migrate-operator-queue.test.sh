#!/usr/bin/env bash
# migrate-operator-queue.test.sh — fixture tests for migrate-operator-queue.sh.
# A fake `gh` first on PATH records every call and answers from fixture files,
# so nothing reaches GitHub. Asserts: a non-private repo is refused in both
# modes; the dry run lists one row per block and makes no write call; --apply
# creates the missing labels and one issue per new block, with the block's
# field lines verbatim in the body and the project label from the first word
# of `project:`; a block whose title already has an issue is skipped. Run
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
  "repo view")    echo "$FAKE_VIS" ;;
  "issue list")   printf 'already-there\t7\n' ;;
  "label list")   printf 'operator-action\n' ;;
  "label create") : ;;
  "issue create")
    while [ $# -gt 0 ]; do
      if [ "$1" = "--title" ]; then t="$2"; fi
      if [ "$1" = "--body-file" ]; then cp "$2" "$FAKE_BODIES/$t"; fi
      shift
    done ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
GH
chmod +x "$FX/bin/gh"
export PATH="$FX/bin:$PATH" FAKE_LOG="$FX/gh.log" FAKE_BODIES="$FX/bodies"

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
assert "public repo refused (dry run)" "[ $rc -eq 1 ] && grep -qF 'refusing: o/r is PUBLIC' <<<\"\$out\" && [ \"\$(writes)\" -eq 0 ]"
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
assert "apply: missing project labels created, existing operator-action not" "grep -qx 'label create project:dotfiles -R o/r --color C5DEF5' '$FAKE_LOG' && grep -qx 'label create project:stringer -R o/r --color C5DEF5' '$FAKE_LOG' && ! grep -q 'label create operator-action' '$FAKE_LOG'"
assert "apply: two issues created, none for the existing title" "[ \"\$(grep -c '^issue create' '$FAKE_LOG')\" -eq 2 ] && ! grep -q -- '--title already-there' '$FAKE_LOG'"
assert "apply: scoped issue carries both labels" "grep -q -- '--title dot-thing --label operator-action --body-file .* --label project:dotfiles' '$FAKE_LOG'"
assert "apply: unscoped issue carries only operator-action" "grep -- '--title no-project-item' '$FAKE_LOG' | grep -qv 'project:'"
assert "apply: body keeps the field lines verbatim" "grep -qxF -- '- verified: 2026-10-01 (re-checked)' '$FX/bodies/dot-thing' && grep -qxF -- '- added: 2026-07-01' '$FX/bodies/dot-thing' && ! grep -q '^## ' '$FX/bodies/dot-thing'"
assert "apply: body notes the migration" "grep -q '^Migrated from ~/.claude/operator-queue.md on ' '$FX/bodies/dot-thing'"

# A queue with no project anywhere: --apply must not abort on the empty label list.
printf '## lone\n- added: 2026-09-01\n- action: unscoped only\n' > "$FX/unscoped.md"
: > "$FAKE_LOG"
out="$(FAKE_VIS=PRIVATE bash "$SCRIPT" --queue "$FX/unscoped.md" --repo o/r --apply 2>&1)"; rc=$?
assert "apply: all-unscoped queue creates its issue" "[ $rc -eq 0 ] && grep -q -- '--title lone --label operator-action' '$FAKE_LOG'"

echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
