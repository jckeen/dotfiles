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
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && cat "$CODEX_FAKE_DIR/output" > "$a"
  prev="$a"
done
rc=0
[ -f "$CODEX_FAKE_DIR/rc" ] && rc="$(cat "$CODEX_FAKE_DIR/rc")"
exit "$rc"
EOF
chmod +x "$SHIM_DIR/codex"
export PATH="$SHIM_DIR:$PATH"
export CODEX_FAKE_DIR=""
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
check "nonzero rc + clean approve degrades (not trusted)" 0 "not trusting the result" --uncommitted --no-issues
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

# ── unresolved base: never a false 'nothing to review'; hard with --require ──
new_repo
git -C "$R" checkout -qb feature
echo "committed work" >> "$R/code.txt"
git -C "$R" commit -qam "ahead"
approve_clean
check "unresolved base degrades with a warning" 0 "could not be resolved" --base does-not-exist --no-issues
assert "codex not invoked on unresolved base" "[ ! -e '$CODEX_FAKE_DIR/invoked' ]"
check "unresolved base fails hard with --require" 3 "could not be resolved" --base does-not-exist --no-issues --require
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

echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
