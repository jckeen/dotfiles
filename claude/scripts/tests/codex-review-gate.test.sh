#!/usr/bin/env bash
# codex-review-gate.test.sh — fixture tests for codex-review-gate.sh (#198).
# Builds throwaway git repos under mktemp and stubs `codex` with a PATH shim
# that captures argv + stdin, honors `-o <file>` by replaying a crafted JSON
# result, and exits with a crafted rc — so the gate's fenced stdin delivery,
# fail-closed JSON validation, self-review guard, degraded base handling, and
# rc-vs-approve distrust are asserted without a real Codex session. Run
# directly; exit 1 on any failure. Mirrors antigravity-review-gate.test.sh.
set -uo pipefail

resolve_script_path() {
  local target="$1" dir
  while [[ -L "$target" ]]; do
    dir="$(cd -P "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    [[ "$target" != /* ]] && target="$dir/$target"
  done
  cd -P "$(dirname "$target")" && pwd
}
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
GATE="$SCRIPT_DIR/../codex-review-gate.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP-FAIL: jq is required to test the gate's JSON parsing" >&2; exit 1; }

pass=0
failed=0
R=""

# One PATH shim for the whole run; per-test capture dir via CODEX_FAKE_DIR.
# The shim replays $CODEX_FAKE_DIR/output into the file the gate passes after
# `-o`, exits with $CODEX_FAKE_DIR/rc (default 0), and records how it was
# called, so tests can assert both the gate's verdict handling and the
# prompt-delivery channel.
SHIM_DIR="$(mktemp -d)"
cat > "$SHIM_DIR/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_FAKE_DIR/argv"
cat > "$CODEX_FAKE_DIR/stdin"
touch "$CODEX_FAKE_DIR/invoked"
printf '%s\n' "$0" > "$CODEX_FAKE_DIR/executable"
[ ! -f "$CODEX_FAKE_DIR/hang" ] || exec python3 "$CODEX_FAKE_DIR/hang"
[ ! -f "$CODEX_FAKE_DIR/mutate" ] || bash "$CODEX_FAKE_DIR/mutate"
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && cat "$CODEX_FAKE_DIR/output" > "$a"
  prev="$a"
done
[ -f "$CODEX_FAKE_DIR/stderr" ] && cat "$CODEX_FAKE_DIR/stderr" >&2
rc=0
[ -f "$CODEX_FAKE_DIR/rc" ] && rc="$(cat "$CODEX_FAKE_DIR/rc")"
exit "$rc"
EOF
chmod +x "$SHIM_DIR/codex"
export PATH="$SHIM_DIR:$PATH"
export CODEX_FAKE_DIR=""
export CODEX_GATE_BIN="$SHIM_DIR/codex"
unset CODEX_GATE_TIMEOUT
TEST_HOME="$SHIM_DIR/home"
mkdir -p "$TEST_HOME"
CHECK_OUTPUT=""
CHECK_DIAGNOSTIC=""
trap 'rm -f -- "$CHECK_DIAGNOSTIC"; rm -rf -- "$SHIM_DIR"' EXIT
unset CODEX_GATE_REQUIRED
unset CODEX_GATE_ALLOW_INSTRUCTION_DIFF
unset GATE_FORCE_FULL
unset GATE_TIER1_MAX_LINES

new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
  echo "base line" > "$R/code.txt"
  git -C "$R" add code.txt
  git -C "$R" commit -qm "init"
  CODEX_FAKE_DIR="$(mktemp -d)"
  : > "$CODEX_FAKE_DIR/output"
}

approve_clean() {
  printf '%s' '{"verdict":"approve","summary":"looks fine","findings":[]}' > "$CODEX_FAKE_DIR/output"
}

# check <name> <expected-exit> [<required output fragment>] [gate args...]
check() {
  local name="$1" want="$2" frag="${3:-}"
  shift 3 || shift $#
  local out rc
  rm -f -- "$CHECK_DIAGNOSTIC"
  out="$(cd "$R" && env HOME="$TEST_HOME" "$GATE" "$@" 2>&1)"
  rc=$?
  # shellcheck disable=SC2034  # Read by assert's evaluated conditions.
  CHECK_OUTPUT="$out"
  CHECK_DIAGNOSTIC="$(sed -n 's/^  Private Codex diagnostic: //p' <<<"$out")"
  local ok=1
  [ "$rc" -eq "$want" ] || ok=0
  if [ -n "$frag" ] && ! grep -qF -- "$frag" <<<"$out"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (want rc=$want frag='$frag'; got rc=$rc)"
    echo "$out" | sed 's/^/      | /'
  fi
}

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (condition: $cond)"
  fi
}

# ── clean approve passes; prompt + fenced diff travel on stdin, never argv ──
new_repo
echo "SECRET_MARKER_XYZ = changed" >> "$R/code.txt"
approve_clean
check "clean approve passes" 0 "Codex review passed" --uncommitted --no-issues
assert "prompt+diff delivered on stdin" "grep -q 'SECRET_MARKER_XYZ' '$CODEX_FAKE_DIR/stdin'"
assert "fence marker present on stdin" "grep -q 'UNTRUSTED_DIFF_' '$CODEX_FAKE_DIR/stdin'"
assert "diff absent from codex argv" "! grep -q 'SECRET_MARKER_XYZ' '$CODEX_FAKE_DIR/argv'"
assert "fence preamble absent from codex argv" "! grep -q 'UNTRUSTED' '$CODEX_FAKE_DIR/argv'"
assert "structured schema requested" "grep -q -- '--output-schema' '$CODEX_FAKE_DIR/argv'"
assert "review runs sandboxed read-only" "grep -qx 'read-only' '$CODEX_FAKE_DIR/argv'"
rm -rf "$R"

# ── installed runtime preference and explicit override ─────────────────
new_repo
echo "change" >> "$R/code.txt"
approve_clean
managed="$TEST_HOME/.codex/packages/standalone/current/bin/codex"
mkdir -p "$(dirname "$managed")" "$SHIM_DIR/release/bin"
cp "$SHIM_DIR/codex" "$SHIM_DIR/release/bin/codex"
ln -s "$SHIM_DIR/release/bin/codex" "$managed"
unset CODEX_GATE_BIN
check "managed standalone wins over an older PATH CLI" 0 "Codex review passed" --uncommitted --no-issues
assert "receipt and invocation pin the managed executable" "jq -e --arg exe '$SHIM_DIR/release/bin/codex' '.reviewer.executable == \$exe' '$R/.git/review-receipts/codex.json' >/dev/null && grep -qxF '$SHIM_DIR/release/bin/codex' '$CODEX_FAKE_DIR/executable'"
export CODEX_GATE_BIN="$SHIM_DIR/codex"
check "explicit binary overrides the managed installation" 0 "Codex review passed" --uncommitted --no-issues
assert "receipt and invocation agree on explicit binary" "jq -e --arg exe '$SHIM_DIR/codex' '.reviewer.executable == \$exe' '$R/.git/review-receipts/codex.json' >/dev/null && grep -qxF '$SHIM_DIR/codex' '$CODEX_FAKE_DIR/executable'"
export CODEX_GATE_BIN=codex
check "explicit command name intentionally uses PATH" 0 "Codex review passed" --uncommitted --no-issues
assert "explicit PATH selection wins over managed CLI" "grep -qxF '$SHIM_DIR/codex' '$CODEX_FAKE_DIR/executable'"
for invalid in "$SHIM_DIR/missing" "$SHIM_DIR" ''; do
  export CODEX_GATE_BIN="$invalid"
  rm -f "$CODEX_FAKE_DIR/invoked"
  check "invalid explicit binary fails closed" 3 "CODEX_GATE_BIN" --uncommitted --no-issues
  assert "invalid override never falls back or leaves a receipt" "[ ! -e '$CODEX_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/codex.json' ]"
done
unset CODEX_GATE_BIN
rm "$managed"
check "PATH remains the fallback without a standalone install" 0 "Codex review passed" --uncommitted --no-issues
assert "fallback invokes the fixture CLI" "grep -qxF '$SHIM_DIR/codex' '$CODEX_FAKE_DIR/executable'"
export CODEX_GATE_BIN="$SHIM_DIR/codex"
rm -rf "$R"

# ── failures expose a safe hint and a bounded private diagnostic ─────────
new_repo
echo "change" >> "$R/code.txt"
approve_clean
echo 1 > "$CODEX_FAKE_DIR/rc"
python3 - "$CODEX_FAKE_DIR/stderr" <<'PYERR'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text('PRIVATE_PROMPT_MARKER' * 2000 + '\nERROR: The configured model requires a newer version of Codex. PRIVATE_TOKEN_MARKER\n')
PYERR
check "runtime failure explains incompatible CLI" 3 "requires a newer Codex CLI" --uncommitted --no-issues
assert "failure output never dumps stderr secrets" "[[ \$CHECK_OUTPUT != *PRIVATE_PROMPT_MARKER* && \$CHECK_OUTPUT != *PRIVATE_TOKEN_MARKER* ]]"
assert "private diagnostic retains bounded error details" "python3 -c 'from pathlib import Path; import sys; p=Path(sys.argv[1]); assert p.is_file() and 0 < p.stat().st_size <= 16384; assert p.stat().st_mode & 0o777 == 0o600; assert b\"PRIVATE_TOKEN_MARKER\" in p.read_bytes()' \"\$CHECK_DIAGNOSTIC\""
assert "failed runtime cannot issue a receipt" "[ ! -e '$R/.git/review-receipts/codex.json' ]"
: > "$CODEX_FAKE_DIR/output"
echo 0 > "$CODEX_FAKE_DIR/rc"
check "empty output also gives safe diagnostic context" 3 "requires a newer Codex CLI" --uncommitted --no-issues --require
assert "empty-output diagnostic never dumps stderr secrets" "[[ \$CHECK_OUTPUT != *PRIVATE_PROMPT_MARKER* && \$CHECK_OUTPUT != *PRIVATE_TOKEN_MARKER* ]]"
rm -rf "$R"

# BSD mktemp passes explicit templates directly to mkstemp, which requires
# trailing Xs. Exercise that interface on Linux too, where GNU mktemp accepts
# a suffix that would fail on macOS.
new_repo
echo "change" >> "$R/code.txt"
approve_clean
export CODEX_TEST_REAL_MKTEMP
CODEX_TEST_REAL_MKTEMP="$(type -P mktemp)"
cat > "$SHIM_DIR/mktemp" <<'PYMKTEMP'
#!/usr/bin/env python3
import ctypes
import os
import sys
args = sys.argv[1:]
if len(args) == 1 and args[0].startswith('/'):
    template = ctypes.create_string_buffer(os.fsencode(args[0]))
    libc = ctypes.CDLL(None, use_errno=True)
    fd = libc.mkstemp(template)
    if fd < 0:
        sys.exit('mkstemp: ' + os.strerror(ctypes.get_errno()))
    os.close(fd)
    print(os.fsdecode(template.value))
else:
    os.execv(os.environ['CODEX_TEST_REAL_MKTEMP'], ['mktemp', *args])
PYMKTEMP
chmod +x "$SHIM_DIR/mktemp"
check "BSD explicit tempfile templates permit a clean review" 0 "Codex review passed" --uncommitted --no-issues
echo 1 > "$CODEX_FAKE_DIR/rc"
echo 'private diagnostic' > "$CODEX_FAKE_DIR/stderr"
check "BSD explicit tempfile templates retain failure diagnostics" 3 "Private Codex diagnostic:" --uncommitted --no-issues
rm -f "$SHIM_DIR/mktemp"
unset CODEX_TEST_REAL_MKTEMP
rm -rf "$R"

# ── bounded timeout terminates the reviewer and stubborn descendants ─────
new_repo
echo "change" >> "$R/code.txt"
approve_clean
for invalid in 0 -1 invalid; do
  export CODEX_GATE_TIMEOUT="$invalid"
  check "invalid timeout fails closed before dispatch" 3 "CODEX_GATE_TIMEOUT" --uncommitted --no-issues
  assert "invalid timeout never dispatches reviewer" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
done
cat > "$CODEX_FAKE_DIR/hang" <<'PYHANG'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen([sys.executable, '-c', 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(20)'])
Path(os.environ['CODEX_FAKE_DIR'], 'pids').write_text(f'{os.getpid()} {child.pid}')
time.sleep(10)
PYHANG
export CODEX_GATE_TIMEOUT=1
started=$SECONDS
check "hung review fails closed at the deadline" 3 "timed out after 1 seconds" --uncommitted --no-issues
assert "timeout and kill grace stay bounded" "(( SECONDS - $started < 9 ))"
assert "timeout does not issue a receipt" "[ ! -e '$R/.git/review-receipts/codex.json' ]"
assert "timeout kills the reviewer and its descendants" "python3 -c 'from pathlib import Path; import subprocess,sys; pids=Path(sys.argv[1]).read_text().split(); assert len(pids) == 2; states=[subprocess.run([\"ps\", \"-p\", pid, \"-o\", \"stat=\"], capture_output=True, text=True).stdout.strip() for pid in pids]; assert all(not state or state.startswith(\"Z\") for state in states), states' '$CODEX_FAKE_DIR/pids'"
unset CODEX_GATE_TIMEOUT
rm -rf "$R"

# Job control creates another group in the same owned session.
for lifecycle in job-control interrupt-cleanup interrupt-startup; do
  new_repo
  echo "change" >> "$R/code.txt"
  approve_clean
  if [[ "$lifecycle" == job-control ]]; then
    cat > "$CODEX_FAKE_DIR/hang" <<'PYJOB'
import os
os.execv('/bin/bash', ['bash', '-c', 'set -m; sleep 12 & echo "$$ $!" > "$CODEX_FAKE_DIR/pids"; wait'])
PYJOB
  elif [[ "$lifecycle" == interrupt-startup ]]; then
    cat > "$CODEX_FAKE_DIR/hang" <<'PYSTARTUP'
import os
from pathlib import Path
import signal
import time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(os.environ['CODEX_FAKE_DIR'], 'pids').write_text(str(os.getpid()))
time.sleep(12)
PYSTARTUP
    cat > "$CODEX_FAKE_DIR/sitecustomize.py" <<'PYSITE'
import os
from pathlib import Path
import signal
import subprocess
import time
original = subprocess.Popen
def popen(*args, **kwargs):
    process = original(*args, **kwargs)
    if kwargs.get('start_new_session'):
        for _ in range(100):
            if Path(os.environ['CODEX_FAKE_DIR'], 'pids').exists():
                break
            time.sleep(.01)
        os.kill(os.getpid(), signal.SIGINT)
    return process
subprocess.Popen = popen
PYSITE
    export PYTHONPATH="$CODEX_FAKE_DIR"
  else
    cat > "$CODEX_FAKE_DIR/hang" <<'PYINTERRUPT'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGINT, signal.SIG_IGN)
script = "import os,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(2); os.kill(int(__import__('sys').argv[1]), signal.SIGINT)"
child = subprocess.Popen([sys.executable, '-c', script, str(os.getppid())])
Path(os.environ['CODEX_FAKE_DIR'], 'pids').write_text(f'{os.getpid()} {child.pid}')
time.sleep(12)
PYINTERRUPT
  fi
  sleep 15 &
  unrelated_pid=$!
  export CODEX_GATE_TIMEOUT=1
  fragment="timed out after 1 seconds"
  [[ "$lifecycle" != interrupt-startup ]] || fragment="not trusting the result"
  check "$lifecycle fails closed" 3 "$fragment" --uncommitted --no-issues
  assert "$lifecycle does not issue a receipt" "[ ! -e '$R/.git/review-receipts/codex.json' ]"
  assert "$lifecycle terminates owned descendants" "python3 -c 'from pathlib import Path; import subprocess,sys; pids=Path(sys.argv[1]).read_text().split(); assert pids; states=[subprocess.run([\"ps\", \"-p\", pid, \"-o\", \"stat=\"], capture_output=True, text=True).stdout.strip() for pid in pids]; assert all(not state or state.startswith(\"Z\") for state in states), states' '$CODEX_FAKE_DIR/pids'"
  assert "$lifecycle preserves an unrelated process" "kill -0 '$unrelated_pid'"
  kill "$unrelated_pid"
  wait "$unrelated_pid" 2>/dev/null || true
  unset CODEX_GATE_TIMEOUT PYTHONPATH
  rm -rf "$R"
done

# An interrupt concurrent with successful wait must not mint approval.
new_repo
echo "change" >> "$R/code.txt"
approve_clean
cat > "$CODEX_FAKE_DIR/sitecustomize.py" <<'PYSUCCESS'
import os
import signal
import subprocess
original = subprocess.Popen
def popen(*args, **kwargs):
    process = original(*args, **kwargs)
    if kwargs.get('start_new_session'):
        original_wait = process.wait
        def wait(*args, **kwargs):
            result = original_wait(*args, **kwargs)
            os.kill(os.getpid(), signal.SIGINT)
            return result
        process.wait = wait
    return process
subprocess.Popen = popen
PYSUCCESS
export PYTHONPATH="$CODEX_FAKE_DIR"
check "interrupt concurrent with successful exit fails closed" 3 "not trusting the result" --uncommitted --no-issues
assert "interrupted success cannot issue a receipt" "[ ! -e '$R/.git/review-receipts/codex.json' ]"
unset PYTHONPATH
rm -rf "$R"

# Stable handles must reject a recycled PID and preserve captured identity.
cat > "$SHIM_DIR/check-signal-identity.py" <<'PYIDENTITY'
import ast
import ctypes
import errno
from pathlib import Path
import sys
from types import SimpleNamespace
source = Path(sys.argv[1]).read_text().split("python3 -c '\nimport ctypes", 1)[1]
source = 'import ctypes' + source.split("' \"$REVIEW_TIMEOUT\"", 1)[0]
tree = ast.parse(source)
definitions = [node for node in ast.walk(tree)
               if isinstance(node, (ast.FunctionDef, ast.ClassDef))
               and node.name in ('signal_member', 'UniqueIdentifier')]
namespace = dict(ctypes=ctypes, errno=errno)
exec(compile(ast.Module(body=definitions, type_ignores=[]), '<gate signaling>', 'exec'), namespace)
received, closed = [], []
namespace.update(sys=SimpleNamespace(platform='linux'),
                 os=SimpleNamespace(pidfd_open=lambda pid: 42, getsid=lambda pid: 999,
                                    close=closed.append, strerror=str),
                 signal=SimpleNamespace(pidfd_send_signal=lambda fd, sig: received.append((fd, sig))))
namespace['signal_member'](101, 202, 9)
assert received == [] and closed == [42], 'recycled PID outside owned session was signaled'
namespace['os'].getsid = lambda pid: 202
namespace['signal_member'](101, 202, 9)
assert received == [(42, 9)], 'Linux signal did not use the opened stable handle'

def vanished(pid):
    raise ProcessLookupError()
namespace['os'].pidfd_open = vanished
namespace['signal_member'](101, 202, 9)
assert received == [(42, 9)], 'vanished PID fell back to unsafe delivery'

UniqueIdentifier = namespace['UniqueIdentifier']
assert ctypes.sizeof(UniqueIdentifier) == 56
AuditToken = ctypes.c_uint32 * 8
received.clear()
def pidinfo(pid, flavor, arg, pointer, size):
    assert flavor == 17 and size == 56
    ctypes.cast(pointer, ctypes.POINTER(UniqueIdentifier)).contents.idversion = 303
    return size

def deliver(pointer, signum):
    token = ctypes.cast(pointer, ctypes.POINTER(AuditToken)).contents
    received.append((token[5], token[7], signum))
    return errno.ESRCH  # The kernel rejects this vanished pidversion.
namespace.update(sys=SimpleNamespace(platform='darwin'), AuditToken=AuditToken,
                 libproc=SimpleNamespace(proc_pidinfo=pidinfo, proc_signal_with_audittoken=deliver))
namespace['os'].getsid = lambda pid: 999
namespace['signal_member'](101, 202, 9)
assert received == [], 'Darwin reused PID outside the session was signaled'
namespace['os'].getsid = lambda pid: 202
namespace['signal_member'](101, 202, 0)
assert received == [], 'Darwin startup called its signal API with invalid signal zero'
namespace['signal_member'](101, 202, 9)
assert received == [(101, 303, 9)], 'Darwin signal lost captured pidversion'
PYIDENTITY
assert "stable signals reject stale PIDs on Linux and Darwin" "python3 '$SHIM_DIR/check-signal-identity.py' '$GATE'"

# ── fail CLOSED on unparseable / nonconforming JSON ───────────────────
new_repo
echo "change" >> "$R/code.txt"
printf '%s' 'this is not JSON at all' > "$CODEX_FAKE_DIR/output"
check "unparseable output blocks" 2 "not the expected JSON shape" --uncommitted --no-issues
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf '%s' '{"verdict":"lgtm","summary":"?","findings":[]}' > "$CODEX_FAKE_DIR/output"
check "unknown verdict blocks" 2 "not the expected JSON shape" --uncommitted --no-issues
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf '%s' '{"verdict":"approve","summary":"?","findings":[{"severity":"catastrophic","title":"x","file":"code.txt","line_start":1}]}' > "$CODEX_FAKE_DIR/output"
check "unknown severity blocks" 2 "not the expected JSON shape" --uncommitted --no-issues
rm -rf "$R"

# ── whole-verdict handling ─────────────────────────────────────────────
new_repo
echo "change" >> "$R/code.txt"
printf '%s' '{"verdict":"needs-attention","summary":"bug","findings":[{"severity":"high","title":"real bug","file":"code.txt","line_start":1,"body":"boom","recommendation":"fix"}]}' > "$CODEX_FAKE_DIR/output"
check "high finding blocks" 2 "BLOCKING findings" --uncommitted --no-issues
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf '%s' '{"verdict":"needs-attention","summary":"something is off","findings":[]}' > "$CODEX_FAKE_DIR/output"
check "needs-attention with zero findings fails closed" 2 "(fail closed)" --uncommitted --no-issues
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf '%s' '{"verdict":"needs-attention","summary":"nit only","findings":[{"severity":"low","title":"nit","file":"code.txt","line_start":1,"body":"minor","recommendation":"maybe"}]}' > "$CODEX_FAKE_DIR/output"
check "low-only findings do not block" 0 "Codex review passed" --uncommitted --no-issues
rm -rf "$R"

# ── rc-vs-approve guard: non-zero exit + clean approve is distrusted ──
new_repo
echo "change" >> "$R/code.txt"
approve_clean
echo 1 > "$CODEX_FAKE_DIR/rc"
check "nonzero rc + clean approve blocks" 3 "not trusting the result" --uncommitted --no-issues
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
approve_clean
echo 1 > "$CODEX_FAKE_DIR/rc"
check "nonzero rc + clean approve fails hard with --require" 3 "not trusting the result" --uncommitted --no-issues --require
rm -rf "$R"

# ── degrade on missing review output ───────────────────────────────────
new_repo
echo "change" >> "$R/code.txt"
: > "$CODEX_FAKE_DIR/output"
check "empty output degrades open with a warning" 0 "produced no review output" --uncommitted --no-issues
check "empty output fails hard with --require" 3 "produced no review output" --uncommitted --no-issues --require
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
: > "$CODEX_FAKE_DIR/output"
for i in $(seq 1 100); do echo "verbose stderr line $i"; done > "$CODEX_FAKE_DIR/stderr"
check "long stderr reaches the degrade path without pipefail 141" 0 "produced no review output" --uncommitted --no-issues
rm -rf "$R"

# ── unresolved base: never a false 'nothing to review'; hard with --require ──
new_repo
git -C "$R" checkout -qb feature
echo "committed work" >> "$R/code.txt"
git -C "$R" commit -qam "ahead"
approve_clean
check "unresolved base blocks" 2 "could not be resolved" --base does-not-exist --no-issues
assert "codex not invoked on unresolved base" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
check "unresolved base fails hard with --require" 2 "could not be resolved" --base does-not-exist --no-issues --require
rm -rf "$R"

# ── self-review guard: instruction-surface diffs block a codex self-review ──
new_repo
echo "steer the reviewer" > "$R/AGENTS.md"
approve_clean
check "diff touching AGENTS.md blocks" 2 "instruction surface" --uncommitted --no-issues
assert "codex not invoked on instruction-surface diff" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
mkdir -p "$R/codex"
echo "steer the reviewer" > "$R/codex/config.toml"
approve_clean
check "diff touching codex/ blocks" 2 "instruction surface" --uncommitted --no-issues
rm -rf "$R"

new_repo
echo "steer the reviewer" > "$R/AGENTS.md"
approve_clean
export CODEX_GATE_ALLOW_INSTRUCTION_DIFF=1
check "CODEX_GATE_ALLOW_INSTRUCTION_DIFF=1 overrides the guard" 0 "Instruction-surface diff allowed" --uncommitted --no-issues
unset CODEX_GATE_ALLOW_INSTRUCTION_DIFF
assert "codex invoked once the guard is overridden" "[ -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

# Rename laundering must not slip past the guard: `git mv AGENTS.md notes.md`
# lists only the destination under rename detection; --no-renames restores
# both sides so the source path still trips the guard.
new_repo
echo "reviewer instructions" > "$R/AGENTS.md"
git -C "$R" add AGENTS.md
git -C "$R" commit -qm "add instructions"
git -C "$R" mv AGENTS.md archive-notes.md
approve_clean
check "renaming AGENTS.md away still trips the guard" 2 "instruction surface" --uncommitted --no-issues
assert "codex not invoked on the rename-laundered guard diff" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

# The gate machinery itself is self-review-guarded: the running gate has
# already sourced the working-tree gate-lib.sh, so a diff editing it must not
# be certified by that same code.
new_repo
echo "malicious edit" > "$R/gate-lib.sh"
approve_clean
check "diff touching gate-lib.sh blocks" 2 "gate machinery" --uncommitted --no-issues
assert "codex not invoked on a gate-machinery diff" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
mkdir -p "$R/claude/scripts"
echo "malicious edit" > "$R/claude/scripts/antigravity-review-gate.sh"
approve_clean
check "diff touching a review-gate script blocks" 2 "gate machinery" --uncommitted --no-issues
rm -rf "$R"

# ── #212: proportionality valve ────────────────────────────────────────
new_repo
printf '# Title\n\nA sentence of documentation.\n' > "$R/README.md"
approve_clean
check "docs-only small diff takes the tier-1 skip" 0 "tier-1 skip" --uncommitted --no-issues
assert "codex not invoked on a tier-1 skip" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
printf '# Title\n' > "$R/README.md"
approve_clean
export GATE_FORCE_FULL=1
check "GATE_FORCE_FULL=1 forces the full pass on a docs-only diff" 0 "Codex review passed" --uncommitted --no-issues
unset GATE_FORCE_FULL
assert "codex invoked under GATE_FORCE_FULL" "[ -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
printf 'notes about rotation\n' > "$R/token-rotation.md"
approve_clean
check "risk-surface filename escalates to the full pass" 0 "Codex review passed" --uncommitted --no-issues
assert "codex invoked for the risk-surface diff" "[ -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
printf 'small change\n' > "$R/widget.xyz"
approve_clean
check "unclassified file escalates to the full pass" 0 "Codex review passed" --uncommitted --no-issues
assert "codex invoked for the unclassified diff" "[ -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
printf 'line1\nline2\nline3\nline4\nline5\n' > "$R/README.md"
approve_clean
export GATE_TIER1_MAX_LINES=2
check "docs diff above the size cap takes the full pass" 0 "Codex review passed" --uncommitted --no-issues
unset GATE_TIER1_MAX_LINES
assert "codex invoked above the size cap" "[ -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
printf '# Title\n' > "$R/README.md"
approve_clean
check "adversarial --claim forces the full pass on a docs-only diff" 0 "Codex review passed" --uncommitted --no-issues --claim "the docs are accurate"
assert "codex invoked when a claim is given" "[ -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

# Rename laundering: `git mv risk.sh notes.md` must NOT classify as docs-only —
# --no-renames lists both sides, and the source path escalates to a full pass.
new_repo
mkdir -p "$R/claude/hooks"
printf '#!/bin/sh\nexit 0\n' > "$R/claude/hooks/pre-push-guard.sh"
git -C "$R" add claude/hooks/pre-push-guard.sh
git -C "$R" commit -qm "add guard"
git -C "$R" mv claude/hooks/pre-push-guard.sh notes.md
approve_clean
check "renaming a risk surface to .md still takes the full pass" 0 "Codex review passed" --uncommitted --no-issues
assert "codex invoked for the rename-laundered diff" "[ -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

echo ""
for instruction in .codex/config.toml nested/codex/config.toml; do
  new_repo
  mkdir -p "$R/$(dirname "$instruction")"
  echo steer > "$R/$instruction"
  approve_clean
  check "self-review guard includes $instruction" 2 "instruction surface" --uncommitted --no-issues
  rm -rf "$R"
done

# A completed committed gate, and only that scope, supplies shipping evidence.
new_repo
git -C "$R" checkout -qb feature
echo committed >> "$R/code.txt"
git -C "$R" commit -qam work
approve_clean
check "committed pass records an outgoing receipt" 0 "Review receipt recorded" --no-issues
assert "common shipping checker accepts the gate receipt" "python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head '$(git -C "$R" rev-parse HEAD)' >/dev/null"
: > "$CODEX_FAKE_DIR/output"
check "later empty output produces no new approval" 0 "produced no review output" --no-issues
assert "failed retry invalidates the earlier lane receipt" "[ ! -f '$R/.git/review-receipts/codex.json' ]"
rm -rf "$R"

# Regression coverage for the workflow audit findings.
new_repo
git -C "$R" checkout -qb feature
echo committed >> "$R/code.txt"
git -C "$R" commit -qam work
echo docs > "$R/notes.md"
approve_clean
check "missing base blocks before dirty docs fallback" 2 "could not be resolved" --base missing --no-issues
assert "missing base never dispatches dirty fallback" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
rm -rf "$R"

for instruction in AGENTS.md nested/AGENTS.local.md codex/config.toml; do
  new_repo
  git -C "$R" checkout -qb feature
  echo committed >> "$R/code.txt"
  git -C "$R" commit -qam work
  mkdir -p "$R/$(dirname "$instruction")"
  echo 'changed instruction content' > "$R/$instruction"
  approve_clean
  check "dirty $instruction blocks committed review" 2 "instruction surface" --no-issues
  assert "dirty instructions never dispatch" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
  rm -rf "$R"
done

new_repo
echo change >> "$R/code.txt"
printf '%s' '{"verdict":"needs-attention","findings":[{"severity":"low","title":"nit","file":"code.txt","line_start":1}]}' > "$CODEX_FAKE_DIR/output"
echo 42 > "$CODEX_FAKE_DIR/rc"
check "failed CLI with low findings blocks" 3 "not trusting the result" --uncommitted --no-issues --require
check "failed CLI cannot degrade to success" 3 "not trusting the result" --uncommitted --no-issues
rm -rf "$R"

for asset in image.svg bundle.min.js; do
  for scope in tracked untracked; do
    new_repo
    printf '%s\n' 'ACTIVE_ASSET_MARKER alert(document.cookie)' > "$R/$asset"
    if [[ "$scope" == tracked ]]; then
      git -C "$R" checkout -qb feature
      git -C "$R" add "$asset"
      git -C "$R" commit -qm asset
    fi
    approve_clean
    check "$scope $asset is reviewed" 0 "Codex review passed" --no-issues
    assert "active $asset content is in prompt" "grep -q 'ACTIVE_ASSET_MARKER' '$CODEX_FAKE_DIR/stdin'"
    rm -rf "$R"
  done
done

# Filename exemptions cannot hide executable hooks or code named like docs/assets.
for active_path in .claude/hooks/check.lock LICENSE.py preview.png; do
  for scope in committed uncommitted; do
    new_repo
    mkdir -p "$R/$(dirname "$active_path")" "$R/.claude"
    printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"python3 .claude/hooks/check.lock"}]}]}}\n' > "$R/.claude/settings.json"
    printf '#!/usr/bin/env python3\nprint("before")\n' > "$R/$active_path"
    chmod +x "$R/$active_path"
    git -C "$R" add .claude/settings.json "$active_path"
    git -C "$R" commit -qm 'existing executable'
    git -C "$R" checkout -qb feature
    printf '#!/usr/bin/env python3\nprint("EXECUTABLE_REVIEW_MARKER")\n' > "$R/$active_path"
    if [[ "$scope" == committed ]]; then
      git -C "$R" commit -qam 'changed executable behavior'
    fi
    approve_clean
    check "$scope $active_path requires full review" 0 "Codex review passed" "--$scope" --no-issues --require
    assert "executable content reaches Codex" "grep -q 'EXECUTABLE_REVIEW_MARKER' '$CODEX_FAKE_DIR/stdin'"
    assert "executable receipt records actual review" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/codex.json' >/dev/null"
    if [[ "$scope" == committed ]]; then
      assert "reviewed executable receipt can ship" "python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" >/dev/null 2>&1"
    fi
    rm -rf "$R"
  done
done

for scope in committed uncommitted; do
  new_repo
  git -C "$R" checkout -qb feature
  mkdir -p "$R/.codex"
  printf 'CODEX_POLICY_MARKER\n' > "$R/.codex/policy.lock"
  if [[ "$scope" == committed ]]; then
    git -C "$R" add .codex/policy.lock
    git -C "$R" commit -qm 'instruction with passive suffix'
  fi
  check "$scope passive suffix cannot hide Codex instructions" 2 "Diff touches the Codex reviewer's own instruction surface" "--$scope" --no-issues --require
  assert "guarded instruction cannot issue an exemption receipt" "[ ! -e '$R/.git/review-receipts/codex.json' ]"
  rm -rf "$R"
done

for pathspec_setting in literal glob noglob icase conflicting all; do
  for changed_path in code.txt .codex/config.toml; do
    new_repo
    git -C "$R" checkout -qb feature
    mkdir -p "$R/$(dirname "$changed_path")"
    printf 'PATHSPEC_GATE_MARKER\n' > "$R/$changed_path"
    git -C "$R" add "$changed_path"
    git -C "$R" commit -qm 'pathspec environment fixture'
    approve_clean
    case "$pathspec_setting" in
      literal) export GIT_LITERAL_PATHSPECS=1 ;;
      glob) export GIT_GLOB_PATHSPECS=1 ;;
      noglob) export GIT_NOGLOB_PATHSPECS=1 ;;
      icase) export GIT_ICASE_PATHSPECS=1 ;;
      conflicting) export GIT_GLOB_PATHSPECS=1 GIT_NOGLOB_PATHSPECS=1 ;;
      all) export GIT_LITERAL_PATHSPECS=1 GIT_GLOB_PATHSPECS=1 GIT_NOGLOB_PATHSPECS=1 GIT_ICASE_PATHSPECS=1 ;;
    esac
    if [[ "$changed_path" == code.txt ]]; then
      check "$pathspec_setting environment still reviews code" 0 "Codex review passed" --committed --no-issues --require
      assert "pathspec environment preserves reviewer bytes" "grep -q 'PATHSPEC_GATE_MARKER' '$CODEX_FAKE_DIR/stdin'"
      assert "pathspec environment cannot issue a no-diff receipt" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/codex.json' >/dev/null"
    else
      check "$pathspec_setting environment preserves instruction guard" 2 "Diff touches the Codex reviewer's own instruction surface" --committed --no-issues --require
      assert "pathspec environment cannot exempt instructions" "[ ! -e '$R/.git/review-receipts/codex.json' ]"
    fi
    unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
    rm -rf "$R"
  done
done

for suffix in ' ' $'\n'; do
  new_repo
  git -C "$R" checkout -qb feature
  echo committed >> "$R/code.txt"
  git -C "$R" commit -qam 'twin repository fixture'
  sibling="$R"
  R="$R$suffix"
  cp -a "$sibling" "$R"
  printf 'TWIN_WORKTREE_MARKER\n' > "$R/code.txt"
  approve_clean
  check "whitespace twin reviews its own workspace" 0 "Codex review passed" --uncommitted --no-issues --require
  assert "whitespace twin bytes reach Codex" "grep -q 'TWIN_WORKTREE_MARKER' '$CODEX_FAKE_DIR/stdin'"
  assert "whitespace twin cannot create sibling receipt" "[ ! -e '$sibling/.git/review-receipts/codex.json' ]"
  printf 'dirty twin instructions\n' > "$R/AGENTS.md"
  rm -f "$CODEX_FAKE_DIR/invoked"
  check "whitespace twin dirty instructions block committed review" 2 "dirty instruction surface" --committed --no-issues --require
  assert "whitespace twin instruction guard prevents dispatch" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
  rm -rf "$R" "$sibling"
done

new_repo
echo source-directory >> "$R/code.txt"
copied_scripts="$SHIM_DIR/scripts"$'\n'
mkdir -p "$copied_scripts"
cp "$SCRIPT_DIR/../codex-review-gate.sh" "$SCRIPT_DIR/../gate-lib.sh" "$SCRIPT_DIR/../review-receipt.py" "$SCRIPT_DIR/../codex-review-schema.json" "$copied_scripts/"
original_gate="$GATE"
GATE="$copied_scripts/codex-review-gate.sh"
approve_clean
check "gate source directory preserves trailing newline" 0 "Codex review passed" --uncommitted --no-issues --require
assert "gate loaded from newline directory dispatches" "grep -q 'source-directory' '$CODEX_FAKE_DIR/stdin'"
GATE="$original_gate"
rm -rf "$R"

for checkout_state in staged-mode crlf sparse; do
  new_repo
  args=(--committed --no-issues --require)
  case "$checkout_state" in
    staged-mode)
      printf 'before\n' > "$R/image.png"
      git -C "$R" add image.png
      git -C "$R" commit -qm 'regular file'
      git -C "$R" config core.filemode false
      git -C "$R" update-index --chmod=+x image.png
      printf 'NATIVE_STATE_REVIEW_MARKER\n' > "$R/image.png"
      git -C "$R" add image.png
      args=(--uncommitted --no-issues --require)
      ;;
    crlf)
      printf 'Known instructions.\n' > "$R/AGENTS.md"
      git -C "$R" add AGENTS.md
      git -C "$R" commit -qm 'instructions'
      git -C "$R" config core.autocrlf true
      rm "$R/AGENTS.md"
      git -C "$R" checkout -- AGENTS.md
      git -C "$R" checkout -qb feature
      printf 'NATIVE_STATE_REVIEW_MARKER\n' > "$R/code.txt"
      git -C "$R" commit -qam 'code change'
      ;;
    sparse)
      mkdir -p "$R/docs" "$R/src"
      printf 'Known instructions.\n' > "$R/docs/AGENTS.md"
      printf 'before\n' > "$R/src/code.txt"
      git -C "$R" add docs src
      git -C "$R" commit -qm 'sparse fixture'
      git -C "$R" sparse-checkout init --cone --sparse-index
      git -C "$R" sparse-checkout set src
      git -C "$R" checkout -qb feature
      printf 'NATIVE_STATE_REVIEW_MARKER\n' > "$R/src/code.txt"
      git -C "$R" commit -qam 'code change'
      ;;
  esac
  approve_clean
  check "$checkout_state reaches required Codex review" 0 "Codex review passed" "${args[@]}"
  assert "native checkout state preserves review bytes" "grep -q 'NATIVE_STATE_REVIEW_MARKER' '$CODEX_FAKE_DIR/stdin'"
  assert "native checkout state gets full-review receipt" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/codex.json' >/dev/null"
  rm -rf "$R"
done

for normalization in auto autocrlf; do
  new_repo
  printf '\v%.0s' {1..20} > "$R/AGENTS.md"
  printf 'CRLF_BINARY_INSTRUCTION_MARKER\n' >> "$R/AGENTS.md"
  : > "$R/.gitattributes"
  [[ "$normalization" != auto ]] || printf 'AGENTS.md text=auto\n' > "$R/.gitattributes"
  git -C "$R" add AGENTS.md .gitattributes
  git -C "$R" commit -qm 'automatic binary classification'
  [[ "$normalization" != autocrlf ]] || git -C "$R" config core.autocrlf true
  python3 - "$R/AGENTS.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_bytes(path.read_bytes().replace(b'\n', b'\r\n'))
PY
  approve_clean
  check "$normalization binary instructions block committed Codex review" 2 "dirty instruction surface" --committed --no-issues --require
  assert "dirty binary instructions cannot dispatch committed review" "[ ! -f '$CODEX_FAKE_DIR/invoked' ]"
  check "$normalization binary instructions reach the Codex instruction guard" 2 "instruction" --uncommitted --no-issues --require
  CODEX_GATE_ALLOW_INSTRUCTION_DIFF=1 check "$normalization binary instructions require full Codex review" 0 "Codex review passed" --uncommitted --no-issues --require
  assert "binary instruction CRLF change reaches Codex" "grep -q 'CRLF_BINARY_INSTRUCTION_MARKER' '$CODEX_FAKE_DIR/stdin'"
  assert "binary instruction change cannot receive no-diff evidence" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/codex.json' >/dev/null"
  rm -rf "$R"
done

for normalization in text autocrlf; do
  new_repo
  ln -s $'SYMLINK_TARGET\nname' "$R/link.txt"
  : > "$R/.gitattributes"
  [[ "$normalization" != text ]] || printf 'link.txt text\n' > "$R/.gitattributes"
  git -C "$R" add link.txt .gitattributes
  git -C "$R" commit -qm 'symlink fixture'
  [[ "$normalization" != autocrlf ]] || git -C "$R" config core.autocrlf true
  rm "$R/link.txt"
  ln -s $'SYMLINK_TARGET\r\nname' "$R/link.txt"
  approve_clean
  check "$normalization cannot normalize away a symlink target change" 0 "Codex review passed" --uncommitted --no-issues --require
  assert "symlink target bytes reach Codex" "grep -q 'SYMLINK_TARGET' '$CODEX_FAKE_DIR/stdin'"
  assert "symlink target change gets a full-review receipt" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/codex.json' >/dev/null"
  rm -rf "$R"
done

for source_instruction in agents/skills/orchestrate/references/runtime-contracts.md agents/canon/fragments/shared.md claude/skills/example/reference.md claude/agents/reviewer.md agents/skills/example/references/policy.lock; do
  new_repo
  git -C "$R" checkout -qb feature
  mkdir -p "$R/$(dirname "$source_instruction")"
  printf 'SOURCE_INSTRUCTION_REVIEW_MARKER\n' > "$R/$source_instruction"
  git -C "$R" add "$source_instruction"
  git -C "$R" commit -qm 'source instruction'
  approve_clean
  check "$source_instruction requires full Codex review" 0 "Codex review passed" --committed --no-issues --require
  assert "source instruction reaches Codex" "grep -q 'SOURCE_INSTRUCTION_REVIEW_MARKER' '$CODEX_FAKE_DIR/stdin'"
  assert "source instruction receives reviewed shipping evidence" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/codex.json' >/dev/null && python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" >/dev/null 2>&1"
  rm -rf "$R"
done

for mutation in head index worktree untracked base; do
  new_repo
  git -C "$R" checkout -qb feature
  echo committed >> "$R/code.txt"
  git -C "$R" commit -qam work
  case "$mutation" in
    head) printf 'git commit --allow-empty -qm concurrent\n' > "$CODEX_FAKE_DIR/mutate" ;;
    index) printf 'echo staged >> code.txt; git add code.txt; git checkout -- code.txt\n' > "$CODEX_FAKE_DIR/mutate" ;;
    worktree) printf 'echo concurrent >> code.txt\n' > "$CODEX_FAKE_DIR/mutate" ;;
    untracked) printf 'echo concurrent > new.txt\n' > "$CODEX_FAKE_DIR/mutate" ;;
    base) printf 'git update-ref refs/heads/main HEAD\n' > "$CODEX_FAKE_DIR/mutate" ;;
  esac
  approve_clean
  check "$mutation changed during review blocks" 2 "changed during review" --no-issues
  rm -rf "$R"
done

for ignore_submodules in none all; do
  new_repo
  git -C "$R" checkout -qb feature
  git -C "$R" update-index --add --cacheinfo 160000 "$(git -C "$R" rev-parse HEAD)" vendor
  git -C "$R" commit -qm 'base gitlink'
  git -C "$R" update-ref refs/heads/main HEAD
  git -C "$R" update-index --force-remove vendor
  git -C "$R" commit -qm 'delete gitlink'
  git -C "$R" config diff.ignoreSubmodules "$ignore_submodules"
  approve_clean
  check "base gitlink deletion blocks with ignoreSubmodules=$ignore_submodules" 2 "submodule snapshots are unsupported" --committed --no-issues --require
  assert "unsupported base gitlink never dispatches a reviewer" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
  assert "unsupported base gitlink cannot issue an exemption receipt" "[ ! -e '$R/.git/review-receipts/codex.json' ]"
  rm -rf "$R"
done

for instruction in AGENTS.md .codex/config.toml .codex/cache/AGENTS.md; do
  for scope in explicit auto; do
    new_repo
    mkdir -p "$R/$(dirname "$instruction")"
    printf '%s\n' "$instruction" > "$R/.git/info/exclude"
    printf 'IGNORED_INSTRUCTION_MARKER\n' > "$R/$instruction"
    args=(--no-issues --require)
    [[ "$scope" != explicit ]] || args+=(--uncommitted)
    check "ignored $instruction blocks $scope self-review" 2 "Diff touches the Codex reviewer's own instruction surface" "${args[@]}"
    assert "ignored instructions never dispatch" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
    rm -rf "$R"
  done
done

for instruction in .claude/commands/check.md .gemini/commands/check.md .agents/example/guide.md; do
  new_repo
  git -C "$R" checkout -qb feature
  mkdir -p "$R/$(dirname "$instruction")"
  printf 'AGENT_DOCUMENT_MARKER\n' > "$R/$instruction"
  git -C "$R" add "$instruction"
  git -C "$R" commit -qm 'agent command documentation'
  approve_clean
  check "committed $instruction dispatches full review" 0 "Codex review passed" --committed --no-issues --require
  assert "agent document reaches reviewer" "grep -q 'AGENT_DOCUMENT_MARKER' '$CODEX_FAKE_DIR/stdin'"
  assert "agent document receives valid committed receipt" "python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" >/dev/null 2>&1"
  rm -rf "$R"
done

new_repo
echo change >> "$R/code.txt"
for private_path in .codex/auth.json .claude/.credentials.json .gemini/oauth_creds.json agents/skills/example/auth.json claude/skills/example/.credentials.json; do
  mkdir -p "$R/$(dirname "$private_path")"
  printf '%s\n' "$private_path" >> "$R/.git/info/exclude"
  printf '{"access_token":"SYNTHETIC_PRIVATE_CREDENTIAL_MARKER"}\n' > "$R/$private_path"
done
for instruction in .claude/settings.json .agents/example/SKILL.md agents/skills/example/cache/policy.md; do
  mkdir -p "$R/$(dirname "$instruction")"
  printf '%s\n' "$instruction" >> "$R/.git/info/exclude"
  printf 'REVIEW_AGENT_CONFIG_MARKER\n' > "$R/$instruction"
done
approve_clean
check "ignored runtime credentials allow ordinary review" 0 "Codex review passed" --uncommitted --no-issues --require
assert "ignored runtime credentials stay out of Codex stdin" "[ -s '$CODEX_FAKE_DIR/stdin' ] && ! grep -q 'SYNTHETIC_PRIVATE_CREDENTIAL_MARKER' '$CODEX_FAKE_DIR/stdin'"
assert "ignored agent config and skill still reach Codex" "grep -q 'REVIEW_AGENT_CONFIG_MARKER' '$CODEX_FAKE_DIR/stdin' && grep -q '.claude/settings.json' '$CODEX_FAKE_DIR/stdin' && grep -q '.agents/example/SKILL.md' '$CODEX_FAKE_DIR/stdin'"
assert "source bundle cache remains instruction data" "grep -q 'agents/skills/example/cache/policy.md' '$CODEX_FAKE_DIR/stdin'"
rm -rf "$R"

new_repo
git -C "$R" checkout -qb feature
seq 1 250 > "$R/notes.md"
git -C "$R" add notes.md
git -C "$R" commit -qm docs
export GATE_TIER1_MAX_LINES=0500
check "configured docs cap issues a receipt" 0 "tier-1 skip" --no-issues --require
assert "configured docs cap avoids reviewer dispatch" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
unset GATE_TIER1_MAX_LINES
assert "shipping accepts the captured custom cap" "python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" >/dev/null 2>&1"
export GATE_TIER1_MAX_LINES=2
approve_clean
check "same committed docs above custom cap dispatch review" 0 "Codex review passed" --committed --no-issues --require
assert "small custom cap invokes Codex" "[ -e '$CODEX_FAKE_DIR/invoked' ]"
unset GATE_TIER1_MAX_LINES
export GATE_TIER1_MAX_LINES=--invalid
approve_clean
check "leading-dash invalid cap escalates to full review" 0 "Codex review passed" --no-issues --require
unset GATE_TIER1_MAX_LINES
rm -rf "$R"

cat > "$SHIM_DIR/classify.py" <<'PY'
import os
import sys
print(os.environ['CLASSIFY_OUTPUT'])
sys.exit(int(os.environ.get('CLASSIFY_RC', '0')))
PY
export CLASSIFY_OUTPUT='{"tier":1,"reason":"captured docs policy"}' CLASSIFY_RC=0
assert "shared classifier accepts helper tier and reason" "(source '$SCRIPT_DIR/../gate-lib.sh'; RECEIPT_HELPER='$SHIM_DIR/classify.py'; GATE_RUN_DIR='$SHIM_DIR'; gate_classify_tier; [[ \$GATE_TIER == 1 && \$GATE_TIER_REASON == 'captured docs policy' ]])"
for CLASSIFY_OUTPUT in 'broken' '{}' '{"tier":1}' '{"tier":"1","reason":"docs"}' '{"tier":1,"reason":null}' '{"tier":0,"reason":"docs"}' $'{"tier":1,"reason":"docs"}\n{"tier":1,"reason":"docs"}'; do
  assert "malformed helper classification keeps full review" "(source '$SCRIPT_DIR/../gate-lib.sh'; RECEIPT_HELPER='$SHIM_DIR/classify.py'; GATE_RUN_DIR='$SHIM_DIR'; gate_classify_tier; [[ \$GATE_TIER == 2 ]])"
done
export CLASSIFY_OUTPUT='{"tier":1,"reason":"docs"}' CLASSIFY_RC=1
assert "failed helper classification keeps full review" "(source '$SCRIPT_DIR/../gate-lib.sh'; RECEIPT_HELPER='$SHIM_DIR/classify.py'; GATE_RUN_DIR='$SHIM_DIR'; gate_classify_tier; [[ \$GATE_TIER == 2 ]])"
unset CLASSIFY_OUTPUT CLASSIFY_RC

assert "explicit committed scope selects immutable objects" "(source '$SCRIPT_DIR/../gate-lib.sh'; FORCE_UNCOMMITTED=false; FORCE_COMMITTED=true; gate_select_diff_target; [[ \$GATE_SCOPE == committed ]])"

R="$(mktemp -d)"
check "outside Git keeps advisory warning" 0 "not inside a git work tree"
check "outside Git blocks required review" 3 "treating as a hard failure" --require
rm -rf "$R"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
