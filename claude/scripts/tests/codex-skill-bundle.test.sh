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
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1 && grep -q 'All good' "$OUT"; then
  ok "complete nested skill bundle passes"
else
  fail "complete nested skill bundle failed"
fi

mkdir -p "$H/vendor-skill"
ln -s "$H/vendor-skill" "$H/.codex/skills/vendor"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  ok "unmanaged directory-symlink skill remains valid"
else
  fail "unmanaged directory-symlink skill failed the audit"
fi

mkdir -p "$H/.codex/sessions/x"
ln -s "$R/removed-runtime-file" "$H/.codex/sessions/x/unmanaged.md"
if HOME="$H" "$R/check-codex.sh" --fix > "$OUT" 2>&1 \
  && [ -L "$H/.codex/sessions/x/unmanaged.md" ]; then
  ok "orphan cleanup ignores links outside managed paths"
else
  fail "orphan cleanup modified unmanaged runtime state"
fi

mkdir -p "$H/.codex/skills/local"
ln -s "$R/agents/skills/demo/removed.md" "$H/.codex/skills/local/custom.md"
if HOME="$H" "$R/check-codex.sh" --fix > "$OUT" 2>&1 \
  && [ -L "$H/.codex/skills/local/custom.md" ]; then
  ok "orphan cleanup requires an exact managed destination"
else
  fail "orphan cleanup removed a target-prefix collision"
fi

mkdir -p "$H/.codex/skills/demo/references/stale"
ln -s "$R/agents/skills/demo/references/stale/deep.md" "$H/.codex/skills/demo/references/stale/deep.md"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "deep orphaned managed link was accepted"
elif grep -q 'ORPHAN.*stale/deep.md' "$OUT"; then
  ok "deep orphaned managed link fails"
else
  fail "deep orphan failure was not reported"
fi

rm "$H/.codex/skills/demo/references/stale/deep.md"
mv "$H/.codex/skills" "$H/external-skills"
ln -s "$H/external-skills" "$H/.codex/skills"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "symlinked managed skill directory was accepted"
elif grep -q 'UNSAFE.*skills is a managed directory symlink' "$OUT"; then
  ok "symlinked managed skill directory fails closed"
else
  fail "symlinked managed skill directory failed without a useful report"
fi

mv "$H/.codex" "$H/external-codex"
ln -s "$H/external-codex" "$H/.codex"
if HOME="$H" "$R/check-codex.sh" --fix > "$OUT" 2>&1; then
  fail "symlinked Codex runtime root was accepted"
elif grep -q 'UNSAFE.*~/.codex is a directory symlink' "$OUT" \
  && [ -L "$H/external-codex/skills/local/custom.md" ]; then
  ok "symlinked Codex runtime root fails without cleanup traversal"
else
  fail "symlinked Codex runtime root did not fail closed"
fi

echo ""
echo "codex-skill-bundle: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
