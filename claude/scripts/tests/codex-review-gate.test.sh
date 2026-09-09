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
for private_path in .codex/auth.json .claude/.credentials.json .gemini/oauth_creds.json; do
  mkdir -p "$R/$(dirname "$private_path")"
  printf '%s\n' "$private_path" >> "$R/.git/info/exclude"
  printf '{"access_token":"SYNTHETIC_PRIVATE_CREDENTIAL_MARKER"}\n' > "$R/$private_path"
done
for instruction in .claude/settings.json .agents/example/SKILL.md; do
  mkdir -p "$R/$(dirname "$instruction")"
  printf '%s\n' "$instruction" >> "$R/.git/info/exclude"
  printf 'REVIEW_AGENT_CONFIG_MARKER\n' > "$R/$instruction"
done
approve_clean
check "ignored runtime credentials allow ordinary review" 0 "Codex review passed" --uncommitted --no-issues --require
assert "ignored runtime credentials stay out of Codex stdin" "[ -s '$CODEX_FAKE_DIR/stdin' ] && ! grep -q 'SYNTHETIC_PRIVATE_CREDENTIAL_MARKER' '$CODEX_FAKE_DIR/stdin'"
assert "ignored agent config and skill still reach Codex" "grep -q 'REVIEW_AGENT_CONFIG_MARKER' '$CODEX_FAKE_DIR/stdin' && grep -q '.claude/settings.json' '$CODEX_FAKE_DIR/stdin' && grep -q '.agents/example/SKILL.md' '$CODEX_FAKE_DIR/stdin'"
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
