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

rm "$T/fake-home/.claude/settings.json"
if run && grep -q 'skipping' "$T/out"; then ok "missing settings.json skips with exit 0"
else fail "missing settings.json skips with exit 0"; cat "$T/out"; fi

echo "check-skill-refs: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
