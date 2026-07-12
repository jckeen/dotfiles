#!/usr/bin/env bash
# cx-remote-control.test.sh — cx starts Codex Remote Control before the CLI,
# while preserving local Codex access when the experimental daemon is
# unavailable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../../.bash_aliases
source "$REPO_ROOT/.bash_aliases"

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

CALLS="$(mktemp)"
TEST_HOME="$(mktemp -d)"
TEST_DEV="$(mktemp -d)"
trap 'rm -f "$CALLS"; rm -rf "$TEST_HOME" "$TEST_DEV"' EXIT
export HOME="$TEST_HOME"
export CODEX_MEMORY_REPO="$TEST_DEV/private-codex-memory"
mkdir -p "$HOME/.codex/app-server-daemon"
mkdir -p "$CODEX_MEMORY_REPO"
printf '{"remoteControlEnabled":true}\n' \
  > "$HOME/.codex/app-server-daemon/settings.json"
cat > "$CODEX_MEMORY_REPO/bootstrap.sh" <<EOF
#!/usr/bin/env bash
printf 'bootstrap\n' >> "$CALLS"
EOF

_dev_dir() {
  printf '%s\n' "$TEST_DEV"
}

_agent_preflight() {
  _agent_resuming=0
  _agent_shifted=0
}

codex() {
  printf '%s\n' "$*" >> "$CALLS"
  if [ "$*" = "remote-control start --json" ]; then
    return "${REMOTE_START_RC:-0}"
  fi
  return 0
}

cx resume session-123 >/dev/null 2>&1
expected_calls=$'bootstrap\nremote-control start --json\nresume session-123'
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "cx starts Remote Control before launching Codex"
else
  fail "cx call order was: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
REMOTE_START_RC=1
if output="$(cx --model test-model 2>&1)"; then
  ok "Remote Control failure does not block Codex"
else
  fail "cx returned non-zero when only Remote Control failed"
fi

if grep -q 'Remote Control unavailable' <<< "$output"; then
  ok "Remote Control failure is visible"
else
  fail "cx did not warn when Remote Control failed"
fi

expected_calls=$'bootstrap\nremote-control start --json\n--model test-model'
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "cx still launches Codex after a Remote Control failure"
else
  fail "cx failure-path calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
printf '{"remoteControlEnabled":false}\n' \
  > "$HOME/.codex/app-server-daemon/settings.json"
unset REMOTE_START_RC
cx exec --help >/dev/null 2>&1
expected_calls=$'bootstrap\nexec --help'
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "cx does not enable Remote Control on an unconfigured host"
else
  fail "cx opted an unconfigured host into Remote Control: $(tr '\n' '|' < "$CALLS")"
fi

echo ""
echo "cx-remote-control: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
