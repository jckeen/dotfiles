#!/usr/bin/env bash
# Self-test recursive Codex skill deployment auditing with a throwaway HOME.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
R="$(mktemp -d)" || { echo "FAIL - unable to allocate source fixture"; exit 1; }
H="$(mktemp -d)" || { echo "FAIL - unable to allocate HOME fixture"; exit 1; }
OUT="$(mktemp)" || { echo "FAIL - unable to allocate output fixture"; exit 1; }
trap 'rm -rf "$R" "$H" "$OUT"' EXIT

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

mkdir -p "$R/codex" "$R/agents/skills/demo/references" \
  "$H/.codex/skills/demo/references" "$H/.agents/skills"
cp "$REPO_ROOT/check-codex.sh" "$REPO_ROOT/lib-checks.sh" "$R/"
printf '# Agent rules\n' > "$R/codex/AGENTS.md"
printf '%s\n' '---' 'name: demo' 'description: Demo skill.' '---' > "$R/agents/skills/demo/SKILL.md"
printf '# Nested reference\n' > "$R/agents/skills/demo/references/runtime.md"
ln -s "$R/codex/AGENTS.md" "$H/.codex/AGENTS.md"
ln -s "$R/agents/skills/demo/SKILL.md" "$H/.codex/skills/demo/SKILL.md"
ln -s "$R/agents/skills/demo" "$H/.agents/skills/demo"

MISSING_HOME="$(mktemp -d)"
if HOME="$MISSING_HOME" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "checker accepted missing Codex runtime configuration"
elif grep -q 'MISSING.*Codex has not been initialized' "$OUT"; then
  ok "checker fails health checks when Codex is uninitialized"
else
  fail "missing Codex state lacked a useful diagnostic"
fi
rm -rf "$MISSING_HOME"

if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1 \
  && grep -q 'MISSING.*skills/demo/references/runtime.md' "$OUT" \
  && ! grep -q 'All good' "$OUT"; then
  ok "missing nested skill link warns with its relative path"
else
  fail "missing nested skill link was not surfaced clearly"
fi

if HOME="$H" "$R/check-codex.sh" --strict > "$OUT" 2>&1; then
  fail "strict checker accepted missing managed Codex config"
else
  ok "strict checker turns actionable Codex drift into launcher failure"
fi

ln -s "$R/agents/skills/demo/references/runtime.md" "$H/.codex/skills/demo/references/runtime.md"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1 && grep -q 'All good' "$OUT"; then
  ok "complete nested skill bundle passes"
else
  fail "complete nested skill bundle failed"
fi

mkdir -p "$H/custom-codex-memory"
printf '# private instructions\n' > "$H/custom-codex-memory/AGENTS.local.md"
printf '# private memory\n' > "$H/custom-codex-memory/MEMORY.md"
if HOME="$H" CODEX_MEMORY_REPO="$H/custom-codex-memory" \
  "$R/check-codex.sh" > "$OUT" 2>&1 \
  && grep -q 'MISSING.*AGENTS.local.md' "$OUT" \
  && grep -q 'MISSING.*MEMORY.md' "$OUT"; then
  ok "custom Codex memory repository override is audited"
else
  fail "CODEX_MEMORY_REPO override was ignored by the health check"
fi

chmod 000 "$R/agents/skills/demo/references"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "failed source traversal was accepted"
elif grep -q 'FAILED.*traverse complete skill bundle' "$OUT"; then
  ok "failed source traversal fails the audit"
else
  fail "failed source traversal lacked a useful report"
fi
chmod 755 "$R/agents/skills/demo/references"

mkdir -p "$R/external-skill"
ln -s "$R/external-skill" "$R/agents/skills/escaped"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "symlinked source skill root was accepted"
elif grep -q 'UNSAFE.*source skill root is a directory symlink' "$OUT"; then
  ok "symlinked source skill root fails closed"
else
  fail "symlinked source skill root lacked a useful report"
fi
rm "$R/agents/skills/escaped"

mv "$R/agents/skills" "$R/agents/real-skills"
ln -s "$R/agents/real-skills" "$R/agents/skills"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "symlinked aggregate source skill root was accepted"
elif grep -q 'UNSAFE.*shared source skill root is a directory symlink' "$OUT"; then
  ok "symlinked aggregate source skill root fails closed"
else
  fail "symlinked aggregate source skill root lacked a useful report"
fi
rm "$R/agents/skills"
mv "$R/agents/real-skills" "$R/agents/skills"

printf 'external instructions\n' > "$R/external-file.md"
ln -s "$R/external-file.md" "$R/agents/skills/demo/escaped-file.md"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "escaping source file symlink was accepted"
elif grep -q 'UNSAFE.*source skill symlink escapes its bundle' "$OUT"; then
  ok "escaping source file symlink fails closed"
else
  fail "escaping source file symlink lacked a useful report"
fi
rm "$R/agents/skills/demo/escaped-file.md"

mkdir -p "$R/shared-directory"
ln -s "$R/shared-directory" "$R/agents/skills/demo/directory-link"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "source directory symlink was accepted"
elif grep -q 'UNSAFE.*source skill symlink escapes its bundle' "$OUT"; then
  ok "source directory symlink fails closed"
else
  fail "source directory symlink lacked a useful report"
fi
rm "$R/agents/skills/demo/directory-link"

chmod 000 "$H/.codex/skills/demo/references"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "failed destination traversal was accepted"
elif grep -q 'FAILED.*traverse managed skill destinations' "$OUT"; then
  ok "failed destination traversal fails the audit"
else
  fail "failed destination traversal lacked a useful report"
fi
chmod 755 "$H/.codex/skills/demo/references"

mkdir -p "$H/vendor-skill"
ln -s "$H/vendor-skill" "$H/.codex/skills/vendor"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  ok "unmanaged directory-symlink skill remains valid"
else
  fail "unmanaged directory-symlink skill failed the audit"
fi

mkdir -p "$H/managed-external"
ln -s "$R/agents/skills/demo/references/deep.md" "$H/managed-external/deep.md"
ln -s "$H/managed-external" "$H/.codex/skills/demo/references/managed-link"
if HOME="$H" "$R/check-codex.sh" > "$OUT" 2>&1; then
  fail "directory symlink inside a managed skill was accepted"
elif grep -q 'UNSAFE.*managed-link is a directory symlink inside a managed skill' "$OUT"; then
  ok "directory symlink inside a managed skill fails closed"
else
  fail "managed directory symlink lacked a useful report"
fi
rm "$H/.codex/skills/demo/references/managed-link"

mkdir -p "$H/.codex/sessions/x"
ln -s "$R/removed-runtime-file" "$H/.codex/sessions/x/unmanaged.md"
if HOME="$H" "$R/check-codex.sh" --fix > "$OUT" 2>&1 \
  && [ -L "$H/.codex/sessions/x/unmanaged.md" ]; then
  ok "orphan cleanup ignores links outside managed paths"
else
  fail "orphan cleanup modified unmanaged runtime state"
fi

rm "$H/.codex/AGENTS.md"
ln -s "$R/removed-custom-agents.md" "$H/.codex/AGENTS.md"
if HOME="$H" "$R/check-codex.sh" --fix > "$OUT" 2>&1; then
  fail "wrong top-level link was accepted"
elif [ -L "$H/.codex/AGENTS.md" ] && grep -q 'WRONG.*AGENTS.md' "$OUT"; then
  ok "wrong top-level link remains report-only under fix"
else
  fail "wrong top-level link was removed or not reported"
fi
rm "$H/.codex/AGENTS.md"
ln -s "$R/codex/AGENTS.md" "$H/.codex/AGENTS.md"

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

chmod 500 "$H/.codex/skills/demo/references/stale"
if HOME="$H" "$R/check-codex.sh" --fix > "$OUT" 2>&1; then
  fail "failed orphan removal was reported as success"
elif grep -q 'FAILED.*stale/deep.md could not be removed' "$OUT" \
  && [ -L "$H/.codex/skills/demo/references/stale/deep.md" ]; then
  ok "failed orphan removal remains visible"
else
  fail "failed orphan removal lacked a useful report"
fi
chmod 700 "$H/.codex/skills/demo/references/stale"

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

rm "$H/.codex"
mv "$H/external-codex" "$H/.codex"
mv "$H/.agents/skills" "$H/external-agent-skills"
ln -s "$H/external-agent-skills" "$H/.agents/skills"
if HOME="$H" "$R/check-codex.sh" --fix > "$OUT" 2>&1; then
  fail "symlinked canonical user-skill root was accepted"
elif grep -q 'UNSAFE.*user-skill root is a directory symlink' "$OUT" \
  && [ -L "$H/external-agent-skills/demo" ]; then
  ok "symlinked canonical user-skill root fails without cleanup traversal"
else
  fail "symlinked canonical user-skill root did not fail closed"
fi

echo ""
echo "codex-skill-bundle: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
