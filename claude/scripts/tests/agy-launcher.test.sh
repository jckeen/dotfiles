#!/usr/bin/env bash
# agy-launcher.test.sh — the Antigravity launcher shares the repo-sync,
# project-selection, and health-check preflight used by cc/cx.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

CALLS="$(mktemp)"
TEST_HOME="$(mktemp -d)"
TEST_DEV="$(mktemp -d)"
SHIM_DIR="$(mktemp -d)"
trap 'rm -f "$CALLS"; rm -rf "$TEST_HOME" "$TEST_DEV" "$SHIM_DIR"' EXIT

cat > "$SHIM_DIR/agy" <<'EOF'
#!/usr/bin/env bash
printf 'binary|%s\n' "$*" >> "$CALLS"
EOF
chmod +x "$SHIM_DIR/agy"

export CALLS
export HOME="$TEST_HOME"
export PATH="$SHIM_DIR:/usr/bin:/bin"

# shellcheck source=../../../.bash_aliases
source "$REPO_ROOT/.bash_aliases"

_dev_dir() {
  printf '%s\n' "$TEST_DEV"
}

_agent_preflight() {
  printf 'preflight|%s|%s|%s\n' "$1" "$2" "${*:3}" >> "$CALLS"
  _agent_resuming=0
  _agent_shifted="${TEST_SHIFTED:-0}"
}

agy --continue >/dev/null 2>&1
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|--continue
binary|--continue"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy runs the Antigravity health preflight before the CLI"
else
  fail "agy preflight call order was: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
TEST_SHIFTED=1
agy demo-project --model gemini-test >/dev/null 2>&1
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|demo-project --model gemini-test
binary|--model gemini-test"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy keeps cc/cx project-selection ergonomics without leaking the project name"
else
  fail "agy project-selection calls were: $(tr '\n' '|' < "$CALLS")"
fi

echo ""
echo "agy-launcher: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
