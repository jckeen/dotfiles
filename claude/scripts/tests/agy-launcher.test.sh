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
unset AGY_MEMORY_REPO

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
binary|--mode auto --remote-control --continue"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy runs the Antigravity health preflight before the CLI and defaults to --mode auto --remote-control"
else
  fail "agy preflight call order was: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
TEST_SHIFTED=1
agy demo-project --model gemini-test >/dev/null 2>&1
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|demo-project --model gemini-test
binary|--mode auto --remote-control --model gemini-test"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy keeps cc/cx project-selection ergonomics without leaking the project name"
else
  fail "agy project-selection calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
TEST_SHIFTED=0
agy --mode plan --continue >/dev/null 2>&1
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|--mode plan --continue
binary|--remote-control --mode plan --continue"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy honors an explicit --mode flag without duplicating --mode auto"
else
  fail "agy explicit --mode calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
TEST_SHIFTED=0
agy --remote-control=false --continue >/dev/null 2>&1
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|--remote-control=false --continue
binary|--mode auto --remote-control=false --continue"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy honors an explicit --remote-control flag without duplicating --remote-control"
else
  fail "agy explicit --remote-control calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
TEST_SHIFTED=0
agy -c 67f5203b-2f89-4ff0-9c9c-b3f924ba1ef8 >/dev/null 2>&1
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|-c 67f5203b-2f89-4ff0-9c9c-b3f924ba1ef8
binary|--mode auto --remote-control --conversation 67f5203b-2f89-4ff0-9c9c-b3f924ba1ef8"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy rewrites -c <id> to --conversation <id> so CLI does not reject <id> as an unexpected positional arg"
else
  fail "agy -c <id> calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
TEST_SHIFTED=0
agy -c=67f5203b-2f89-4ff0-9c9c-b3f924ba1ef8 >/dev/null 2>&1
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|-c=67f5203b-2f89-4ff0-9c9c-b3f924ba1ef8
binary|--mode auto --remote-control --conversation=67f5203b-2f89-4ff0-9c9c-b3f924ba1ef8"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy rewrites -c=<id> to --conversation=<id>"
else
  fail "agy -c=<id> calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
TEST_SHIFTED=0
agy -c --model gemini-test >/dev/null 2>&1
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|-c --model gemini-test
binary|--mode auto --remote-control -c --model gemini-test"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy preserves bare -c when followed by another flag"
else
  fail "agy -c --model calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
TEST_SHIFTED=0
agy --continue=true -c=false >/dev/null 2>&1
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|--continue=true -c=false
binary|--mode auto --remote-control --continue=true -c=false"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy preserves explicit boolean continue values (--continue=true, -c=false)"
else
  fail "agy boolean continue calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
TEST_SHIFTED=0
agy --print '-c=example' -i --mode >/dev/null 2>&1
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|--print -c=example -i --mode
binary|--mode auto --remote-control --print -c=example -i --mode"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy preserves option values during resume normalization and mode detection"
else
  fail "agy option-value calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
mkdir -p "$TEST_DEV/agy-memory"
cat > "$TEST_DEV/agy-memory/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
printf 'bootstrap\n' >> "$CALLS"
EOF
chmod +x "$TEST_DEV/agy-memory/bootstrap.sh"
agy --continue >/dev/null 2>&1
rm -rf "$TEST_DEV/agy-memory"
expected_calls="preflight|--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=|_check_antigravity_launch_health|--continue
bootstrap
binary|--mode auto --remote-control --continue"
if [ "$(cat "$CALLS")" = "$expected_calls" ]; then
  ok "agy runs agy-memory/bootstrap.sh after preflight when present"
else
  fail "agy bootstrap calls were: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
TEST_SHIFTED=0
agy models >/dev/null 2>&1
if [ "$(cat "$CALLS")" = "binary|models" ]; then
  ok "agy utility subcommands bypass the launch preflight"
else
  fail "agy models ran the launch preflight: $(tr '\n' '|' < "$CALLS")"
fi

: > "$CALLS"
agy --help >/dev/null 2>&1
if [ "$(cat "$CALLS")" = "binary|--help" ]; then
  ok "agy help/version flags bypass the launch preflight"
else
  fail "agy --help ran the launch preflight: $(tr '\n' '|' < "$CALLS")"
fi

_agent_preflight() {
  printf 'unexpected preflight\n' >> "$CALLS"
  return 1
}
for utility in mcp remote-control mic-serve; do
  : > "$CALLS"
  if agy "$utility" --help >/dev/null 2>&1 &&
      [ "$(cat "$CALLS")" = "binary|$utility --help" ]; then
    ok "agy $utility bypasses a failing workspace preflight"
  else
    fail "agy $utility entered workspace preflight: $(tr '\n' '|' < "$CALLS")"
  fi
done

echo ""
echo "agy-launcher: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
