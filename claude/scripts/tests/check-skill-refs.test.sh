#!/usr/bin/env bash
# check-skill-refs.test.sh — check-skill-refs.sh against a fixture repo and a
# temp HOME: an unhedged ref to an "off" skill fails --strict, the same ref
# hedged with "if available" or "where enabled" passes, paths/URLs/fractions
# never count as refs, and a missing settings.json is a skip (exit 0).
# Run directly; exit 1 on any failure.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
failed=0
ok()   { pass=$((pass + 1));   echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

command -v jq >/dev/null 2>&1 || { echo "check-skill-refs: jq is required" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R/claude/scripts" "$R/claude/skills/orchestrate" "$R/claude/skills/changelog" "$T/fake-home/.claude"
cp "$REPO_ROOT/claude/scripts/check-skill-refs.sh" "$REPO_ROOT/claude/scripts/checker-lib.sh" "$R/claude/scripts/"
printf '{"skillOverrides": {"changelog": "off"}}\n' >"$T/fake-home/.claude/settings.json"
ORCH="$R/claude/skills/orchestrate/SKILL.md"
run() { HOME="$T/fake-home" "$R/claude/scripts/check-skill-refs.sh" --strict >"$T/out" 2>&1; }

printf '# x\n\n1. Log it with `/changelog`.\n' >"$ORCH"
if ! run && grep -q 'changelog — off' "$T/out"; then ok "unhedged ref to an off skill fails --strict"
else fail "unhedged ref to an off skill fails --strict"; cat "$T/out"; fi

printf '# x\n\n1. Log it (`/changelog` if\n   available).\n' >"$ORCH"
if run; then ok "ref hedged with 'if available' passes"
else fail "ref hedged with 'if available' passes"; cat "$T/out"; fi

printf '# x\n\n7. **Changelog** — `/changelog` where enabled\n' >"$ORCH"
if run; then ok "ref hedged with 'where enabled' passes"
else fail "ref hedged with 'where enabled' passes"; cat "$T/out"; fi

printf '# x\n\nSee `/home/you/x`, https://code.claude.com/docs/en/hooks, changelog.d/, 3/5 and ~/.claude/skills.\n' >"$ORCH"
if run; then ok "paths, URLs and fractions are not refs"
else fail "paths, URLs and fractions are not refs"; cat "$T/out"; fi

printf '# x\n\nRun `/nosuch` and `/orchestrate`.\n' >"$ORCH"
if ! run && grep -q 'nosuch — no such skill' "$T/out" && ! grep -q 'orchestrate —' "$T/out"; then
  ok "missing skill flagged, existing skill not"
else fail "missing skill flagged, existing skill not"; cat "$T/out"; fi

printf '# x\n\n1. Run `/changelog`.\n2. Run `/simplify` if available.\n' >"$ORCH"
if ! run && grep -q 'changelog — off' "$T/out"; then ok "a hedge in the next sentence does not cover an unhedged off ref"
else fail "a hedge in the next sentence does not cover an unhedged off ref"; cat "$T/out"; fi

printf '# x\n\nLog it with `/changelog`. Then simplify (`/simplify` if available).\n' >"$ORCH"
if ! run && grep -q 'changelog — off' "$T/out"; then ok "two sentences on one line are judged separately"
else fail "two sentences on one line are judged separately"; cat "$T/out"; fi

printf '# x\n\n- Record the work with `/changelog`\n  where it is enabled, then stop.\n' >"$ORCH"
if run; then ok "a hedge wrapped onto the next line of the same sentence still exempts"
else fail "a hedge wrapped onto the next line of the same sentence still exempts"; cat "$T/out"; fi

printf '# x\n\n3. Review with `/changelog` (the `review` skill if available).\n' >"$ORCH"
if ! run && grep -q 'changelog — off' "$T/out"; then ok "a hedged parenthetical does not exempt the mandatory ref before it"
else fail "a hedged parenthetical does not exempt the mandatory ref before it"; cat "$T/out"; fi

printf '# x\n\nRun `/orchestrate`,`/nosuch`.\n' >"$ORCH"
if ! run && grep -q 'nosuch — no such skill' "$T/out"; then ok "a ref right after a comma is still seen"
else fail "a ref right after a comma is still seen"; cat "$T/out"; fi

printf '# x\n\nUse `/changelog` after Codex'"'"'s review.\n' >"$ORCH"
if ! run && grep -q 'changelog — off' "$T/out"; then ok "another runtime named elsewhere in the clause does not exempt the ref"
else fail "another runtime named elsewhere in the clause does not exempt the ref"; cat "$T/out"; fi

printf '# x\n\nThen run Codex'"'"'s `/changelog` skill on the result.\n' >"$ORCH"
if run; then ok "a ref the other runtime's possessive names directly is exempt"
else fail "a ref the other runtime's possessive names directly is exempt"; cat "$T/out"; fi

rm "$T/fake-home/.claude/settings.json"
if run && grep -q 'skipping' "$T/out"; then ok "missing settings.json skips with exit 0"
else fail "missing settings.json skips with exit 0"; cat "$T/out"; fi

echo "check-skill-refs: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
