#!/usr/bin/env bash
# codex-config.test.sh — checked-in Codex examples use current config surfaces.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

if ! grep -q '\[profiles\.' "$REPO_ROOT/codex/config.toml.example"; then
  ok "global config example does not document removed inline profiles"
else
  fail "global config example still documents an inline profile"
fi

readonly_example="$REPO_ROOT/codex/readonly.config.toml.example"
if [ -f "$readonly_example" ] \
  && grep -q '^sandbox_mode = "read-only"$' "$readonly_example" \
  && grep -q '^approval_policy = "on-request"$' "$readonly_example"; then
  ok "read-only profile example uses supported Codex keys"
else
  fail "read-only profile example is missing or uses stale keys"
fi

tilde='~'
if grep -q "$tilde/.codex/readonly.config.toml" "$REPO_ROOT/codex/README.md" \
  && grep -q -- '--profile readonly' "$REPO_ROOT/codex/README.md"; then
  ok "Codex README documents the separate profile file"
else
  fail "Codex README does not explain how to install and use the profile"
fi

echo ""
echo "codex-config: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
