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
SHIM_DIR="$(mktemp -d)"
cat > "$SHIM_DIR/agy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$AGY_FAKE_DIR/argv"
cat > "$AGY_FAKE_DIR/stdin"
touch "$AGY_FAKE_DIR/invoked"
cat "$AGY_FAKE_DIR/output"
EOF
chmod +x "$SHIM_DIR/agy"
export PATH="$SHIM_DIR:$PATH"
export AGY_FAKE_DIR=""
unset ANTIGRAVITY_GATE_REQUIRED

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

# ── #153: unresolvable base fails closed, without invoking agy ────────
new_repo
git -C "$R" checkout -qb feature
echo "committed work" >> "$R/code.txt"
git -C "$R" commit -qam "ahead"
check "unresolvable --base fails closed" 2 "could not be resolved" --base does-not-exist
assert "agy not invoked on unresolvable base" "[ ! -e '$AGY_FAKE_DIR/invoked' ]"
rm -rf "$R"

echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
