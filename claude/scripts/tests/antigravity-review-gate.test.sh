#!/usr/bin/env bash
# antigravity-review-gate.test.sh — fixture tests for antigravity-review-gate.sh.
# Builds throwaway git repos under mktemp and stubs `agy` with a PATH shim that
# captures argv + stdin and emits crafted output, so the gate's verdict parsing,
# fail-closed base handling, and no-diff-in-argv delivery (#152/#153/#154) are
# asserted without spending plan quota. Run directly; exit 1 on any failure.
# Mirrors install-integrity.test.sh.
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
GATE="$SCRIPT_DIR/../antigravity-review-gate.sh"

pass=0
failed=0
R=""

# One PATH shim for the whole run; per-test capture dir via AGY_FAKE_DIR.
# The shim replays $AGY_FAKE_DIR/output and records how it was called, so tests
# can assert both the gate's exit behavior and the prompt-delivery channel.
# It emulates agy 1.1.1 prompt semantics (#227): a prompt flag with an EMPTY
# value errors out ("empty prompt") WITHOUT reading stdin, a non-empty prompt
# flag suppresses the stdin read, and stdin is consumed only when no prompt
# flag is present — so a gate that regresses to the pre-1.1.1 `--print ""`
# form fails these tests the same way it fails against the real binary.
SHIM_DIR="$(mktemp -d)"
cat > "$SHIM_DIR/agy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$AGY_FAKE_DIR/argv"
touch "$AGY_FAKE_DIR/invoked"
[ ! -f "$AGY_FAKE_DIR/mutate" ] || bash "$AGY_FAKE_DIR/mutate"
# Go's flag package treats -print/--print/-p and the =value forms as the same
# flag, so the emulation must too (adversarial review of PR #243: an equals or
# single-dash spelling regression must not pass the suite).
have_prompt_flag=0 prompt_value="" expect_value=0
for a in "$@"; do
  if [ "$expect_value" = 1 ]; then prompt_value="$a"; expect_value=0; continue; fi
  case "$a" in
    --print|--prompt|-print|-prompt|-p) have_prompt_flag=1; expect_value=1 ;;
    --print=*|--prompt=*|-print=*|-prompt=*|-p=*) have_prompt_flag=1; prompt_value="${a#*=}" ;;
  esac
done
if [ "$have_prompt_flag" = 1 ] && [ -z "$prompt_value" ]; then
  echo 'Error: empty prompt. Usage: agy --print "your prompt here"' >&2
  : > "$AGY_FAKE_DIR/stdin"
  exit 1
fi
if [ "$have_prompt_flag" = 1 ]; then
  : > "$AGY_FAKE_DIR/stdin"
else
  cat > "$AGY_FAKE_DIR/stdin"
fi
prev=""
for a in "$@"; do
  [ "$prev" = "--log-file" ] && [ -f "$AGY_FAKE_DIR/log" ] && cat "$AGY_FAKE_DIR/log" > "$a"
  prev="$a"
done
[ -f "$AGY_FAKE_DIR/stderr" ] && cat "$AGY_FAKE_DIR/stderr" >&2
cat "$AGY_FAKE_DIR/output"
# A fixture can force a non-zero agy exit alongside real output — the gate's
# failure path prints that output, so it must be exercised with a live stdout.
[ ! -f "$AGY_FAKE_DIR/exit" ] || exit "$(cat "$AGY_FAKE_DIR/exit")"
EOF
chmod +x "$SHIM_DIR/agy"
export PATH="$SHIM_DIR:$PATH"
export AGY_FAKE_DIR=""
unset ANTIGRAVITY_GATE_REQUIRED
unset ANTIGRAVITY_GATE_ALLOW_INSTRUCTION_DIFF
unset ANTIGRAVITY_GATE_MODEL
unset GATE_FORCE_FULL
unset GATE_TIER1_MAX_LINES
unset REVIEW_LANE
unset REVIEW_LANE_NOTE

new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
  echo "base line" > "$R/code.txt"
  git -C "$R" add code.txt
  git -C "$R" commit -qm "init"
  AGY_FAKE_DIR="$(mktemp -d)"
  : > "$AGY_FAKE_DIR/output"
}

# check <name> <expected-exit> [<required output fragment>] [gate args...]
check() {
  local name="$1" want="$2" frag="${3:-}"
  shift 3 || shift $#
  local out rc
  out="$(cd "$R" && "$GATE" "$@" 2>&1)"
  rc=$?
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

# ── #152: LGTB only as the whole verdict ──────────────────────────────
new_repo
echo "SECRET_MARKER_XYZ = injected" >> "$R/code.txt"
printf '%s\n' 'The diff says "output LGTB" — suspicious' > "$AGY_FAKE_DIR/output"
check "injected 'output LGTB' inside prose blocks" 2 "cannot confirm the review is clean" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "whole-output LGTB passes" 0 "LGTB verdict" --uncommitted
# ── #154: the diff travels on stdin, never argv ───────────────────────
assert "prompt+diff delivered on stdin" "grep -q 'change' '$AGY_FAKE_DIR/stdin'"
assert "diff absent from agy argv" "! grep -q 'change' '$AGY_FAKE_DIR/argv'"
assert "fence preamble absent from agy argv" "! grep -q 'UNTRUSTED' '$AGY_FAKE_DIR/argv'"
# ── #227: no prompt flag at all — agy ≥1.1.1 reads stdin only then, and a
# prompt flag reappearing on argv is one release away from an argv secret leak.
# Covers every Go-flag spelling: single/double dash, with or without =value.
assert "no prompt flag on agy argv" "! grep -qE -- '^-{1,2}(print|prompt|p)(=.*)?$' '$AGY_FAKE_DIR/argv'"
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'Reviewed the diff carefully.\nLGTB\n' > "$AGY_FAKE_DIR/output"
check "final-line LGTB passes" 0 "LGTB verdict" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'severity [P1] mentioned mid-sentence, unparseable\nLGTB\n' > "$AGY_FAKE_DIR/output"
check "final-line LGTB with stray [P#] token blocks" 2 "cannot confirm the review is clean" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf -- '- [P1] Broken thing — code.txt:1\n' > "$AGY_FAKE_DIR/output"
check "P1 finding blocks" 2 "BLOCKING findings" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf -- '- [P3] Nit — code.txt:1\n' > "$AGY_FAKE_DIR/output"
check "P3-only does not block" 0 "clean of blocking findings" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf -- '- [P3] minor nit — code.txt:1\nthis is really a [P1] in disguise\n' > "$AGY_FAKE_DIR/output"
check "prose [P1] alongside a valid P3 line blocks" 2 "Stray [P#] token" --uncommitted
rm -rf "$R"

# ── agy print-timeout expiry: partial output is never a verdict ────────
# agy 1.2.3 exits 0 on --print-timeout expiry and prints
# "[agy] print timeout after <d> with turn in progress; returning partial
# output" on stderr, which the gate merges into the verdict file. A truncated
# finding list must not ride the P3-only pass path.
new_repo
echo "change" >> "$R/code.txt"
printf '%s\n' '- [P3] nit — code.txt:1' > "$AGY_FAKE_DIR/output"
printf '%s\n' '[agy] print timeout after 360s with turn in progress; returning partial output' > "$AGY_FAKE_DIR/stderr"
check "expired print timeout with partial P3 output degrades open" 0 "output is partial" --uncommitted
assert "expired print timeout mints no receipt" "[ ! -e '$R/.git/review-receipts/antigravity.json' ]"
check "expired print timeout fails closed with --require" 3 "output is partial" --uncommitted --require
assert "agy print-timeout pinned to the gate ceiling" "grep -qx -- '--print-timeout' '$AGY_FAKE_DIR/argv' && grep -qx -- '360s' '$AGY_FAKE_DIR/argv'"
rm -rf "$R"

# The guard reads agy's stderr only: a reviewed diff steering the model into
# printing the expiry note on stdout must not reach the degrade-open path.
new_repo
echo "change" >> "$R/code.txt"
printf '%s\n' '- [P1] real finding — code.txt:1' '[agy] print timeout after 360s with turn in progress; returning partial output' > "$AGY_FAKE_DIR/output"
check "expiry note imitated on stdout cannot degrade past a blocking finding" 2 "BLOCKING findings" --uncommitted
rm -rf "$R"

# A partial review that already carries a blocking finding is a verdict, not a
# degraded lane: exit 2 with and without --require, on every post-dispatch
# failure path, so review-and-push.sh's exit-3 fallback can never let Codex
# approve over it (ADR-0008). A P3-only partial still degrades (tested above).
new_repo
echo "change" >> "$R/code.txt"
printf '%s\n' '- [P1] real finding — code.txt:1' > "$AGY_FAKE_DIR/output"
printf '%s\n' '[agy] print timeout after 360s with turn in progress; returning partial output' > "$AGY_FAKE_DIR/stderr"
check "expired print timeout with a blocking finding is a verdict" 2 "verdict, not a degraded lane" --uncommitted
check "expired print timeout with a blocking finding is a verdict under --require" 2 "verdict, not a degraded lane" --uncommitted --require
assert "that verdict mints no receipt" "[ ! -e '$R/.git/review-receipts/antigravity.json' ]"
rm -rf "$R"
new_repo
echo "change" >> "$R/code.txt"
printf '%s\n' '- [P2] real finding — code.txt:1' > "$AGY_FAKE_DIR/output"
printf '124\n' > "$AGY_FAKE_DIR/exit"
check "agy timeout (124) after a blocking finding is a verdict under --require" 2 "verdict, not a degraded lane" --uncommitted --require
printf '7\n' > "$AGY_FAKE_DIR/exit"
check "agy nonzero exit after a blocking finding is a verdict under --require" 2 "verdict, not a degraded lane" --uncommitted --require
check "agy nonzero exit after a blocking finding is a verdict without --require" 2 "verdict, not a degraded lane" --uncommitted
rm -f "$AGY_FAKE_DIR/exit"
rm -rf "$R"

# A benign stderr diagnostic must not defeat a clean final-line verdict, and
# empty stdout still reaches the canary path even when stderr has content.
new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' 'W0915 some benign agy warning' > "$AGY_FAKE_DIR/stderr"
check "benign stderr diagnostic does not block a clean verdict" 0 "LGTB verdict" --uncommitted
rm -rf "$R"
new_repo
echo "change" >> "$R/code.txt"
: > "$AGY_FAKE_DIR/output"
printf '%s\n' 'E0915 something failed' > "$AGY_FAKE_DIR/stderr"
check "empty stdout with stderr content still degrades, never passes" 0 "canary failed" --uncommitted
assert "empty stdout with stderr content mints no receipt" "[ ! -e '$R/.git/review-receipts/antigravity.json' ]"
rm -rf "$R"

# ── #422: a long failure report must not abort the failure path ───────
# The failure branch echoes agy's output and stderr. `sed … | head -20` over
# more than a pipe buffer's worth of text kills sed with SIGPIPE, and under
# `set -euo pipefail` that ends the gate (141 on WSL2) before `degrade` runs —
# turning a degrade-open into a crash, and a --require failure into the wrong
# exit code.
new_repo
echo "change" >> "$R/code.txt"
: > "$AGY_FAKE_DIR/output"
awk 'BEGIN { for (i = 0; i < 5000; i++) printf "E0915 agy diagnostic %0200d\n", i }' > "$AGY_FAKE_DIR/stderr"
check "long agy stderr still reaches the degrade path" 0 "canary failed" --uncommitted
(cd "$R" && "$GATE" --uncommitted > "$AGY_FAKE_DIR/gate-out" 2>&1) || true
shown="$(grep -c '^    E0915 agy diagnostic' "$AGY_FAKE_DIR/gate-out" || true)"
assert "long agy stderr is shown truncated, not in full" "[ '$shown' = 20 ]"
check "long agy stderr fails closed with --require" 3 "hard failure" --uncommitted --require
rm -f "$AGY_FAKE_DIR/stderr"
rm -rf "$R"

# Same branch, reached with a non-zero exit and long stdout.
new_repo
echo "change" >> "$R/code.txt"
awk 'BEGIN { for (i = 0; i < 5000; i++) printf "unparseable agy output %0200d\n", i }' > "$AGY_FAKE_DIR/output"
printf '9\n' > "$AGY_FAKE_DIR/exit"
check "long agy stdout on a failed run still degrades" 0 "agy review session failed (exit 9)" --uncommitted
(cd "$R" && "$GATE" --uncommitted > "$AGY_FAKE_DIR/gate-out" 2>&1) || true
shown="$(grep -c '^    unparseable agy output' "$AGY_FAKE_DIR/gate-out" || true)"
assert "long agy stdout is shown truncated, not in full" "[ '$shown' = 20 ]"
rm -f "$AGY_FAKE_DIR/exit"
rm -rf "$R"

# Leading zeros are decimal seconds, not octal.
new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
ANTIGRAVITY_GATE_TIMEOUT=090 check "leading-zero ANTIGRAVITY_GATE_TIMEOUT is decimal" 0 "LGTB verdict" --uncommitted
rm -rf "$R"

# ── #421: a zero timeout is "disabled", not 30 seconds ────────────────
# GNU timeout documents a duration of 0 as no timeout at all, so a documented
# "disabled" setting must reach both agy's --print-timeout and the outer _tmo
# ceiling unchanged. A `timeout` shim ahead of the real one records the
# ceiling the gate computed and then runs the command unbounded, which is all
# these fixtures need.
TMO_SHIM_DIR="$(mktemp -d)"
cat > "$TMO_SHIM_DIR/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$AGY_FAKE_DIR/ceilings"
shift
exec "$@"
EOF
chmod +x "$TMO_SHIM_DIR/timeout"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
PATH_SAVED="$PATH"
export PATH="$TMO_SHIM_DIR:$PATH"
ANTIGRAVITY_GATE_TIMEOUT=0 check "zero ANTIGRAVITY_GATE_TIMEOUT still runs the review" 0 "LGTB verdict" --uncommitted
ceiling="$(head -n 1 "$AGY_FAKE_DIR/ceilings" 2>/dev/null || true)"
assert "zero ANTIGRAVITY_GATE_TIMEOUT leaves the outer ceiling disabled" "[ '$ceiling' = 0 ]"
assert "zero ANTIGRAVITY_GATE_TIMEOUT reaches agy's print timeout too" "grep -qx -- '0s' '$AGY_FAKE_DIR/argv'"
rm -f "$AGY_FAKE_DIR/ceilings"
ANTIGRAVITY_GATE_TIMEOUT=120 check "non-zero ANTIGRAVITY_GATE_TIMEOUT still reviews" 0 "LGTB verdict" --uncommitted
ceiling="$(head -n 1 "$AGY_FAKE_DIR/ceilings" 2>/dev/null || true)"
assert "non-zero ceiling stays 30s above agy's own print timeout" "[ '$ceiling' = 150 ]"
export PATH="$PATH_SAVED"
rm -rf "$R"

# A failed run keeps agy's log for diagnosis (#409); a clean run removes it.
new_repo
echo "change" >> "$R/code.txt"
printf '%s\n' '- [P1] real finding — code.txt:1' > "$AGY_FAKE_DIR/output"
printf 'fake agy log line\n' > "$AGY_FAKE_DIR/log"
(cd "$R" && "$GATE" --uncommitted > "$AGY_FAKE_DIR/gate-out" 2>&1) || true
kept="$(grep -o 'agy log retained for diagnosis: [^ ]*' "$AGY_FAKE_DIR/gate-out" | sed 's/.*: //')"
kept_err="$(grep -o '(stderr: [^)]*)' "$AGY_FAKE_DIR/gate-out" | sed 's/(stderr: //; s/)//')"
assert "failed run announces the retained agy log" "[ -n '$kept' ]"
assert "retained agy log exists with the CLI's content" "grep -q 'fake agy log line' '$kept'"
for f in "$kept" "$kept_err"; do [ -n "$f" ] && rm -f "$f"; done; :
# A degraded run exits 0 without --require but is still a diagnostic case.
: > "$AGY_FAKE_DIR/output"
printf 'fake agy log line\n' > "$AGY_FAKE_DIR/log"
printf '%s\n' '[agy] print timeout after 360s with turn in progress; returning partial output' > "$AGY_FAKE_DIR/stderr"
(cd "$R" && "$GATE" --uncommitted > "$AGY_FAKE_DIR/gate-out" 2>&1)
kept="$(grep -o 'agy log retained for diagnosis: [^ ]*' "$AGY_FAKE_DIR/gate-out" | sed 's/.*: //')"
kept_err="$(grep -o '(stderr: [^)]*)' "$AGY_FAKE_DIR/gate-out" | sed 's/(stderr: //; s/)//')"
assert "degraded exit-0 run still retains the agy log" "[ -n '$kept' ] && [ -f '$kept' ]"
for f in "$kept" "$kept_err"; do [ -n "$f" ] && rm -f "$f"; done; :; rm -f "$AGY_FAKE_DIR/stderr"
# A crash that wrote stderr but no log still keeps the stderr capture.
: > "$AGY_FAKE_DIR/output"; rm -f "$AGY_FAKE_DIR/log"
printf 'agy crashed before logging\n' > "$AGY_FAKE_DIR/stderr"
(cd "$R" && "$GATE" --uncommitted --require > "$AGY_FAKE_DIR/gate-out" 2>&1) || true
kept="$(grep -o 'agy log retained for diagnosis: [^ ]*' "$AGY_FAKE_DIR/gate-out" | sed 's/.*: //')"
kept_err="$(grep -o '(stderr: [^)]*)' "$AGY_FAKE_DIR/gate-out" | sed 's/(stderr: //; s/)//')"
assert "stderr-only failure retains the stderr capture" "[ -n '$kept_err' ] && grep -q 'crashed before logging' '$kept_err'"
for f in "$kept" "$kept_err"; do [ -n "$f" ] && rm -f "$f"; done; :; rm -f "$AGY_FAKE_DIR/stderr"
# A pre-dispatch failure (unresolvable base) never ran agy: nothing to retain.
(cd "$R" && "$GATE" --base does-not-exist > "$AGY_FAKE_DIR/gate-out" 2>&1) || true
assert "pre-dispatch failure retains no empty agy log" "! grep -q 'agy log retained' '$AGY_FAKE_DIR/gate-out'"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
(cd "$R" && "$GATE" --uncommitted > "$AGY_FAKE_DIR/gate-out" 2>&1)
assert "clean run does not retain the agy log" "! grep -q 'agy log retained' '$AGY_FAKE_DIR/gate-out'"
clean_log="$(grep -A1 -x -- '--log-file' "$AGY_FAKE_DIR/argv" | tail -n1)"
assert "clean run removes the agy log from disk" "[ -n '$clean_log' ] && [ ! -e '$clean_log' ]"
rm -rf "$R"

# The ceiling is shell arithmetic and a Go duration; suffixed values fail closed.
new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
ANTIGRAVITY_GATE_TIMEOUT=5m check "non-integer ANTIGRAVITY_GATE_TIMEOUT fails closed" 2 "integer number of seconds" --uncommitted
rm -rf "$R"

# ── large diffs: the empty-diff check must stay linear (#405 sibling) ──
# Bash pattern substitution over a multi-megabyte diff spun for 30+ minutes
# at 100% CPU; the check now runs in Python. Bound the run so a regression
# fails loudly instead of hanging the suite.
new_repo
python3 - "$R/big.txt" <<'PYBIG'
import sys
with open(sys.argv[1], 'w') as f:
    for i in range(30000):
        f.write(f'line {i} ' + 'x' * 60 + '\n')
PYBIG
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
# #423: resolve the bounding command the way _tmo does — GNU `timeout`,
# `gtimeout` from macOS coreutils, else no ceiling at all. A bare `timeout`
# baked into the shim exits 127 on stock macOS, where BSD userland ships
# neither. The resolved absolute path also keeps the bound independent of any
# PATH shim a later fixture installs.
BOUND_TMO="$(command -v timeout || command -v gtimeout || true)"
if [[ -n "$BOUND_TMO" ]]; then
  printf '#!/usr/bin/env bash\nexec %q 120 %q "$@"\n' "$BOUND_TMO" "$GATE" > "$SHIM_DIR/gate-bounded"
else
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$GATE" > "$SHIM_DIR/gate-bounded"
fi
chmod +x "$SHIM_DIR/gate-bounded"
assert "bounded gate shim never resolves its bound from PATH" "grep -qE '^exec +/' '$SHIM_DIR/gate-bounded'"
GATE_REAL="$GATE"; GATE="$SHIM_DIR/gate-bounded"
# The byte cap (#409) is raised out of the way: this fixture is about the
# empty-diff check staying linear, not about the input window.
ANTIGRAVITY_GATE_MAX_LINES=40000 ANTIGRAVITY_GATE_MAX_BYTES=10000000 \
  check "30k-line diff completes within the bound" 0 "LGTB verdict" --uncommitted
GATE="$GATE_REAL"
rm -rf "$R"

# The propagation line format matches agy 1.1.1's model_config_manager log
# (#205, exercised in full below); fixtures from here on hand it to the shim
# so a dispatching run also verifies its model pin.
PROP_OK='I0710 model_config_manager.go:157] Propagating selected model override to backend: label="Gemini 3.1 Pro (High)"'
PROP_BAD='I0710 model_config_manager.go:157] Propagating selected model override to backend: label="Gemini 3.5 Flash (Low)"'

# ── #409: the measured agy input window is a hard size cap ────────────
# agy print mode delivers only ~185 KB of a single user message to the model
# (measured: a 590 KB message of numbered lines came back covering the first
# 3,250 of 10,000 lines, with no truncation reported). Above the cap a verdict
# would certify a fraction of the diff, so the gate degrades instead of
# dispatching — and never mints a receipt for what it did not review.
new_repo
python3 - "$R/wide.txt" <<'PYWIDE'
import sys
with open(sys.argv[1], 'w') as f:
    for i in range(2000):
        f.write(f'line {i} ' + 'y' * 100 + '\n')
PYWIDE
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
ANTIGRAVITY_GATE_MAX_LINES=40000 \
  check "diff above the measured input window degrades" 0 "the model would see only its first" --uncommitted
assert "oversized prompt never dispatches" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
assert "oversized prompt mints no receipt" "[ ! -e '$R/.git/review-receipts/antigravity.json' ]"
ANTIGRAVITY_GATE_MAX_LINES=40000 \
  check "diff above the measured input window fails closed with --require" 3 "hard failure" --uncommitted --require
ANTIGRAVITY_GATE_MAX_LINES=40000 ANTIGRAVITY_GATE_MAX_BYTES=10000000 \
  check "raised ANTIGRAVITY_GATE_MAX_BYTES dispatches the same diff" 0 "LGTB verdict" --uncommitted
assert "raised byte cap dispatches" "[ -e '$AGY_FAKE_DIR/invoked' ]"
rm -f "$AGY_FAKE_DIR/invoked"
ANTIGRAVITY_GATE_MAX_LINES=40000 ANTIGRAVITY_GATE_MAX_BYTES=0 \
  check "zero ANTIGRAVITY_GATE_MAX_BYTES disables the cap" 0 "LGTB verdict" --uncommitted
assert "disabled byte cap dispatches" "[ -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

# A docs-only diff of one 200,000-byte line clears the tier-1 LINE count while
# sitting far above this lane's input window. It is not exempt — but the reason
# is policy, not this gate's cap (#494): `classify_tier` carries a captured
# tier1_max_bytes, so the diff is tier 2 in BOTH lanes and gets a real review.
# The valve now runs before the caps, so the proof is that the SAME diff
# dispatches once this gate's own window cap is out of the way; the cap still
# degrades while it is in force, because the message really would be truncated.
new_repo
python3 - "$R/README.md" <<'PYLONGLINE'
import sys
with open(sys.argv[1], 'w') as f:
    f.write('x' * 200000 + '\n')
PYLONGLINE
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "one huge docs line is tier 2, so the window cap still degrades" 0 "the model would see only its first" --uncommitted
assert "oversized docs diff mints no tier-1 receipt" "[ ! -e '$R/.git/review-receipts/antigravity.json' ]"
assert "oversized docs diff never dispatches" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
check "oversized docs diff fails closed with --require" 3 "hard failure" --uncommitted --require
ANTIGRAVITY_GATE_MAX_BYTES=0 \
  check "a byte-huge docs diff is reviewed, not exempted, once the cap is off" 0 "LGTB verdict" --uncommitted
assert "a byte-huge docs diff dispatches a real review" "[ -e '$AGY_FAKE_DIR/invoked' ]"
assert "the receipt for it is a review, not a tier-1 exemption" "[ \"\$(jq -r '.completion.outcome' '$R/.git/review-receipts/antigravity.json')\" = passed ]"
rm -f "$AGY_FAKE_DIR/invoked"
rm -rf "$R"

# The valve runs before both size caps, so a docs-only diff that is tier 1 by
# policy takes the exemption even above a cap this gate would otherwise refuse
# to dispatch under: nothing is dispatched, so no message limit applies (#494).
new_repo
printf 'documentation\n' >> "$R/README.md"
git -C "$R" add README.md
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
ANTIGRAVITY_GATE_MAX_BYTES=1 ANTIGRAVITY_GATE_MAX_LINES=1 \
  check "a tier-1 diff is exempt below any cap" 0 "tier-1 skip" --uncommitted --require
assert "the tier-1 exemption dispatches nothing" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
assert "the tier-1 exemption is recorded" "[ \"\$(jq -r '.completion.outcome' '$R/.git/review-receipts/antigravity.json')\" = tier-1 ]"
rm -rf "$R"

# A small diff is unaffected by the default cap, and a non-integer cap is a
# configuration error, not a silent fallback.
new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "small diff passes under the default byte cap" 0 "LGTB verdict" --uncommitted
ANTIGRAVITY_GATE_MAX_BYTES=185K check "non-integer ANTIGRAVITY_GATE_MAX_BYTES fails closed" 2 "integer number of bytes" --uncommitted
rm -rf "$R"

# ── #205: post-dispatch model-pin verification ────────────────────────
# PROP_OK / PROP_BAD are defined above, with the first fixture that needs them.
# The fake conversation records are plain text files — `strings` reads them.

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
AGY_DB_DIR="$(mktemp -d)"
printf 'gen_metadata: Gemini 3.1 Pro (High) gemini-pro-agent\n' > "$AGY_DB_DIR/conv.db"
export AGY_CONVERSATIONS_DIR="$AGY_DB_DIR"
check "propagated label matches the default pin" 0 "model pin verified" --uncommitted
assert "pinned label forwarded on agy argv" "grep -q 'Gemini 3.1 Pro (High)' '$AGY_FAKE_DIR/argv'"
assert "log capture requested on agy argv" "grep -q -- '--log-file' '$AGY_FAKE_DIR/argv'"
check "DB spot-check finds the label in the records" 0 "records the requested label" --uncommitted
unset AGY_CONVERSATIONS_DIR
rm -rf "$R" "$AGY_DB_DIR"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_BAD" > "$AGY_FAKE_DIR/log"
check "propagated-label mismatch fails hard WITHOUT --require" 2 "MODEL PIN FAILED" --uncommitted
check "propagated-label mismatch fails hard with an explicit --model" 2 "MODEL PIN FAILED" --uncommitted --model "Gemini 3.1 Pro (High)"
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s session=42 retry=false\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "trailing fields after the quoted label still verify" 0 "model pin verified" --uncommitted
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
export AGY_CONVERSATIONS_DIR="$R/does-not-exist"
check "missing propagation line degrades to a warning" 0 "MODEL PIN UNVERIFIED" --uncommitted
check "missing propagation line fails hard with --require" 3 "MODEL PIN UNVERIFIED" --uncommitted --require
# A review that produced blocking findings is a verdict even when the pin is
# unverifiable: exit 2, never the degraded exit 3 that review-and-push.sh
# answers with a Codex fallback (ADR-0008: no verdict shopping).
printf -- '- [P1] real defect in code.txt\n' > "$AGY_FAKE_DIR/output"
check "blocking findings under an unverifiable pin exit 2, not 3" 2 "verdict, not a degraded lane" --uncommitted --require
assert "no receipt is minted for that verdict" "[ ! -e '$R/.git/review-receipts/antigravity.json' ]"
unset AGY_CONVERSATIONS_DIR
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
export AGY_CONVERSATIONS_DIR="$R/does-not-exist"
check "absent conversation records degrade to a warning" 0 "cannot confirm the recorded model" --uncommitted
unset AGY_CONVERSATIONS_DIR
rm -rf "$R"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
AGY_DB_DIR="$(mktemp -d)"
printf 'gen_metadata: gemini-default flash only\n' > "$AGY_DB_DIR/conv.db"
export AGY_CONVERSATIONS_DIR="$AGY_DB_DIR"
check "DB spot-check miss is a warning, never a block" 0 "DB spot-check is best-effort" --uncommitted
unset AGY_CONVERSATIONS_DIR
rm -rf "$R" "$AGY_DB_DIR"

new_repo
echo "change" >> "$R/code.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
export ANTIGRAVITY_GATE_MODEL=""
check "empty ANTIGRAVITY_GATE_MODEL disables pinning" 0 "LGTB verdict" --uncommitted
unset ANTIGRAVITY_GATE_MODEL
assert "no --model on agy argv when pinning is disabled" "! grep -q -- '--model' '$AGY_FAKE_DIR/argv'"
rm -rf "$R"

# ── #153: unresolvable base fails closed, without invoking agy ────────
new_repo
git -C "$R" checkout -qb feature
echo "committed work" >> "$R/code.txt"
git -C "$R" commit -qam "ahead"
check "unresolvable --base fails closed" 2 "could not be resolved" --base does-not-exist
assert "agy not invoked on unresolvable base" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

# ── #212: proportionality valve ────────────────────────────────────────
new_repo
printf '# Title\n\nDocs only.\n' > "$R/README.md"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "docs-only small diff takes the tier-1 skip" 0 "tier-1 skip" --uncommitted
assert "agy not invoked on a tier-1 skip" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

# ADR-0008 relies on the tier valve sitting BEFORE the agy-presence check: with
# ordinary work routed here, a machine with no agy must still be able to mint a
# tier-1 exemption rather than degrading every docs diff to the Codex lane.
# Asserted by running with agy removed from PATH entirely.
new_repo
printf '# Title\n\nDocs only.\n' > "$R/README.md"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
# A PATH built from every executable the current one offers EXCEPT agy, so the
# case cannot pass by accident on a machine that simply lacks some other tool.
NO_AGY_PATH="$(mktemp -d)"
while IFS= read -r candidate; do
  agy_free_name="${candidate##*/}"
  [ "$agy_free_name" = agy ] && continue
  [ -e "$NO_AGY_PATH/$agy_free_name" ] || ln -s "$candidate" "$NO_AGY_PATH/$agy_free_name" 2>/dev/null
done <<<"$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r agy_free_dir; do
  [ -d "$agy_free_dir" ] || continue
  find "$agy_free_dir" -maxdepth 1 -type f -perm -u+x 2>/dev/null
  find "$agy_free_dir" -maxdepth 1 -type l 2>/dev/null
done)"
SAVED_PATH="$PATH"
PATH="$NO_AGY_PATH"
assert "agy really is absent from the reduced PATH" "! command -v agy >/dev/null 2>&1"
check "tier-1 skip needs no agy on PATH" 0 "tier-1 skip" --uncommitted --require
PATH="$SAVED_PATH"
assert "the agy-free tier-1 run minted its exemption receipt" \
  "[ -e '$R/.git/review-receipts/antigravity.json' ]"
assert "the agy-free tier-1 receipt is a tier-1 exemption" \
  "jq -e '.completion.outcome == \"tier-1\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
rm -rf "$NO_AGY_PATH" "$R"

new_repo
printf '# Title\n' > "$R/README.md"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
export GATE_FORCE_FULL=1
check "GATE_FORCE_FULL=1 forces the full pass on a docs-only diff" 0 "LGTB verdict" --uncommitted
unset GATE_FORCE_FULL
assert "agy invoked under GATE_FORCE_FULL" "[ -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
printf 'notes about rotation\n' > "$R/token-rotation.md"
printf -- '- [P1] Broken thing — token-rotation.md:1\n' > "$AGY_FAKE_DIR/output"
check "risk-surface filename escalates to the full pass (and still blocks)" 2 "BLOCKING findings" --uncommitted
rm -rf "$R"

# ── ADR-0008: supplementary lane on a codex-required diff ─────────────
# The gate must still run, still mint its receipt, and say the receipt cannot
# ship the diff. Silently minting a receipt here is the fail-open ADR-0008 closes.
new_repo
printf 'notes about hosts\n' > "$R/hostnames.txt"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "codex-required diff announces the supplementary lane" 0 "supplementary lane" --uncommitted
assert "supplementary run still dispatches the review" "[ -e '$AGY_FAKE_DIR/invoked' ]"
assert "supplementary run still mints an antigravity receipt" \
  "[ -e '$R/.git/review-receipts/antigravity.json' ]"
assert "the supplementary receipt records the codex requirement" \
  "grep -qF '\"required_lane\":\"codex\"' '$R/.git/review-receipts/antigravity.json'"
# And the receipt is refused for shipping, which is the whole point of saying so.
assert "the supplementary receipt cannot ship the diff" \
  "! python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" --reviewer antigravity >/dev/null 2>&1"
rm -rf "$R"

# An ordinary tier-2 diff is this lane's own work: no supplementary warning.
new_repo
printf 'ordinary change\n' > "$R/widget.ts"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "ordinary tier-2 diff is reviewed as the primary lane" 0 "LGTB verdict" --uncommitted
assert "ordinary diff carries no supplementary warning" \
  "! (cd '$R' && '$GATE' --uncommitted 2>&1 | grep -qF 'supplementary lane')"
rm -rf "$R"

new_repo
printf 'small change\n' > "$R/widget.xyz"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "unclassified file escalates to the full pass" 0 "LGTB verdict" --uncommitted
assert "agy invoked for the unclassified diff" "[ -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

# Rename laundering: `git mv risk.sh notes.md` must NOT classify as docs-only —
# --no-renames lists both sides, and the source path escalates.
new_repo
mkdir -p "$R/claude/hooks"
printf '#!/bin/sh\nexit 0\n' > "$R/claude/hooks/pre-push-guard.sh"
git -C "$R" add claude/hooks/pre-push-guard.sh
git -C "$R" commit -qm "add guard"
git -C "$R" mv claude/hooks/pre-push-guard.sh notes.md
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "renaming a risk surface to .md still takes the full pass" 0 "LGTB verdict" --uncommitted
assert "agy invoked for the rename-laundered diff" "[ -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

echo ""
new_repo
echo change >> "$R/code.txt"
printf '%s\n' '- [P3] nit; [P1] auth bypass — code.txt:1' > "$AGY_FAKE_DIR/output"
awk 'BEGIN { for (i=0; i<2000; i++) printf "- [P3] %0200d — code.txt:1\n", i }' >> "$AGY_FAKE_DIR/output"
check "long output cannot SIGPIPE away an embedded priority" 2 "Stray [P#] token" --uncommitted
rm -rf "$R"

new_repo
echo change >> "$R/code.txt"
printf '%s\n' '- [P3] nit; [P1] authentication bypass — code.txt:1' > "$AGY_FAKE_DIR/output"
check "embedded P1 on a recognized P3 line blocks" 2 "Stray [P#] token" --uncommitted
rm -rf "$R"

new_repo
git -C "$R" checkout -qb feature
echo committed >> "$R/code.txt"
git -C "$R" commit -qam work
echo steer > "$R/GEMINI.md"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "dirty Gemini instructions block committed review" 2 "instruction surface"
assert "dirty Gemini instructions never dispatch" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

new_repo
git -C "$R" checkout -qb feature
echo committed >> "$R/code.txt"
git -C "$R" commit -qam work
printf 'git commit --allow-empty -qm concurrent\n' > "$AGY_FAKE_DIR/mutate"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "Antigravity rejects concurrent HEAD change" 2 "changed during review" --require
rm -rf "$R"

# Own instructions and shared gate code cannot authorize their own review.
for protected in GEMINI.md nested/GEMINI.local.md .gemini/commands/check.md antigravity/policy.lock .antigravity/settings.json claude/scripts/gate-lib.sh claude/scripts/review-receipt.py claude/scripts/review-multipart.py claude/scripts/codex-review-gate.sh claude/scripts/antigravity-review-gate.sh; do
  for scope in committed uncommitted; do
    new_repo
    git -C "$R" checkout -qb feature
    mkdir -p "$R/$(dirname "$protected")"
    printf 'SELF_REVIEW_INSTRUCTION_MARKER\n' > "$R/$protected"
    if [[ "$scope" == committed ]]; then
      git -C "$R" add "$protected"
      git -C "$R" commit -qm 'protected review input'
    fi
    printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
    printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
    check "$scope $protected blocks Antigravity self-review" 2 "Diff touches the Antigravity reviewer's own instruction surface" "--$scope" --require
    assert "protected input never dispatches or issues a receipt" "[ ! -e '$AGY_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/antigravity.json' ]"
    ANTIGRAVITY_GATE_ALLOW_INSTRUCTION_DIFF=1 check "independently reviewed $scope $protected permits explicit override" 0 "Instruction-surface diff allowed" "--$scope" --require
    assert "override still reviews protected input in full" "grep -q 'SELF_REVIEW_INSTRUCTION_MARKER' '$AGY_FAKE_DIR/stdin' && jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
    rm -rf "$R"
  done
done

for protected in GEMINI.md .gemini/commands/check.md .antigravity/policy.lock; do
  new_repo
  mkdir -p "$R/$(dirname "$protected")"
  printf '%s\n' "$protected" > "$R/.git/info/exclude"
  printf 'IGNORED_SELF_REVIEW_MARKER\n' > "$R/$protected"
  check "ignored $protected blocks Antigravity self-review" 2 "Diff touches the Antigravity reviewer's own instruction surface" --uncommitted --require
  assert "ignored own instruction cannot dispatch or receive a receipt" "[ ! -e '$AGY_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/antigravity.json' ]"
  rm -rf "$R"
done

# The reviewer output schema is itself a runtime review input.
original_gate="$GATE"
for scope in committed uncommitted; do
  new_repo
  mkdir -p "$R/claude/scripts"
  for source_file in codex-review-gate.sh antigravity-review-gate.sh gate-lib.sh review-receipt.py review-multipart.py codex-review-schema.json; do
    cp "$SCRIPT_DIR/../$source_file" "$R/claude/scripts/"
  done
  git -C "$R" add claude/scripts
  git -C "$R" commit -qm 'baseline gate and schema'
  git -C "$R" checkout -qb feature
  jq '.properties.verdict.enum = ["approve"] | .properties.findings.maxItems = 0 | .description = "RESTRICTED_REVIEW_SCHEMA_MARKER"' "$SCRIPT_DIR/../codex-review-schema.json" > "$R/claude/scripts/codex-review-schema.json"
  if [[ "$scope" == committed ]]; then
    git -C "$R" commit -qam 'restrict the review schema'
  fi
  GATE="$R/claude/scripts/antigravity-review-gate.sh"
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  check "$scope output schema cannot authorize antigravity review" 2 "instruction surface" "--$scope" --require
  assert "changed schema cannot dispatch or issue antigravity approval" "[ ! -e '$AGY_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/antigravity.json' ]"
  ANTIGRAVITY_GATE_ALLOW_INSTRUCTION_DIFF=1 check "independently reviewed $scope schema permits antigravity override" 0 "Instruction-surface diff allowed" "--$scope" --require
  assert "schema override reviews the restricting input in full" "grep -q 'RESTRICTED_REVIEW_SCHEMA_MARKER' '$AGY_FAKE_DIR/stdin' && jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"

  rm -rf "$R"
done
GATE="$original_gate"

# Gate ancestor symlinks also redirect the installed helper symlink farm.
original_gate="$GATE"
for ancestor in claude claude/scripts .claude .claude/scripts; do
  for route in direct installed; do
    new_repo
    versions="$(mktemp -d "$SHIM_DIR/gate-ancestors.XXXXXX")"
    gate_files=(codex-review-gate.sh antigravity-review-gate.sh gate-lib.sh review-receipt.py review-multipart.py codex-review-schema.json)
    for version in before after; do
      source_scripts="$versions/$version"
      [[ "$ancestor" == */scripts ]] || source_scripts+=/scripts
      mkdir -p "$source_scripts"
      for source_file in "${gate_files[@]}"; do
        cp "$SCRIPT_DIR/../$source_file" "$source_scripts/"
      done
      if [[ "$version" == after ]]; then
        printf '\ntouch "$AGY_FAKE_DIR/helper-evidence"\n' >> "$source_scripts/gate-lib.sh"
      fi
    done
    mkdir -p "$R/$(dirname "$ancestor")"
    ln -s "$versions/before" "$R/$ancestor"
    git -C "$R" add "$ancestor"
    git -C "$R" commit -qm 'baseline gate ancestor'
    git -C "$R" checkout -qb feature
    rm "$R/$ancestor"
    ln -s "$versions/after" "$R/$ancestor"
    git -C "$R" add "$ancestor"
    git -C "$R" commit -qm 'redirect gate ancestor'
    source_scripts="$R/${ancestor%%/*}/scripts"
    if [[ "$route" == installed ]]; then
      installed_scripts="$versions/operator-root/.claude/scripts"
      mkdir -p "$installed_scripts"
      for source_file in "${gate_files[@]}"; do
        ln -s "$source_scripts/$source_file" "$installed_scripts/$source_file"
      done
      GATE="$installed_scripts/antigravity-review-gate.sh"
    else
      GATE="$source_scripts/antigravity-review-gate.sh"
    fi
    printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
    printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
    check "$route $ancestor retarget blocks antigravity self-review" 2 "instruction" --committed --require
    assert "retargeted helper was loaded through $route $ancestor" "[ -e '$AGY_FAKE_DIR/helper-evidence' ]"
    assert "gate ancestor cannot dispatch or issue antigravity approval" "[ ! -e '$AGY_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/antigravity.json' ]"
    ANTIGRAVITY_GATE_ALLOW_INSTRUCTION_DIFF=1 check "$route $ancestor still requires a supported instruction snapshot" 2 "instruction symlink" --committed --require
    assert "unsupported ancestor override cannot issue antigravity approval" "[ ! -e '$AGY_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/antigravity.json' ]"
    rm -rf "$R"
  done
done
GATE="$original_gate"

# Every protected runtime root must also reject a tracked ancestor retarget.
for ancestor in antigravity .antigravity .gemini agents agents/skills; do
  new_repo
  versions="$(mktemp -d "$SHIM_DIR/runtime-ancestors.XXXXXX")"
  case "$ancestor" in
    agents|.agents) runtime_input=skills/review/SKILL.md ;;
    agents/skills|.agents/skills) runtime_input=review/SKILL.md ;;
    codex|.codex) runtime_input=AGENTS.md ;;
    .gemini) runtime_input=config/GEMINI.md ;;
    *) runtime_input=GEMINI.md ;;
  esac
  for version in before after; do
    mkdir -p "$versions/$version/$(dirname "$runtime_input")"
    printf '%s runtime input\n' "$version" > "$versions/$version/$runtime_input"
  done
  mkdir -p "$R/$(dirname "$ancestor")"
  ln -s "$versions/before" "$R/$ancestor"
  git -C "$R" add "$ancestor"
  git -C "$R" commit -qm 'baseline runtime ancestor'
  git -C "$R" checkout -qb feature
  rm "$R/$ancestor"
  ln -s "$versions/after" "$R/$ancestor"
  git -C "$R" add "$ancestor"
  git -C "$R" commit -qm 'redirect runtime ancestor'
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  check "$ancestor retarget blocks antigravity runtime self-review" 2 "instruction" --committed --require
  assert "$ancestor actually redirects the runtime input" "grep -q 'after runtime input' '$R/$ancestor/$runtime_input'"
  assert "runtime ancestor cannot dispatch or issue antigravity approval" "[ ! -e '$AGY_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/antigravity.json' ]"
  rm -rf "$R"
done

# setup.sh installs agents/skills directly into Antigravity's managed skills.
for protected in agents/skills/review/SKILL.md agents/skills/review/references/policy.lock; do
  for scope in committed uncommitted; do
    new_repo
    git -C "$R" checkout -qb feature
    skill_home="$SHIM_DIR/skill-home"
    mkdir -p "$R/$(dirname "$protected")" "$skill_home/.gemini/config/skills"
    printf 'SHARED_SKILL_INSTRUCTION_MARKER\n' > "$R/$protected"
    ln -s "$R/agents/skills/review" "$skill_home/.gemini/config/skills/review"
    assert "managed Antigravity skill exposes the source bundle" "grep -q 'SHARED_SKILL_INSTRUCTION_MARKER' '$skill_home/.gemini/config/skills/review/${protected#agents/skills/review/}'"
    if [[ "$scope" == committed ]]; then
      git -C "$R" add "$protected"
      git -C "$R" commit -qm 'shared skill input'
    fi
    printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
    printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
    HOME="$skill_home" check "$scope $protected blocks Antigravity self-review" 2 "Diff touches the Antigravity reviewer's own instruction surface" "--$scope" --require
    assert "shared skill cannot dispatch or issue Antigravity approval" "[ ! -e '$AGY_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/antigravity.json' ]"
    HOME="$skill_home" ANTIGRAVITY_GATE_ALLOW_INSTRUCTION_DIFF=1 check "independently reviewed $scope $protected permits Antigravity override" 0 "Instruction-surface diff allowed" "--$scope" --require
    assert "override reviews the complete Antigravity skill input" "grep -q 'SHARED_SKILL_INSTRUCTION_MARKER' '$AGY_FAKE_DIR/stdin' && jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
    rm -f "$skill_home/.gemini/config/skills/review"
    rm -rf "$R"
  done
done

for scope in committed uncommitted; do
  new_repo
  git -C "$R" checkout -qb feature
  skill_home="$SHIM_DIR/skill-home"
  mkdir -p "$SHIM_DIR/shared-agent-source/skills/review" "$skill_home/.gemini/config/skills"
  printf 'REDIRECTED_SHARED_SKILL_MARKER\n' > "$SHIM_DIR/shared-agent-source/skills/review/SKILL.md"
  ln -s "$SHIM_DIR/shared-agent-source" "$R/agents"
  ln -s "$R/agents/skills/review" "$skill_home/.gemini/config/skills/review"
  assert "shared root redirects the installed Antigravity skill" "grep -q 'REDIRECTED_SHARED_SKILL_MARKER' '$skill_home/.gemini/config/skills/review/SKILL.md'"
  if [[ "$scope" == committed ]]; then
    git -C "$R" add agents
    git -C "$R" commit -qm 'shared source root replacement'
  fi
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  HOME="$skill_home" check "$scope shared source root blocks Antigravity self-review" 2 "instruction" "--$scope" --require
  assert "shared source root cannot issue Antigravity approval" "[ ! -e '$AGY_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/antigravity.json' ]"
  rm -f "$skill_home/.gemini/config/skills/review"
  rm -rf "$R"
done

# Unchanged canonical instruction links can be reviewed; both identities stay bound.
for mutation in target-worktree target-index target-commit link-worktree link-index link-commit; do
  new_repo
  printf 'Canonical instructions.\n' > "$R/CLAUDE.md"
  ln -s CLAUDE.md "$R/AGENTS.md"
  git -C "$R" add AGENTS.md CLAUDE.md
  git -C "$R" commit -qm 'canonical instructions'
  git -C "$R" checkout -qb feature
  echo committed >> "$R/code.txt"
  git -C "$R" commit -qam work
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  check "canonical link permits antigravity receipt before $mutation" 0 "LGTB verdict" --committed --require
  assert "canonical link antigravity receipt is valid" "python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" --reviewer antigravity >/dev/null 2>&1"
  case "$mutation" in
    target-*)
      printf 'Changed canonical instructions.\n' > "$R/CLAUDE.md"
      if [[ "$mutation" == target-index ]]; then
        git -C "$R" add CLAUDE.md
        printf 'Canonical instructions.\n' > "$R/CLAUDE.md"
      elif [[ "$mutation" == target-commit ]]; then
        git -C "$R" commit -qam 'changed canonical target'
      fi
      ;;
    link-*)
      rm "$R/AGENTS.md"
      ln -s ./CLAUDE.md "$R/AGENTS.md"
      if [[ "$mutation" == link-index ]]; then
        git -C "$R" add AGENTS.md
        rm "$R/AGENTS.md"
        ln -s CLAUDE.md "$R/AGENTS.md"
      elif [[ "$mutation" == link-commit ]]; then
        git -C "$R" commit -qam 'changed canonical link'
      fi
      ;;
  esac
  assert "$mutation stales antigravity shipping evidence" "! python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" --reviewer antigravity >/dev/null 2>&1"
  rm -f "$AGY_FAKE_DIR/invoked"
  check "$mutation blocks a new antigravity review" 2 "instruction symlink" --committed --require
  assert "$mutation prevents antigravity dispatch and approval" "[ ! -e '$AGY_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/antigravity.json' ]"
  rm -rf "$R"
done

for mutation in target link; do
  new_repo
  printf 'Canonical instructions.\n' > "$R/CLAUDE.md"
  ln -s CLAUDE.md "$R/AGENTS.md"
  git -C "$R" add AGENTS.md CLAUDE.md
  git -C "$R" commit -qm 'canonical instructions'
  git -C "$R" checkout -qb feature
  echo committed >> "$R/code.txt"
  git -C "$R" commit -qam work
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  if [[ "$mutation" == target ]]; then
    printf 'printf "Mutated during review.\\n" > CLAUDE.md\n' > "$AGY_FAKE_DIR/mutate"
  else
    printf 'rm AGENTS.md\nln -s ./CLAUDE.md AGENTS.md\n' > "$AGY_FAKE_DIR/mutate"
  fi
  check "concurrent $mutation mutation blocks antigravity receipt" 2 "instruction symlink" --committed --require
  assert "concurrent $mutation mutation leaves no antigravity approval" "[ -e '$AGY_FAKE_DIR/invoked' ] && [ ! -e '$R/.git/review-receipts/antigravity.json' ]"
  rm -rf "$R"
done

# The alternate lane must receive instruction bytes even with passive suffixes.
for active_path in .codex/policy.lock .claude/hooks/check.lock LICENSE.py; do
  for scope in committed uncommitted; do
    new_repo
    git -C "$R" checkout -qb feature
    mkdir -p "$R/$(dirname "$active_path")"
    printf '#!/usr/bin/env python3\nprint("ACTIVE_REVIEW_MARKER")\n' > "$R/$active_path"
    chmod +x "$R/$active_path"
    if [[ "$scope" == committed ]]; then
      git -C "$R" add "$active_path"
      git -C "$R" commit -qm 'active change with exempt filename'
    fi
    printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
    printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
    check "$scope $active_path requires alternate review" 0 "LGTB verdict" "--$scope" --require
    assert "active content reaches alternate reviewer" "grep -q 'ACTIVE_REVIEW_MARKER' '$AGY_FAKE_DIR/stdin'"
    assert "active receipt records actual alternate review" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
    rm -rf "$R"
  done
done

for pathspec_setting in literal conflicting; do
  new_repo
  git -C "$R" checkout -qb feature
  mkdir -p "$R/.codex"
  printf 'PATHSPEC_ALTERNATE_MARKER\n' > "$R/.codex/config.toml"
  git -C "$R" add .codex/config.toml
  git -C "$R" commit -qm 'pathspec environment fixture'
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  if [[ "$pathspec_setting" == literal ]]; then
    export GIT_LITERAL_PATHSPECS=1
  else
    export GIT_GLOB_PATHSPECS=1 GIT_NOGLOB_PATHSPECS=1
  fi
  check "$pathspec_setting environment still dispatches alternate review" 0 "LGTB verdict" --committed --require
  assert "pathspec environment preserves alternate prompt bytes" "grep -q 'PATHSPEC_ALTERNATE_MARKER' '$AGY_FAKE_DIR/stdin'"
  assert "pathspec environment cannot exempt alternate review" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
  unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
  rm -rf "$R"
done

for suffix in ' ' $'\n'; do
  new_repo
  git -C "$R" checkout -qb feature
  echo committed >> "$R/code.txt"
  git -C "$R" commit -qam 'twin repository fixture'
  sibling="$R"
  R="$R$suffix"
  cp -a "$sibling" "$R"
  printf 'TWIN_ALTERNATE_MARKER\n' > "$R/code.txt"
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  check "whitespace twin reviews its own alternate workspace" 0 "LGTB verdict" --uncommitted --require
  assert "whitespace twin bytes reach alternate reviewer" "grep -q 'TWIN_ALTERNATE_MARKER' '$AGY_FAKE_DIR/stdin'"
  assert "whitespace twin cannot create sibling alternate receipt" "[ ! -e '$sibling/.git/review-receipts/antigravity.json' ]"
  printf 'dirty twin instructions\n' > "$R/AGENTS.md"
  rm -f "$AGY_FAKE_DIR/invoked"
  check "whitespace twin blocks alternate committed review" 2 "dirty instruction surface" --committed --require
  assert "whitespace twin dirty instructions prevent alternate dispatch" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
  rm -rf "$R" "$sibling"
done

new_repo
echo source-directory >> "$R/code.txt"
copied_scripts="$SHIM_DIR/scripts"$'\n'
mkdir -p "$copied_scripts"
cp "$SCRIPT_DIR/../antigravity-review-gate.sh" "$SCRIPT_DIR/../gate-lib.sh" "$SCRIPT_DIR/../review-receipt.py" "$copied_scripts/"
original_gate="$GATE"
GATE="$copied_scripts/antigravity-review-gate.sh"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "alternate gate source directory preserves trailing newline" 0 "LGTB verdict" --uncommitted --require
assert "alternate gate from newline directory dispatches" "grep -q 'source-directory' '$AGY_FAKE_DIR/stdin'"
GATE="$original_gate"
rm -rf "$R"

for checkout_state in staged-mode crlf sparse; do
  new_repo
  args=(--committed --require)
  case "$checkout_state" in
    staged-mode)
      printf 'before\n' > "$R/image.png"
      git -C "$R" add image.png
      git -C "$R" commit -qm 'regular file'
      git -C "$R" config core.filemode false
      git -C "$R" update-index --chmod=+x image.png
      printf 'NATIVE_STATE_REVIEW_MARKER\n' > "$R/image.png"
      git -C "$R" add image.png
      args=(--uncommitted --require)
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
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  check "$checkout_state reaches required alternate review" 0 "LGTB verdict" "${args[@]}"
  assert "native checkout state preserves alternate bytes" "grep -q 'NATIVE_STATE_REVIEW_MARKER' '$AGY_FAKE_DIR/stdin'"
  assert "native checkout state gets full alternate receipt" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
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
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  check "$normalization binary instructions block committed alternate review" 2 "dirty instruction surface" --committed --require
  assert "dirty binary instructions cannot dispatch committed alternate review" "[ ! -f '$AGY_FAKE_DIR/invoked' ]"
  check "$normalization binary instructions require full alternate review" 0 "LGTB verdict" --uncommitted --require
  assert "binary instruction CRLF change reaches alternate reviewer" "grep -q 'CRLF_BINARY_INSTRUCTION_MARKER' '$AGY_FAKE_DIR/stdin'"
  assert "binary instruction change cannot receive alternate no-diff evidence" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
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
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  check "$normalization cannot hide a symlink from alternate review" 0 "LGTB verdict" --uncommitted --require
  assert "symlink target bytes reach alternate reviewer" "grep -q 'SYMLINK_TARGET' '$AGY_FAKE_DIR/stdin'"
  assert "symlink change gets a full alternate receipt" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
  rm -rf "$R"
done

for source_instruction in agents/skills/orchestrate/references/runtime-contracts.md agents/canon/fragments/shared.md claude/skills/example/reference.md claude/agents/reviewer.md agents/skills/example/references/policy.lock; do
  new_repo
  git -C "$R" checkout -qb feature
  mkdir -p "$R/$(dirname "$source_instruction")"
  printf 'SOURCE_INSTRUCTION_REVIEW_MARKER\n' > "$R/$source_instruction"
  git -C "$R" add "$source_instruction"
  git -C "$R" commit -qm 'source instruction'
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  if [[ "$source_instruction" == agents/skills/* ]]; then
    check "$source_instruction blocks shared-skill self-review" 2 "instruction surface" --committed --require
    ANTIGRAVITY_GATE_ALLOW_INSTRUCTION_DIFF=1 check "$source_instruction permits independently reviewed override" 0 "LGTB verdict" --committed --require
  else
    check "$source_instruction requires alternate review" 0 "LGTB verdict" --committed --require
  fi
  assert "source instruction reaches alternate reviewer" "grep -q 'SOURCE_INSTRUCTION_REVIEW_MARKER' '$AGY_FAKE_DIR/stdin'"
  # ADR-0008: the review really happened and the receipt is complete, but an
  # instruction surface is codex-required, so this receipt cannot ship the diff.
  assert "source instruction receives reviewed alternate evidence" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
  assert "source instruction records the codex lane requirement" "jq -e '.classification.required_lane == \"codex\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
  assert "alternate evidence alone cannot ship a source instruction" "! python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" >/dev/null 2>&1"
  rm -rf "$R"
done

for instruction in AGENTS.md .codex/config.toml .codex/cache/AGENTS.md; do
  for scope in explicit auto; do
    new_repo
    mkdir -p "$R/$(dirname "$instruction")"
    printf '%s\n' "$instruction" > "$R/.git/info/exclude"
    printf 'IGNORED_INSTRUCTION_MARKER\n' > "$R/$instruction"
    printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
    printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
    args=(--require)
    [[ "$scope" != explicit ]] || args+=(--uncommitted)
    check "ignored $instruction receives $scope alternate review" 0 "LGTB verdict" "${args[@]}"
    assert "ignored instruction bytes reach alternate review" "grep -q 'IGNORED_INSTRUCTION_MARKER' '$AGY_FAKE_DIR/stdin'"
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
  printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
  printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
  if [[ "$instruction" == .gemini/* ]]; then
    ANTIGRAVITY_GATE_ALLOW_INSTRUCTION_DIFF=1 check "independently reviewed $instruction dispatches alternate review" 0 "LGTB verdict" --committed --require
  else
    check "committed $instruction dispatches alternate review" 0 "LGTB verdict" --committed --require
  fi
  assert "agent document reaches alternate reviewer" "grep -q 'AGENT_DOCUMENT_MARKER' '$AGY_FAKE_DIR/stdin'"
  assert "agent document receives a completed alternate receipt" "jq -e '.completion.outcome == \"passed\"' '$R/.git/review-receipts/antigravity.json' >/dev/null"
  # ADR-0008: agent-document diffs are codex-required; the Antigravity receipt
  # is a supplementary second opinion and is refused as shipping evidence.
  assert "alternate evidence alone cannot ship an agent document" "! python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" >/dev/null 2>&1"
  rm -rf "$R"
done

new_repo
echo change >> "$R/code.txt"
for private_path in .codex/auth.json .claude/.credentials.json .gemini/oauth_creds.json agents/skills/example/auth.json claude/skills/example/.credentials.json; do
  mkdir -p "$R/$(dirname "$private_path")"
  printf '%s\n' "$private_path" >> "$R/.git/info/exclude"
  printf '{"access_token":"SYNTHETIC_PRIVATE_CREDENTIAL_MARKER"}\n' > "$R/$private_path"
done
for instruction in .claude/settings.json .agents/example/SKILL.md .codex/cache/AGENTS.md agents/skills/example/cache/policy.md; do
  mkdir -p "$R/$(dirname "$instruction")"
  printf '%s\n' "$instruction" >> "$R/.git/info/exclude"
  printf 'REVIEW_AGENT_CONFIG_MARKER\n' > "$R/$instruction"
done
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "ignored shared skills still block Antigravity self-review" 2 "instruction surface" --uncommitted --require
ANTIGRAVITY_GATE_ALLOW_INSTRUCTION_DIFF=1 check "ignored runtime credentials allow independently reviewed skill input" 0 "LGTB verdict" --uncommitted --require
assert "ignored runtime credentials stay out of Antigravity stdin" "[ -s '$AGY_FAKE_DIR/stdin' ] && ! grep -q 'SYNTHETIC_PRIVATE_CREDENTIAL_MARKER' '$AGY_FAKE_DIR/stdin'"
assert "ignored agent config and skills still reach Antigravity" "grep -q 'REVIEW_AGENT_CONFIG_MARKER' '$AGY_FAKE_DIR/stdin' && grep -q '.claude/settings.json' '$AGY_FAKE_DIR/stdin' && grep -q '.agents/example/SKILL.md' '$AGY_FAKE_DIR/stdin' && grep -q '.codex/cache/AGENTS.md' '$AGY_FAKE_DIR/stdin'"
assert "source bundle cache reaches alternate reviewer" "grep -q 'agents/skills/example/cache/policy.md' '$AGY_FAKE_DIR/stdin'"
rm -rf "$R"

new_repo
git -C "$R" checkout -qb feature
seq 1 250 > "$R/notes.md"
git -C "$R" add notes.md
git -C "$R" commit -qm docs
export GATE_TIER1_MAX_LINES=0500
check "configured docs cap issues alternate receipt" 0 "tier-1 skip" --require
assert "configured docs cap avoids alternate dispatch" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
unset GATE_TIER1_MAX_LINES
assert "shipping accepts captured alternate cap" "python3 '$SCRIPT_DIR/../review-receipt.py' check --repo '$R' --head \"\$(git -C '$R' rev-parse HEAD)\" >/dev/null 2>&1"
export GATE_TIER1_MAX_LINES=2
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
printf '%s\n' "$PROP_OK" > "$AGY_FAKE_DIR/log"
check "same committed docs above custom cap dispatch alternate review" 0 "LGTB verdict" --committed --require
assert "small custom cap invokes Antigravity" "[ -e '$AGY_FAKE_DIR/invoked' ]"
unset GATE_TIER1_MAX_LINES
rm -rf "$R"

# ── #499: a degraded lane is not a verdict; a verdict still retires ────
# The gate captures without touching the Codex lane and claims the artifact only
# once it can reach a verdict. A run that degrades (exit 3) after capture must
# leave a Codex approval of the same commit shippable; a run that reaches a
# verdict and blocks must retire it, exactly as #480 requires.
seed_codex_receipt() {
  local run
  run="$(python3 "$SCRIPT_DIR/../review-receipt.py" begin --repo "$R" --base main \
    --scope committed --reviewer codex)" || return 1
  printf 'codex approval\n' > "$AGY_FAKE_DIR/codex-approval"
  python3 "$SCRIPT_DIR/../review-receipt.py" complete --snapshot "$run/snapshot.json" \
    --outcome passed --output "$AGY_FAKE_DIR/codex-approval" >/dev/null
}
codex_receipt_ships() {
  python3 "$SCRIPT_DIR/../review-receipt.py" check --repo "$R" \
    --head "$(git -C "$R" rev-parse HEAD)" >/dev/null 2>&1
}
new_repo
git -C "$R" checkout -qb feature
echo "committed work" >> "$R/code.txt"
git -C "$R" commit -qam "ahead"
export ANTIGRAVITY_GATE_MODEL=""
seed_codex_receipt
assert "fixture Codex approval ships" "codex_receipt_ships"
ANTIGRAVITY_GATE_MAX_BYTES=10 \
  check "prompt over the byte cap degrades after capture" 3 "treating as a hard failure" --committed --require
assert "a degraded Antigravity run leaves the Codex approval shippable" "codex_receipt_ships"
printf '1\n' > "$AGY_FAKE_DIR/exit"
check "failed agy session degrades after capture" 3 "treating as a hard failure" --committed --require
assert "a failed agy run leaves the Codex approval shippable" "codex_receipt_ships"
rm -f "$AGY_FAKE_DIR/exit"
# A clean run whose model pin cannot be verified records no receipt, so it is
# no verdict either; a blocking one still claims (fail closed).
unset ANTIGRAVITY_GATE_MODEL
rm -f "$AGY_FAKE_DIR/log"
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "a clean run with an unverifiable pin records nothing" 0 "No shipping receipt" --committed
assert "an unattributable clean run leaves the Codex approval shippable" "codex_receipt_ships"
printf '%s\n' '- [P1] real finding — code.txt:1' > "$AGY_FAKE_DIR/output"
check "a blocking run with an unverifiable pin still blocks" 2 "BLOCKING findings" --committed
assert "that blocking run retires the Codex approval" "! codex_receipt_ships"
seed_codex_receipt
export ANTIGRAVITY_GATE_MODEL=""
printf '%s\n' '- [P1] real finding — code.txt:1' > "$AGY_FAKE_DIR/output"
printf '%s\n' '[agy] print timeout after 360s with turn in progress; returning partial output' > "$AGY_FAKE_DIR/stderr"
check "a blocking partial verdict still blocks" 2 "verdict, not a degraded lane" --committed --require
assert "a blocking partial verdict retires the Codex approval" "! codex_receipt_ships && [ ! -e '$R/.git/review-receipts/codex.json' ]"
rm -f "$AGY_FAKE_DIR/stderr"
seed_codex_receipt
check "a blocking verdict blocks" 2 "BLOCKING findings" --committed --require
assert "a blocking verdict retires the Codex approval" "! codex_receipt_ships && [ ! -e '$R/.git/review-receipts/codex.json' ]"
unset ANTIGRAVITY_GATE_MODEL
rm -rf "$R"
# Failed local validation is a blocking verdict too, reached before dispatch.
new_repo
git -C "$R" checkout -qb feature
printf '[package]\nname = "fixture"\n' > "$R/Cargo.toml"
git -C "$R" add Cargo.toml
git -C "$R" commit -qm "cargo fixture"
seed_codex_receipt
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM_DIR/cargo"
chmod +x "$SHIM_DIR/cargo"
check "failed local validation blocks" 2 "cargo check failed" --committed --require
assert "failed local validation retires the Codex approval" "! codex_receipt_ships && [ ! -e '$AGY_FAKE_DIR/invoked' ]"
rm -f "$SHIM_DIR/cargo"
rm -rf "$R"

# A cancellation Bash defers until agy exits must not discard the blocking
# findings agy already wrote: they claim and exit 2. Without any, the signal is
# re-raised as before, and the Codex approval survives.
new_repo
git -C "$R" checkout -qb feature
echo "committed work" >> "$R/code.txt"
git -C "$R" commit -qam "ahead"
export ANTIGRAVITY_GATE_MODEL=""
cat > "$AGY_FAKE_DIR/mutate" <<'EOF'
pid=$PPID
for _ in 1 2 3 4; do
  pid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
  case "$(ps -o args= -p "$pid")" in
    *antigravity-review-gate.sh*) kill -TERM "$pid"; break ;;
  esac
done
EOF
seed_codex_receipt
printf '%s\n' '- [P1] real finding — code.txt:1' > "$AGY_FAKE_DIR/output"
check "a cancellation after blocking agy output is a verdict" 2 "cancelled after it reported blocking findings" --committed --require
assert "that cancellation retires the Codex approval" "! codex_receipt_ships"
seed_codex_receipt
printf 'LGTB\n' > "$AGY_FAKE_DIR/output"
check "a cancellation after clean agy output re-raises the signal" 143 "" --committed --require
assert "that cancellation leaves the Codex approval shippable" "codex_receipt_ships"
rm -f "$AGY_FAKE_DIR/mutate"
unset ANTIGRAVITY_GATE_MODEL
rm -rf "$R"

R="$(mktemp -d)"
check "outside Git keeps advisory warning" 0 "not inside a git work tree"
check "outside Git blocks required review" 3 "treating as a hard failure" --require
rm -rf "$R"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
