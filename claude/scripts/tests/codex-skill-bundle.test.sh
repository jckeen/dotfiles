#!/usr/bin/env bash
# Self-test recursive Codex skill deployment auditing with a throwaway HOME.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
R="$(mktemp -d)"
H="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$R" "$H" "$OUT"' EXIT

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

mkdir -p "$R/codex" "$R/agents/skills/demo/references" "$H/.codex/skills/demo/references"
cp "$REPO_ROOT/check-codex.sh" "$REPO_ROOT/lib-checks.sh" "$R/"
printf '# Agent rules\n' > "$R/codex/AGENTS.md"
printf '%s\n' '---' 'name: demo' 'description: Demo skill.' '---' > "$R/agents/skills/demo/SKILL.md"
printf '# Nested reference\n' > "$R/agents/skills/demo/references/runtime.md"
ln -s "$R/codex/AGENTS.md" "$H/.codex/AGENTS.md"
ln -s "$R/agents/skills/demo/SKILL.md" "$H/.codex/skills/demo/SKILL.md"

if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1 \
  && grep -q 'MISSING.*skills/demo/references/runtime.md' "$OUT" \
  && ! grep -q 'All good' "$OUT"; then
  ok "missing nested skill link warns with its relative path"
else
  fail "missing nested skill link was not surfaced clearly"
fi

ln -s "$R/agents/skills/demo/references/runtime.md" "$H/.codex/skills/demo/references/runtime.md"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  ok "complete nested skill bundle passes"
else
  fail "complete nested skill bundle failed"
fi

mkdir -p "$H/.codex/skills/demo/references/stale"
ln -s "$R/agents/skills/demo/references/missing.md" "$H/.codex/skills/demo/references/stale/deep.md"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "deep orphaned managed link was accepted"
elif grep -q 'ORPHAN.*stale/deep.md' "$OUT"; then
  ok "deep orphaned managed link fails"
else
  fail "deep orphan failure was not reported"
fi

echo ""
echo "codex-skill-bundle: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
