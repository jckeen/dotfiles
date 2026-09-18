#!/usr/bin/env bash
# review-and-push.test.sh — fixture tests for review-and-push.sh.
# Builds throwaway git repos under mktemp and drives only the pre-push
# checkpoints, so nothing here runs tests, spends review quota, or pushes:
# every case is expected to be refused before the remote is ever contacted.
# Covers #401 (inherited Git routing must fail closed), #402 (executable-bit
# drift must be detected when core.fileMode=false hides it from git status), and
# ADR-0008 lane routing (which gate a classified diff dispatches, and what the
# degraded-Antigravity fallback does).
# Run directly; exit 1 on any failure. Mirrors antigravity-review-gate.test.sh.
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
SCRIPT="$SCRIPT_DIR/../review-and-push.sh"

pass=0
failed=0
R=""
OUT=""
RC=0

# A throwaway HOME keeps log_file and any Git config lookups off the real one.
FAKE_HOME="$(mktemp -d)"
export HOME="$FAKE_HOME"
export GIT_CONFIG_GLOBAL="$FAKE_HOME/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
# The guard under test rejects GIT_CONFIG_*, so the fixture config has to reach
# Git through a path the guard ignores: unset the overrides for the script's own
# environment and let each repo carry its identity in its local config instead.

# new_repo [<core.fileMode value>] — a one-commit repo on a non-default branch
# name so the branch checkpoints pass and the refusal under test is the one the
# case is about.
new_repo() {
  local filemode="${1:-false}"
  R="$(mktemp -d)"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
  git -C "$R" config core.fileMode "$filemode"
  echo "base line" > "$R/code.txt"
  printf '#!/bin/sh\necho hi\n' > "$R/tool.sh"
  chmod 0755 "$R/tool.sh"
  git -C "$R" add code.txt tool.sh
  # With core.fileMode=false `git add` records 100644 for an executable file,
  # so the baseline repo would start out drifted. update-index is the same
  # workaround this repo documents for landing a new executable script.
  git -C "$R" update-index --chmod=+x tool.sh
  git -C "$R" commit -qm init
  git -C "$R" checkout -qb feature
}

# run [env assignments...] — invoke the script on $R with the caller's extra
# environment. GIT_CONFIG_* is stripped so the guard sees only what a case sets.
run() {
  OUT="$(env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM "$@" \
    "$SCRIPT" "$R" --auto-push </dev/null 2>&1)"
  RC=$?
}

# want_refusal <name> <fragment> — the run must fail and say <fragment>.
want_refusal() {
  local name="$1" frag="$2"
  if [[ "$RC" -ne 0 ]] && grep -qF -- "$frag" <<<"$OUT"; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (want rc!=0 and frag='$frag'; got rc=$RC)"
    sed 's/^/      | /' <<<"$OUT"
  fi
}

# want_absent <name> <fragment> — the run must not say <fragment>.
want_absent() {
  local name="$1" frag="$2"
  if grep -qF -- "$frag" <<<"$OUT"; then
    failed=$((failed + 1))
    echo "FAIL - $name (unexpected frag='$frag'; rc=$RC)"
    sed 's/^/      | /' <<<"$OUT"
  else
    pass=$((pass + 1))
    echo "ok   - $name"
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

ROUTING_MSG="Git environment overrides"
MODE_MSG="Tracked executable bits differ from the index"

# ── #401: inherited Git routing fails closed ──────────────────────────
# Each override can send the cleanliness, branch, and commit checkpoints at a
# different checkout than the one whose tests run and whose HEAD gets pushed.
for var in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE \
  GIT_ATTR_SOURCE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE \
  GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_CONFIG; do
  new_repo
  run "$var=/nonexistent/routed"
  want_refusal "$var is refused" "$ROUTING_MSG"
  want_absent "$var refusal names only the variable" "/nonexistent/routed"
  assert "$var refusal names $var" "grep -qF -- '$var' <<<\"\$OUT\""
  rm -rf "$R"
done

new_repo
run GIT_CONFIG_COUNT=0
want_refusal "GIT_CONFIG_COUNT is refused" "$ROUTING_MSG"
rm -rf "$R"

new_repo
run GIT_CONFIG_PARAMETERS="'core.fileMode=true'"
want_refusal "GIT_CONFIG_PARAMETERS is refused" "$ROUTING_MSG"
rm -rf "$R"

# The real attack from #401: a clean alternate worktree routed over a dirty
# REPO_DIR. Without the guard the cleanliness checkpoint inspects the clean
# alternate and approves pushing REPO_DIR's unreviewed HEAD.
new_repo
CLEAN_ALT="$(mktemp -d)"
git -C "$CLEAN_ALT" init -q -b main
git -C "$CLEAN_ALT" config user.email t@t.test
git -C "$CLEAN_ALT" config user.name test
echo alt > "$CLEAN_ALT/alt.txt"
git -C "$CLEAN_ALT" add alt.txt
git -C "$CLEAN_ALT" commit -qm alt
git -C "$CLEAN_ALT" checkout -qb feature
echo "uncommitted fix" >> "$R/code.txt"
run GIT_DIR="$CLEAN_ALT/.git" GIT_WORK_TREE="$CLEAN_ALT"
want_refusal "clean routed worktree cannot mask a dirty REPO_DIR" "$ROUTING_MSG"
rm -rf "$R" "$CLEAN_ALT"

# Transport, identity, and defensive variables stay usable — the guard is about
# repository routing, not every GIT_ name.
new_repo
run GIT_AUTHOR_NAME=someone GIT_SSH_COMMAND=/bin/true GIT_TERMINAL_PROMPT=0 \
  GIT_NO_REPLACE_OBJECTS=1
want_absent "non-routing GIT_ variables are not refused" "$ROUTING_MSG"
rm -rf "$R"

# ── #402: executable-bit drift that core.fileMode=false hides ─────────
# Baseline: with the bit flipped, git status really is silent, so the refusal
# below cannot be coming from the existing cleanliness checkpoint.
new_repo
chmod 0755 "$R/code.txt"
assert "core.fileMode=false hides the added bit from git status" \
  "[ -z \"\$(git -C '$R' status --porcelain)\" ]"
assert "core.fileMode=false hides the added bit from ls-files -v" \
  "[ \"\$(git -C '$R' ls-files -v -- code.txt)\" = 'H code.txt' ]"
run
want_refusal "added executable bit is refused" "$MODE_MSG"
assert "added-bit refusal names the file" "grep -qF -- 'code.txt' <<<\"\$OUT\""
rm -rf "$R"

new_repo
chmod 0644 "$R/tool.sh"
assert "core.fileMode=false hides the removed bit from git status" \
  "[ -z \"\$(git -C '$R' status --porcelain)\" ]"
run
want_refusal "removed executable bit is refused" "$MODE_MSG"
assert "removed-bit refusal names the file" "grep -qF -- 'tool.sh' <<<\"\$OUT\""
rm -rf "$R"

# A tracked path whose bit matches the index is not drift; the run gets past
# the cleanliness checkpoints and stops at the push destination instead.
new_repo
run
want_absent "matching modes are not reported as drift" "$MODE_MSG"
want_absent "matching modes reach past the cleanliness checkpoint" \
  "uncommitted changes"
assert "matching modes reach the push-destination step" \
  "[ \"\$RC\" -ne 0 ] && grep -qF -- 'remote' <<<\"\$OUT\""
rm -rf "$R"

# Drift below the toplevel is still drift, and a run from a subdirectory must
# see the whole repository rather than just its own subtree.
new_repo
mkdir -p "$R/nested/deeper"
printf '#!/bin/sh\n' > "$R/nested/deeper/inner.sh"
git -C "$R" add nested/deeper/inner.sh
git -C "$R" commit -qm nested
chmod 0755 "$R/nested/deeper/inner.sh"
run
want_refusal "drift in a subdirectory is refused" "$MODE_MSG"
REPO_ROOT="$R"
R="$REPO_ROOT/nested"
run
want_refusal "drift outside the invoked subdirectory is still refused" "$MODE_MSG"
R="$REPO_ROOT"
rm -rf "$R"

# Symlinks and directories carry no meaningful exec bit of their own; a symlink
# pointing at an executable must not be misread as a mode change.
new_repo
ln -s tool.sh "$R/link.sh"
git -C "$R" add link.sh
git -C "$R" commit -qm link
assert "link is tracked as a symlink" \
  "[ \"\$(git -C '$R' ls-files -s -- link.sh | cut -d' ' -f1)\" = '120000' ]"
run
want_absent "a tracked symlink is not reported as drift" "$MODE_MSG"
rm -rf "$R"

# A work tree whose directory name ends in a newline must fail closed rather
# than resolve to its shorter sibling: the sibling here is clean, so a run that
# trimmed the name's own newline would report no drift and sail through.
NEWLINE_BASE="$(mktemp -d)"
mkdir "$NEWLINE_BASE/repo"
git -C "$NEWLINE_BASE/repo" init -q -b main
git -C "$NEWLINE_BASE/repo" config user.email t@t.test
git -C "$NEWLINE_BASE/repo" config user.name test
git -C "$NEWLINE_BASE/repo" config core.fileMode false
echo sibling > "$NEWLINE_BASE/repo/code.txt"
git -C "$NEWLINE_BASE/repo" add code.txt
git -C "$NEWLINE_BASE/repo" commit -qm sibling
R="$NEWLINE_BASE/repo"$'\n'
mkdir "$R"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t.test
git -C "$R" config user.name test
git -C "$R" config core.fileMode false
echo "base line" > "$R/code.txt"
git -C "$R" add code.txt
git -C "$R" commit -qm init
git -C "$R" checkout -qb feature
chmod 0755 "$R/code.txt"
run
want_refusal "a newline in the work tree path fails closed" \
  "Cannot verify tracked file modes"
want_absent "a newline in the work tree path does not reach the push step" \
  "No such remote"
rm -rf "$NEWLINE_BASE"

# With core.fileMode=true Git reports the change itself; the run must still be
# refused, by the existing cleanliness checkpoint.
new_repo true
chmod 0755 "$R/code.txt"
run
want_refusal "core.fileMode=true still refuses a mode change" "uncommitted changes"
rm -rf "$R"

# ── Ordering: routing is rejected before the tree is inspected ────────
# A repo that would fail the mode checkpoint anyway must report the routing
# problem, proving the guard runs before any Git subprocess touches the tree.
new_repo
chmod 0755 "$R/code.txt"
run GIT_WORK_TREE=/nonexistent/routed
want_refusal "routing is reported first" "$ROUTING_MSG"
want_absent "tree inspection is skipped when routing is refused" "$MODE_MSG"
rm -rf "$R"

# ── ADR-0008: lane routing dispatches exactly one gate ────────────────
# These cases need the run to reach step 3, so each fixture carries a real bare
# origin (check_destination runs before the gate). The two gates are replaced by
# recording fakes through a scripts directory whose review-and-push.sh is a
# SYMLINK to the real script: SCRIPT_DIR is derived with dirname, not readlink,
# so the production script resolves its siblings here with no test hook in it.
# Nothing mints a receipt, so every run still stops at the pre-push receipt
# check — what each case asserts is which gate was dispatched, and with what.
LANE_DIR=""
ORIGIN=""
GATE_LOG=""

make_lane_scripts() {
  LANE_DIR="$(mktemp -d)"
  GATE_LOG="$LANE_DIR/gates.log"
  : > "$GATE_LOG"
  ln -s "$SCRIPT" "$LANE_DIR/review-and-push.sh"
  ln -s "$SCRIPT_DIR/../common.sh" "$LANE_DIR/common.sh"
  ln -s "$SCRIPT_DIR/../gate-lib.sh" "$LANE_DIR/gate-lib.sh"
  ln -s "$SCRIPT_DIR/../review-receipt.py" "$LANE_DIR/review-receipt.py"
  # Written without ${var^^} or other bash-4 forms: the suite has to run on the
  # macOS bash 3.2 floor too.
  cat > "$LANE_DIR/antigravity-review-gate.sh" <<EOF
#!/usr/bin/env bash
printf 'antigravity %s\n' "\$*" >> "$GATE_LOG"
exit "\${FAKE_AGY_RC:-0}"
EOF
  cat > "$LANE_DIR/codex-review-gate.sh" <<EOF
#!/usr/bin/env bash
printf 'codex %s\n' "\$*" >> "$GATE_LOG"
exit "\${FAKE_CODEX_RC:-0}"
EOF
  chmod +x "$LANE_DIR/antigravity-review-gate.sh" "$LANE_DIR/codex-review-gate.sh"
}

# new_lane_repo <changed path> — a repo on `feature` with a pushable bare origin
# and one committed change at <changed path>, which is what the lane classifier
# reads.
new_lane_repo() {
  local path="$1"
  make_lane_scripts
  R="$(mktemp -d)"
  ORIGIN="$(mktemp -d)"
  git -C "$ORIGIN" init -q --bare -b main
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
  git -C "$R" config core.fileMode true
  echo "base line" > "$R/code.txt"
  git -C "$R" add code.txt
  git -C "$R" commit -qm init
  git -C "$R" remote add origin "$ORIGIN"
  git -C "$R" push -q origin main
  git -C "$R" checkout -qb feature
  mkdir -p "$R/$(dirname "$path")"
  printf 'lane fixture change\n' > "$R/$path"
  git -C "$R" add -- "$path"
  git -C "$R" commit -qm "lane fixture"
}

clean_lane_repo() {
  rm -rf "$R" "$ORIGIN" "$LANE_DIR"
}

# run_lane [env assignments...] — invoke the symlinked script on $R.
run_lane() {
  OUT="$(env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM "$@" \
    "$LANE_DIR/review-and-push.sh" "$R" --auto-push </dev/null 2>&1)"
  RC=$?
}

# want_gates <name> <expected gate log> — the dispatched gates, in order.
want_gates() {
  local name="$1" want="$2" got
  got="$(cat "$GATE_LOG")"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name"
    echo "      | want: ${want:-<none>}"
    echo "      | got:  ${got:-<none>}"
    sed 's/^/      | /' <<<"$OUT"
  fi
}

AGY_GATE="antigravity --require --committed"
CODEX_GATE="codex --require --committed"

# A baseline check that the fixture really reaches step 3, so every "only gate X
# ran" assertion below is evidence about routing rather than about an early exit.
new_lane_repo widget.ts
run_lane
want_gates "an ordinary tier-2 diff dispatches only the Antigravity gate" "$AGY_GATE"
assert "the ordinary run names the antigravity lane" \
  "grep -qF -- 'Review lane: antigravity (required: antigravity)' <<<\"\$OUT\""
want_refusal "no receipt means the push is still refused" "no valid committed review receipt"
clean_lane_repo

# A risk surface keeps the Codex gate. claude/scripts/* is on the dotfiles risk
# list, which ADR-0008 deliberately does not narrow.
new_lane_repo claude/scripts/tool.sh
run_lane
want_gates "a risk-surface diff dispatches only the Codex gate" "$CODEX_GATE"
assert "the risk run names the codex lane" \
  "grep -qF -- 'Review lane: codex (required: codex)' <<<\"\$OUT\""
clean_lane_repo

# Tier 1 needs no reviewer at all; the exemption receipt still has to come from
# somewhere, so the cheapest gate runs and its tier valve mints it.
new_lane_repo notes.md
run_lane
want_gates "a tier-1 diff dispatches the cheapest gate only" "$AGY_GATE"
assert "the tier-1 run says no reviewer dispatch is required" \
  "grep -qF -- 'Review lane: none required (tier-1 diff)' <<<\"\$OUT\""
clean_lane_repo

# ── Degraded Antigravity (exit 3) falls back; a verdict (exit 2) does not ──
new_lane_repo widget.ts
run_lane FAKE_AGY_RC=3
want_gates "a degraded Antigravity gate falls back to Codex" "$AGY_GATE
$CODEX_GATE"
assert "the fallback is announced" \
  "grep -qF -- 'falling back to the Codex lane' <<<\"\$OUT\""
clean_lane_repo

new_lane_repo widget.ts
run_lane FAKE_AGY_RC=3 REVIEW_LANE_FALLBACK=block
want_gates "REVIEW_LANE_FALLBACK=block refuses instead of falling back" "$AGY_GATE"
want_refusal "the block refusal names the setting" "REVIEW_LANE_FALLBACK=block"
clean_lane_repo

new_lane_repo widget.ts
run_lane FAKE_AGY_RC=2
want_gates "blocking findings (exit 2) never fall back to Codex" "$AGY_GATE"
assert "an exit-2 verdict propagates" "[ \"\$RC\" -eq 2 ]"
assert "an exit-2 verdict is not announced as a fallback" \
  "! grep -qF -- 'falling back' <<<\"\$OUT\""
clean_lane_repo

# A Codex-lane failure has no fallback of its own — there is no stronger lane.
new_lane_repo claude/scripts/tool.sh
run_lane FAKE_CODEX_RC=3
want_gates "a degraded Codex gate does not fall back to Antigravity" "$CODEX_GATE"
assert "a degraded Codex gate propagates its exit status" "[ \"\$RC\" -eq 3 ]"
clean_lane_repo

# ── REVIEW_LANE overrides: escalation allowed, downgrade refused ──────
new_lane_repo widget.ts
run_lane REVIEW_LANE=codex
want_gates "REVIEW_LANE=codex escalates an ordinary diff" "$CODEX_GATE"
clean_lane_repo

new_lane_repo claude/scripts/tool.sh
run_lane REVIEW_LANE=antigravity
want_gates "REVIEW_LANE=antigravity dispatches no gate on a risk diff" ""
want_refusal "the downgrade refusal names the required lane" "requires the Codex lane"
clean_lane_repo

new_lane_repo widget.ts
run_lane REVIEW_LANE=nonsense
want_gates "an unknown REVIEW_LANE dispatches no gate" ""
want_refusal "an unknown REVIEW_LANE is refused" "REVIEW_LANE must be auto, codex, or antigravity"
clean_lane_repo

# Regression: the wrapper's own bookkeeping variables must not be re-exported
# into the gate's environment. A bare `GATE_RC` in the wrapper silently
# overwrote a caller-exported GATE_RC (bash keeps an imported name exported), so
# a gate that was told to fail exited 0 and the guard passed for the wrong
# reason. This fake reads GATE_RC the way the shipping fixtures' gate does.
new_lane_repo widget.ts
cat > "$LANE_DIR/antigravity-review-gate.sh" <<EOF
#!/usr/bin/env bash
printf 'antigravity %s\n' "\$*" >> "$GATE_LOG"
exit "\${GATE_RC:-0}"
EOF
chmod +x "$LANE_DIR/antigravity-review-gate.sh"
run_lane GATE_RC=2
want_gates "a caller-exported GATE_RC still reaches the gate" "$AGY_GATE"
assert "the gate's GATE_RC exit status is propagated" "[ \"\$RC\" -eq 2 ]"
clean_lane_repo

new_lane_repo widget.ts
run_lane REVIEW_LANE_FALLBACK=nonsense
want_gates "an unknown REVIEW_LANE_FALLBACK dispatches no gate" ""
want_refusal "an unknown REVIEW_LANE_FALLBACK is refused" "REVIEW_LANE_FALLBACK must be codex or block"
clean_lane_repo


rm -rf "$FAKE_HOME"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
