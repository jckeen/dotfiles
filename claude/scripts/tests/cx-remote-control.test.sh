#!/usr/bin/env bash
# cx-remote-control.test.sh — cx attaches interactive sessions to Remote Control,
# while preserving local Codex access when the experimental daemon is
# unavailable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../../.bash_aliases
source "$REPO_ROOT/.bash_aliases"
unset CODEX_HOME

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

CALLS="$(mktemp)"
PROBES="$(mktemp)"
TEST_HOME="$(mktemp -d)"
TEST_DEV="$(mktemp -d)"
trap 'rm -f "$CALLS" "$PROBES"; rm -rf "$TEST_HOME" "$TEST_DEV"' EXIT
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

_codex_shared_server_status() {
  printf 'probe\n' >> "$PROBES"
  return "${REMOTE_PROBE_RC:-0}"
}

codex() {
  printf '%s\n' "$*" >> "$CALLS"
  [ "${1:-}" != "--strict-config" ] || return "${STRICT_CONFIG_RC:-0}"
  return 0
}

cx resume session-123 >/dev/null 2>&1
expected_calls=$'bootstrap\n--strict-config --remote unix:// resume session-123'
if [ "$(cat "$CALLS")" = "$expected_calls" ] && [ "$(wc -l < "$PROBES")" -eq 1 ]; then
  ok "cx reuses a listening shared server without native management commands"
else
  fail "cx call order was: $(tr '\n' '|' < "$CALLS")"
fi

# A listener may appear immediately after an absent probe. No probe result
# authorizes a native management command: it can erase live PID records.
for REMOTE_PROBE_RC in 1 2 3 124 125; do
  : > "$CALLS"
  : > "$PROBES"
  if output="$(cx 2>&1)" \
    && [ "$(cat "$CALLS")" = $'bootstrap\n--strict-config' ] \
    && [ "$(wc -l < "$PROBES")" -eq 1 ] \
    && grep -q 'local session' <<< "$output"; then
    ok "an absent or uncertain socket falls back without native management (exit $REMOTE_PROBE_RC)"
  else
    fail "cx tried daemon management after a failed probe: $output; $(tr '\n' '|' < "$CALLS")"
  fi
  if [ "$REMOTE_PROBE_RC" -eq 3 ]; then
    if grep -q 'codex remote-control start --json' <<< "$output"; then
      ok "an absent server explains how to enable Remote Control explicitly"
    else
      fail "cx did not explain explicit Remote Control startup: $output"
    fi
  fi
done
unset REMOTE_PROBE_RC

# The launcher must parse flags without mistaking their values or a literal
# prompt for a subcommand or an explicit remote address.
assert_launch() {
  local name="$1" expected="$2"
  shift 2
  : > "$CALLS"
  cx "$@" >/dev/null 2>&1
  if [ "$(cat "$CALLS")" = "$expected" ]; then
    ok "$name"
  else
    fail "$name: $(tr '\n' '|' < "$CALLS")"
  fi
}

shared_prefix=$'bootstrap\n--strict-config --remote unix://'
local_prefix=$'bootstrap\n--strict-config'
assert_launch "fresh sessions attach to the shared server" "$shared_prefix"
assert_launch "agents uses the shared server" "$shared_prefix agents" agents
assert_launch "explicit agents endpoint is preserved" \
  "$local_prefix agents --remote=unix:///custom.sock" agents --remote=unix:///custom.sock
assert_launch "fork keeps the remote option ahead of the command" \
  "$shared_prefix fork --last" fork --last
assert_launch "global options before resume keep their ordering" \
  "$shared_prefix --approve-for-me -m example resume --last" --approve-for-me -m example resume --last
assert_launch "a flag value is not a utility command" \
  "$shared_prefix --model exec" --model exec
assert_launch "a flag value is not an explicit remote" \
  "$shared_prefix --config --remote=literal" --config --remote=literal
assert_launch "literal prompts stop option interpretation" \
  "$shared_prefix -- --remote=literal" -- --remote=literal
assert_launch "resume prompts may name a utility command" \
  "$shared_prefix resume session-123 exec" resume session-123 exec
assert_launch "explicit remote is preserved without local daemon startup" \
  "$local_prefix --remote wss://example.invalid resume session-123" --remote wss://example.invalid resume session-123
assert_launch "explicit remote after resume is preserved" \
  "$local_prefix resume session-123 --remote=unix:///custom.sock" resume session-123 --remote=unix:///custom.sock
assert_launch "explicit remote after a prompt is preserved" \
  "$local_prefix inspect --remote unix:///custom.sock" inspect --remote unix:///custom.sock
assert_launch "remote authentication options do not attach the local daemon" \
  "$local_prefix --remote-auth-token-env EXAMPLE_REMOTE_TOKEN" --remote-auth-token-env EXAMPLE_REMOTE_TOKEN
for utility in exec e review login logout mcp plugin mcp-server app-server remote-control completion update doctor sandbox debug apply a queue archive delete migrate-rollouts unarchive cloud exec-server features help; do
  assert_launch "$utility stays a native utility invocation" \
    "$local_prefix --config example=true $utility" --config example=true "$utility"
done
for help_args in '--help' '-h' '--version' '-V' 'resume --help' 'fork -h'; do
  # Intentional splitting of these fixed, non-user test inputs.
  # shellcheck disable=SC2086
  assert_launch "$help_args does not start or attach the daemon" \
    "$local_prefix $help_args" $help_args
done

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
unset STRICT_CONFIG_RC
printf '{"nested":{"remoteControlEnabled":true},"remoteControlEnabled":false}\n' \
  > "$HOME/.codex/app-server-daemon/settings.json"
cx >/dev/null 2>&1
expected_calls=$'bootstrap\n--strict-config'
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "cx requires top-level Remote Control opt-in"
else
  fail "cx accepted nested Remote Control opt-in: $(tr '\n' '|' < "$CALLS")"
fi

assert_launch "disabled Remote Control leaves interactive sessions local" "$local_prefix"
printf 'invalid-json\n' > "$HOME/.codex/app-server-daemon/settings.json"
assert_launch "malformed opt-in never enables Remote Control" "$local_prefix"

printf '{"remoteControlEnabled":true}\n' \
  > "$HOME/.codex/app-server-daemon/settings.json"
STRICT_CONFIG_RC=9
if cx >/dev/null 2>&1; then
  fail "cx ignored the remote CLI exit status"
else
  ok "remote attachment preserves the actual CLI exit status"
fi
unset STRICT_CONFIG_RC
assert_launch "unknown CLI options are passed through without auto-attachment" \
  "$local_prefix --future-option value" --future-option value

REMOTE_PROBE_RC=125
assert_launch "missing timeout support falls back to a local session" "$local_prefix"
unset REMOTE_PROBE_RC

export CODEX_HOME="$TEST_HOME/custom codex home"
mkdir -p "$CODEX_HOME/app-server-daemon"
assert_launch "custom CODEX_HOME never inherits the default home opt-in" "$local_prefix"
printf '{"remoteControlEnabled":true}\n' > "$CODEX_HOME/app-server-daemon/settings.json"
assert_launch "custom CODEX_HOME uses its own remote opt-in" "$shared_prefix"

echo ""
echo "cx-remote-control: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
