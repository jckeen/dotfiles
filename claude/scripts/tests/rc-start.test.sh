#!/usr/bin/env bash
# rc-start.test.sh — the Remote Control launcher (rc-start) against a real
# tmux on a private socket dir, with a stub `claude` that records how it was
# started. Guards against:
#   - a session whose claude has exited still counting as "running", so no
#     later rc-start ever restarts Remote Control (an `exec bash` tail kept it);
#   - `has-session -t rc` matching a prefix (`rc-other`) and skipping the start;
#   - the session's PATH lacking ~/.bun/bin (bunx), including on a tmux
#     server that was already running with a PATH without it;
#   - the working directory: RC_START_DIR, else the folder above the checkout,
#     found through the ~/.local/bin symlink setup.sh makes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

# A missing tmux is a named SKIP on a workstation, but a failure in CI, where
# a skipped suite would read as a pass.
if ! command -v tmux >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then
    echo "FAIL - tmux is not installed on this CI runner"
    exit 1
  fi
  echo "SKIP - tmux is not installed"
  exit 0
fi

TEST_HOME="$(mktemp -d)"
SHIM_DIR="$(mktemp -d)"
WORK_DIR="$(mktemp -d)"
TMUX_DIR="$(mktemp -d)"
CALLS="$TEST_HOME/claude-calls"
cleanup() {
  TMUX_TMPDIR="$TMUX_DIR" tmux kill-server 2>/dev/null
  rm -rf "$TEST_HOME" "$SHIM_DIR" "$WORK_DIR" "$TMUX_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_HOME/.local/bin" "$TEST_HOME/.bun/bin"
ln -s "$REPO_ROOT/rc-start" "$TEST_HOME/.local/bin/rc-start"

# The stub records its arguments, working directory and PATH, then exits
# with the code in $CALLS.exit or, with no such file, stays up like a running
# Remote Control. (A file, not an env var: on a tmux server that is already
# running, a new session gets the caller's PATH but none of its other
# variables.)
cat > "$SHIM_DIR/claude" <<'EOF'
#!/bin/sh
printf '%s|%s|%s\n' "$*" "$(pwd -P)" "$PATH" >> "$CALLS"
if [ -f "$CALLS.exit" ]; then exit "$(cat "$CALLS.exit")"; fi
exec sleep 60
EOF
chmod +x "$SHIM_DIR/claude"

export HOME="$TEST_HOME" CALLS TMUX_TMPDIR="$TMUX_DIR" SHELL=/bin/sh
export PATH="$SHIM_DIR:/usr/bin:/bin"
# Nothing of the caller's may steer the launcher or tmux: the log location,
# the working directory, a tmux config, an enclosing tmux client.
unset TMUX XDG_STATE_HOME XDG_CONFIG_HOME RC_START_DIR

rc_start() { "$TEST_HOME/.local/bin/rc-start"; }
calls() { if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi; }
wait_for() { # wait_for <seconds> <command…>
  local i=0 limit=$(($1 * 10)); shift
  until "$@"; do
    i=$((i + 1)); [ "$i" -ge "$limit" ] && return 1
    sleep 0.1
  done
}
calls_at_least() { [ "$(calls)" -ge "$1" ]; }
no_rc_session() { ! tmux has-session -t '=rc' 2>/dev/null; }

# 1. A server already running without bun on its PATH: the new session still
#    gets ~/.bun/bin, and a session named rc-other is not mistaken for rc.
tmux -f /dev/null new-session -d -s rc-other 'sleep 60'
RC_START_DIR="$WORK_DIR" rc_start >/dev/null
if wait_for 5 calls_at_least 1; then
  IFS='|' read -r args cwd path < "$CALLS"
  [ "$args" = "remote-control --permission-mode auto" ] \
    && ok "starts claude remote-control" || fail "unexpected claude args: $args"
  [ "$cwd" = "$(cd -P "$WORK_DIR" && pwd)" ] \
    && ok "RC_START_DIR is the working directory" || fail "working directory was $cwd"
  case ":$path:" in
    *":$TEST_HOME/.bun/bin:"*) ok "the session's PATH has ~/.bun/bin even on a server that was already running" ;;
    *) fail "the session's PATH lacks \$HOME/.bun/bin: $path" ;;
  esac
else
  fail "rc-start did not start claude while only rc-other was running (prefix match)"
fi

# 2. While it runs, a second call starts nothing.
out="$(RC_START_DIR="$WORK_DIR" rc_start)"
sleep 0.5
if [ "$(calls)" = 1 ] && printf '%s' "$out" | grep -q 'already running'; then
  ok "a second call while it runs starts nothing"
else
  fail "second call: $(calls) claude starts, output: $out"
fi
tmux kill-session -t '=rc'

# 3. Once claude exits, the session ends and the exit is logged, so the next
#    call starts it again.
: > "$CALLS"
echo 7 > "$CALLS.exit"
RC_START_DIR="$WORK_DIR" rc_start >/dev/null
if wait_for 5 calls_at_least 1 && wait_for 5 no_rc_session; then
  ok "the rc session ends when claude exits"
else
  fail "the rc session outlived claude"
fi
if grep -q 'remote-control exited (7)' "$TEST_HOME/.local/state/rc-start.log" 2>/dev/null; then
  ok "the exit status is logged"
else
  fail "no exit line in ~/.local/state/rc-start.log"
fi
RC_START_DIR="$WORK_DIR" rc_start >/dev/null
if wait_for 5 calls_at_least 2; then
  ok "the next call restarts Remote Control after it exited"
else
  fail "rc-start did not restart Remote Control after it exited ($(calls) starts)"
fi
rm -f "$CALLS.exit"
wait_for 5 no_rc_session || tmux kill-session -t '=rc' 2>/dev/null

# 4. Without RC_START_DIR: the folder above the checkout, through the symlink.
: > "$CALLS"
rc_start >/dev/null
if wait_for 5 calls_at_least 1; then
  IFS='|' read -r _ cwd _ < "$CALLS"
  [ "$cwd" = "$(cd -P "$REPO_ROOT/.." && pwd)" ] \
    && ok "defaults to the folder that holds the checkout, through the symlink" \
    || fail "default working directory was $cwd"
else
  fail "rc-start did not start claude for the default directory"
fi
tmux kill-session -t '=rc' 2>/dev/null

# 5. --hold keeps running after starting the session.
timeout 2 "$TEST_HOME/.local/bin/rc-start" --hold >/dev/null
[ $? -eq 124 ] && ok "--hold blocks" || fail "--hold returned instead of blocking"

echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
