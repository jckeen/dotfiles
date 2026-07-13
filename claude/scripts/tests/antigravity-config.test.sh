#!/usr/bin/env bash
# antigravity-config.test.sh — Antigravity health checks fail closed on unsafe
# runtime roots and malformed local MCP configuration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

R="$(mktemp -d)"
H="$(mktemp -d)"
EXTERNAL="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$R" "$H" "$EXTERNAL"; rm -f "$OUT"' EXIT

mkdir -p "$R/antigravity"
cp "$REPO_ROOT/check-antigravity.sh" "$REPO_ROOT/lib-checks.sh" "$R/"
cp "$REPO_ROOT/antigravity/GEMINI.md" "$REPO_ROOT/antigravity/hooks.json" \
  "$R/antigravity/"

if grep -q '@latest' "$REPO_ROOT/antigravity/mcp_config.json.example" \
  || ! grep -Eq '@playwright/mcp@[0-9]' "$REPO_ROOT/antigravity/mcp_config.json.example" \
  || ! grep -Eq '@modelcontextprotocol/server-github@[0-9]' "$REPO_ROOT/antigravity/mcp_config.json.example"; then
  fail "Antigravity MCP template dependencies are not reproducibly pinned"
else
  ok "Antigravity MCP template dependencies are pinned"
fi

MISSING_HOME="$(mktemp -d)"
if HOME="$MISSING_HOME" "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker accepted missing Antigravity runtime configuration"
elif grep -q 'MISSING.*Antigravity has not been initialized' "$OUT"; then
  ok "checker fails health checks when Antigravity is uninitialized"
else
  fail "missing Antigravity state lacked a useful diagnostic"
fi
rm -rf "$MISSING_HOME"

mkdir -p "$H/.gemini"
ln -s "$EXTERNAL" "$H/.gemini/config"
printf 'preserve me\n' > "$EXTERNAL/sentinel"

if HOME="$H" "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker accepted a symlinked Antigravity config root"
elif grep -q 'UNSAFE.*config.*directory symlink' "$OUT" \
  && grep -q 'preserve me' "$EXTERNAL/sentinel"; then
  ok "checker refuses a symlinked Antigravity config root without traversal"
else
  fail "symlinked-root failure lacked a safe diagnostic"
fi

rm "$H/.gemini/config"
rmdir "$H/.gemini"
mkdir -p "$EXTERNAL/config"
ln -s "$R/antigravity/GEMINI.md" "$EXTERNAL/config/GEMINI.md"
ln -s "$R/antigravity/hooks.json" "$EXTERNAL/config/hooks.json"
printf '{"mcpServers":{}}\n' > "$EXTERNAL/config/mcp_config.json"
ln -s "$EXTERNAL" "$H/.gemini"
if HOME="$H" "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker accepted a symlinked Antigravity runtime parent"
elif grep -q 'UNSAFE.*\.gemini.*directory symlink' "$OUT"; then
  ok "checker refuses a symlinked Antigravity runtime parent"
else
  fail "symlinked-parent failure lacked a safe diagnostic"
fi

rm "$H/.gemini"
mkdir -p "$H/.gemini"
mkdir -p "$H/.gemini/config"
ln -s "$R/antigravity/GEMINI.md" "$H/.gemini/config/GEMINI.md"
ln -s "$R/antigravity/hooks.json" "$H/.gemini/config/hooks.json"
printf 'not json\n' > "$H/.gemini/config/mcp_config.json"

if HOME="$H" "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker accepted malformed MCP configuration"
elif grep -q 'INVALID.*mcp_config.json' "$OUT"; then
  ok "checker rejects malformed MCP configuration"
else
  fail "malformed MCP failure lacked a useful diagnostic"
fi

printf '{"mcpServers":{}}\n' > "$H/.gemini/config/mcp_config.json"
if HOME="$H" "$R/check-antigravity.sh" > "$OUT" 2>&1 \
  && grep -q 'All good' "$OUT"; then
  ok "checker accepts a valid local MCP object"
else
  fail "checker rejected a valid local MCP object"
fi

rm "$H/.gemini/config/hooks.json"
if HOME="$H" "$R/check-antigravity.sh" --strict > "$OUT" 2>&1; then
  fail "strict checker accepted missing managed Antigravity config"
else
  ok "strict checker turns actionable Antigravity drift into launcher failure"
fi
ln -s "$R/antigravity/hooks.json" "$H/.gemini/config/hooks.json"

SKILLS_EXTERNAL="$R/external-skills"
mkdir -p "$SKILLS_EXTERNAL"
ln -s "$SKILLS_EXTERNAL" "$H/.gemini/config/skills"
if HOME="$H" "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker accepted a symlinked Antigravity skills ancestor"
elif grep -q 'UNSAFE.*skills.*directory symlink' "$OUT"; then
  ok "checker refuses a symlinked Antigravity skills ancestor"
else
  fail "symlinked-skills failure lacked a safe diagnostic"
fi
rm "$H/.gemini/config/skills"

CUSTOM_MEMORY="$R/custom-agy-memory"
mkdir -p "$CUSTOM_MEMORY"
printf '# private rules\n' > "$CUSTOM_MEMORY/GEMINI.local.md"
printf '# private memory\n' > "$CUSTOM_MEMORY/MEMORY.md"
HOME="$H" AGY_MEMORY_REPO="$CUSTOM_MEMORY" \
  "$R/check-antigravity.sh" > "$OUT" 2>&1 || true
if grep -q 'MISSING.*GEMINI.local.md' "$OUT"; then
  ok "checker honors the Antigravity memory repository override"
else
  fail "checker ignored a custom Antigravity memory repository"
fi

echo ""
echo "antigravity-config: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
