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
TEST_BIN="$(mktemp -d)"
trap 'rm -f "$CALLS"; rm -rf "$TEST_HOME" "$TEST_DEV" "$TEST_BIN"' EXIT
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

export EXPECTED_FILE_LIMIT
EXPECTED_FILE_LIMIT="$(ulimit -f)"
cat > "$TEST_BIN/codex" <<'EOF'
#!/usr/bin/env bash
[ "$(ulimit -f)" = "$EXPECTED_FILE_LIMIT" ] || exit 98
trap '' TERM
setsid bash -c 'trap "" TERM; sleep 4' &
wait
EOF
chmod +x "$TEST_BIN/codex"

SECONDS=0
PATH="$TEST_BIN:$PATH" _codex_remote_run 1 remote-control start --json \
  >/dev/null 2>&1
bounded_rc=$?
bounded_elapsed=$SECONDS
if [ "$bounded_rc" -eq 124 ] && [ "$bounded_elapsed" -le 2 ]; then
  ok "Remote Control bounds capture and returns despite an escaped descendant"
else
  fail "Remote Control deadline was held by an escaped descendant (rc=$bounded_rc, elapsed=${bounded_elapsed}s)"
fi

_codex_remote_run() {
  local timeout_seconds="$1"
  shift
  printf 'bounded:%s:%s\n' "$timeout_seconds" "$*" >> "$CALLS"
  case "$*" in
    "remote-control start --json")
      local attempt
      attempt="$(grep -c '^bounded:15:remote-control start --json$' "$CALLS")"
      if [ "$attempt" -eq 1 ]; then
        [ -z "${REMOTE_START_OUTPUT:-}" ] || printf '%s\n' "$REMOTE_START_OUTPUT" >&2
        return "${REMOTE_START_RC:-0}"
      fi
      [ -z "${REMOTE_RETRY_OUTPUT:-}" ] || printf '%s\n' "$REMOTE_RETRY_OUTPUT" >&2
      return "${REMOTE_RETRY_RC:-0}"
      ;;
    "remote-control stop --json")
      return "${REMOTE_STOP_RC:-0}"
      ;;
  esac
  return 99
}

_codex_remote_recover_stale_updater() {
  printf 'pidfd-recovery\n' >> "$CALLS"
  return "${REMOTE_RECOVERY_RC:-0}"
}

_codex_remote_snapshot_updater() {
  printf 'exact-snapshot\n' >> "$CALLS"
  return "${REMOTE_SNAPSHOT_RC:-0}"
}

codex() {
  printf '%s\n' "$*" >> "$CALLS"
  [ "${1:-}" != "--strict-config" ] || return "${STRICT_CONFIG_RC:-0}"
  return 0
}

cx resume session-123 >/dev/null 2>&1
expected_calls=$'bootstrap\nbounded:15:remote-control start --json\nexact-snapshot\n--strict-config resume session-123'
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "cx starts Remote Control before launching Codex"
else
  fail "cx call order was: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
REMOTE_START_RC=42
REMOTE_START_OUTPUT='specific upstream cause: relay authentication expired token=super-secret-value https://relay.example/path?auth=something'
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

if grep -q 'codex remote-control start --json' <<< "$output" \
  && ! grep -q 'specific upstream cause' <<< "$output" \
  && ! grep -q 'super-secret-value' <<< "$output" \
  && ! grep -q 'relay.example' <<< "$output"; then
  ok "Remote Control failure offers a repro without leaking upstream stderr"
else
  fail "cx exposed upstream stderr or omitted the safe repro: $output"
fi

expected_calls=$'bootstrap\nbounded:15:remote-control start --json\n--strict-config --model test-model'
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "unrelated Remote Control failures do not retry and still launch Codex"
else
  fail "cx failure-path calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
REMOTE_START_RC=124
unset REMOTE_START_OUTPUT
if output="$(cx exec --help 2>&1)" \
  && grep -q 'timed out after 15 seconds' <<< "$output" \
  && [ "$(grep -c '^bounded:15:remote-control start --json$' "$CALLS")" -eq 1 ]; then
  ok "Remote Control start has a visible deadline and does not loop"
else
  fail "cx did not handle a bounded Remote Control timeout: $output"
fi

: > "$CALLS"
REMOTE_START_RC=1
REMOTE_START_OUTPUT="Error: app server did not become ready on $HOME/.codex/app-server-control/app-server-control.sock
Caused by: No such file or directory (os error 2)"
REMOTE_RETRY_RC=0
REMOTE_RECOVERY_RC=0

if output="$(cx --model recovered 2>&1)" \
  && grep -q 'recovered a stale managed daemon' <<< "$output"; then
  ok "cx recovers the exact stale managed updater once"
else
  fail "cx did not recover the stale managed updater: $output"
fi

expected_calls=$'bootstrap\nbounded:15:remote-control start --json\npidfd-recovery\nbounded:8:remote-control stop --json\nbounded:15:remote-control start --json\nexact-snapshot\n--strict-config --model recovered'
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "stale updater recovery is bounded and retries only once"
else
  fail "cx recovery calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
REMOTE_RECOVERY_RC=1
REMOTE_RETRY_RC=0
if output="$(cx --model foreign-pid 2>&1)" \
  && [ "$(grep -c '^pidfd-recovery$' "$CALLS")" -eq 1 ] \
  && [ "$(grep -c '^bounded:15:remote-control start --json$' "$CALLS")" -eq 1 ]; then
  ok "cx never retries when atomic updater validation refuses recovery"
else
  fail "cx retried after updater identity validation failed: $output"
fi

: > "$CALLS"
STRICT_CONFIG_RC=9
printf '{"remoteControlEnabled":false}\n' \
  > "$HOME/.codex/app-server-daemon/settings.json"
if cx exec --help >/dev/null 2>&1; then
  fail "cx ignored strict config failure on the actual Codex invocation"
elif [ "$(tail -1 "$CALLS")" = "--strict-config exec --help" ]; then
  ok "cx enforces strict config on the actual Codex invocation"
else
  fail "cx did not invoke Codex in strict mode: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
unset REMOTE_START_RC REMOTE_RETRY_RC STRICT_CONFIG_RC
printf '{"nested":{"remoteControlEnabled":true},"remoteControlEnabled":false}\n' \
  > "$HOME/.codex/app-server-daemon/settings.json"
cx exec --help >/dev/null 2>&1
expected_calls=$'bootstrap\n--strict-config exec --help'
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "cx requires top-level Remote Control opt-in"
else
  fail "cx accepted nested Remote Control opt-in: $(tr '\n' '|' < "$CALLS")"
fi

echo ""
echo "cx-remote-control: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
