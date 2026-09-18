#!/usr/bin/env bash
# check-tests-wired.test.sh — fixture tests for check-tests-wired.sh.
# Builds throwaway repos under mktemp, copies the checker in so its
# self-resolved REPO_ROOT (SCRIPT_DIR/../..) lands on the fixture, writes
# workflow + test files, runs the copy, and asserts exit code + an output
# fragment. The last case runs the real checker against this repo, which is
# what proves the guard itself is wired. Mirrors doc-refs.test.sh.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
CHECKER="$SCRIPT_DIR/../check-tests-wired.sh"
LIB="$SCRIPT_DIR/../checker-lib.sh"

pass=0
failed=0
R=""

# new_repo — fresh fixture with the checker copied to claude/scripts/ so it
# resolves REPO_ROOT to the fixture root; both workflows start empty.
new_repo() {
  R="$(mktemp -d)"
  mkdir -p "$R/claude/scripts" "$R/.github/workflows"
  cp "$CHECKER" "$R/claude/scripts/check-tests-wired.sh"
  cp "$LIB" "$R/claude/scripts/checker-lib.sh"
  chmod +x "$R/claude/scripts/check-tests-wired.sh"
  : > "$R/.github/workflows/ci.yml"
  : > "$R/.github/workflows/smoke-install.yml"
}

# w <repo-relative path> <line>...  — write a file, one arg per line.
w() {
  local p="$R/$1"
  shift
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" > "$p"
}

# check <name> <expected-exit> [<required output fragment>]
check() {
  local name="$1" want="$2" frag="${3:-}"
  local out rc
  out="$(cd "$R" && ./claude/scripts/check-tests-wired.sh 2>&1)"
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
  rm -rf "$R"
}

# --- Case 1: GOOD — test file named in a ci.yml run step ---------------------
new_repo
w claude/scripts/tests/a.test.sh '#!/usr/bin/env bash' 'exit 0'
w .github/workflows/ci.yml '      - run: claude/scripts/tests/a.test.sh'
check "wired test passes" 0 "tests-wired: OK"

# --- Case 2: BAD — test file no workflow mentions ----------------------------
new_repo
w claude/scripts/tests/b.test.sh '#!/usr/bin/env bash' 'exit 0'
w .github/workflows/ci.yml '      - run: echo unrelated'
check "unwired test fails naming the file" 1 "claude/scripts/tests/b.test.sh"

# --- Case 3: BAD — mention only inside a YAML comment is not wiring ----------
new_repo
w claude/scripts/tests/c.test.sh '#!/usr/bin/env bash' 'exit 0'
w .github/workflows/ci.yml \
  '      # TODO: run claude/scripts/tests/c.test.sh here' \
  '      - run: echo placeholder  # claude/scripts/tests/c.test.sh'
check "comment-only mention fails" 1 "claude/scripts/tests/c.test.sh"

# --- Case 4: GOOD — reached transitively through a wired test file ----------
new_repo
w codex/tests/test_d.py 'print("ok")'
w claude/scripts/tests/d.test.sh \
  '#!/usr/bin/env bash' \
  'python3 "$REPO_ROOT/codex/tests/test_d.py"'
w .github/workflows/ci.yml '      - run: claude/scripts/tests/d.test.sh'
check "transitive reference passes" 0 "tests-wired: OK"

# --- Case 5: GOOD — smoke-install.yml counts as a workflow too --------------
new_repo
w claude/scripts/tests/e.test.py 'print("ok")'
w .github/workflows/smoke-install.yml '      - run: python3 claude/scripts/tests/e.test.py'
check "smoke-install wiring passes" 0 "tests-wired: OK"

# --- Case 6: OPT_OUT — the native Codex regression is skipped ---------------
new_repo
w codex/tests/test_shared_server_native.py 'print("needs a real codex binary")'
w .github/workflows/ci.yml '      - run: echo unrelated'
check "opt-out passes" 0 "tests-wired: OK"

# --- Case 7: a missing workflow file is an error, not silently empty --------
new_repo
rm "$R/.github/workflows/smoke-install.yml"
w .github/workflows/ci.yml '      - run: echo unrelated'
check "missing workflow fails" 1 "workflow missing"

# --- Case 8: the real repo — proves this guard is itself wired --------------
out="$("$CHECKER" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass=$((pass + 1))
  echo "ok   - real repo passes"
else
  failed=$((failed + 1))
  echo "FAIL - real repo passes (got rc=$rc)"
  echo "$out" | sed 's/^/      | /'
fi

echo "---"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
