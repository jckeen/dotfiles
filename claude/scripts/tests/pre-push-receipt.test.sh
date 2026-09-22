#!/usr/bin/env bash
# pre-push-receipt.test.sh — end-to-end lane enforcement at the push boundary.
#
# githooks/pre-push calls `review-receipt.py check` with NO --reviewer. Before
# ADR-0008 that accepted the first valid receipt of either lane, so an
# Antigravity-only receipt shipped a risk-surface diff — the fail-open this
# suite exists to keep closed. The hook itself needs no lane logic: the receipt
# records what the diff requires and the checker refuses a weaker lane, so this
# asserts the whole path (real hook, real receipts, real `git push`) rather than
# the checker alone.
#
# Builds throwaway repos with a local bare origin under mktemp; nothing here
# reaches the network, spends review quota, or runs a reviewer — receipts are
# minted directly by the helper. Run directly; exit 1 on any failure.
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
RECEIPT="$SCRIPT_DIR/../review-receipt.py"
HOOK="$SCRIPT_DIR/../../../githooks/pre-push"
[[ -f "$HOOK" ]] || HOOK="$SCRIPT_DIR/../../githooks/pre-push"
[[ -f "$HOOK" ]] || { echo "SKIP-FAIL: cannot locate githooks/pre-push" >&2; exit 1; }

pass=0
failed=0
R=""
ORIGIN=""
OUT=""
RC=0
RUN=""

# A throwaway HOME so no real Git or tool config is consulted.
FAKE_HOME="$(mktemp -d)"
export HOME="$FAKE_HOME"
export GIT_CONFIG_GLOBAL="$FAKE_HOME/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
# The gitleaks half of the hook is not under test and must not decide the
# verdict; the receipt half is.
export GITLEAKS_SKIP=1
RESULT="$FAKE_HOME/result.json"
printf '%s\n' '{"verdict":"approve","findings":[]}' > "$RESULT"
trap 'rm -rf -- "$FAKE_HOME" "$R" "$ORIGIN"' EXIT

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (condition: $cond)"
    sed 's/^/      | /' <<<"$OUT"
  fi
}

# new_repo <changed path> — a repo on `feature` with one committed change and a
# bare origin, with the real pre-push hook installed the way setup.sh installs
# it (a symlink, so the hook resolves its own source root through readlink).
new_repo() {
  local path="$1"
  R="$(mktemp -d)"
  ORIGIN="$(mktemp -d)"
  git -C "$ORIGIN" init -q --bare -b main
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
  echo "base line" > "$R/code.txt"
  git -C "$R" add code.txt
  git -C "$R" commit -qm init
  git -C "$R" remote add origin "$ORIGIN"
  git -C "$R" push -q origin main
  git -C "$R" checkout -qb feature
  mkdir -p "$R/$(dirname "$path")"
  printf 'pre-push fixture change\n' > "$R/$path"
  git -C "$R" add -- "$path"
  git -C "$R" commit -qm "fixture change"
  ln -sf "$HOOK" "$R/.git/hooks/pre-push"
}

# begin_review <lane> — open an attempt for <lane> without completing it: the
# state a gate leaves behind when it exits 2 on blocking findings.
begin_review() {
  RUN="$(python3 "$RECEIPT" begin --repo "$R" --base origin/main \
    --scope committed --reviewer "$1")" || return 1
}

# finish_review [outcome] — record <outcome> for the run begin_review opened.
finish_review() {
  python3 "$RECEIPT" complete --snapshot "$RUN/snapshot.json" \
    --outcome "${1:-passed}" --output "$RESULT" >/dev/null || return 1
}

# mint <lane> [outcome] — record a completed receipt for <lane> on HEAD.
mint() {
  begin_review "$1" && finish_review "${2:-passed}"
}

push() {
  OUT="$(git -C "$R" push origin feature 2>&1)"
  # shellcheck disable=SC2034  # RC is read inside the eval'd assert conditions.
  RC=$?
}

cleanup() { rm -rf "$R" "$ORIGIN"; R=""; ORIGIN=""; }

# ── A risk surface cannot ship on an Antigravity-only receipt ─────────
# claude/scripts/* is on the dotfiles risk list, which ADR-0008 does not narrow.
new_repo claude/scripts/tool.sh
assert "the hook is installed as a symlink" "[ -L '$R/.git/hooks/pre-push' ]"
assert "an antigravity receipt is minted for the risk diff" "mint antigravity"
push
assert "antigravity-only evidence is BLOCKED on a risk diff" \
  "[ \"\$RC\" -ne 0 ] && grep -qF 'BLOCKED' <<<\"\$OUT\""
assert "the block names the lane requirement" \
  "grep -qF 'receipt lane below required lane' <<<\"\$OUT\""
assert "nothing reached the origin" \
  "! git -C '$ORIGIN' rev-parse --verify --quiet refs/heads/feature >/dev/null"
# The same commit, same hook, a Codex receipt: the push goes through. Without
# this the case above could be passing for any other reason.
assert "a codex receipt is minted for the same commit" "mint codex"
push
assert "a codex receipt ships the risk diff" "[ \"\$RC\" -eq 0 ]"
assert "the origin now has the branch" \
  "git -C '$ORIGIN' rev-parse --verify --quiet refs/heads/feature >/dev/null"
cleanup

# ── Ordinary tier-2 work ships on the Antigravity lane ────────────────
new_repo widget.ts
assert "an antigravity receipt is minted for the ordinary diff" "mint antigravity"
push
assert "antigravity evidence ships an ordinary diff" "[ \"\$RC\" -eq 0 ]"
cleanup

# ── A tier-1 exemption ships from either lane ─────────────────────────
new_repo notes.md
assert "a tier-1 antigravity receipt is minted" "mint antigravity tier-1"
push
assert "a tier-1 exemption ships from the antigravity lane" "[ \"\$RC\" -eq 0 ]"
cleanup

# ── A blocked review retires the other lane's older approval ──────────
# Both gates exit 2 on blocking findings WITHOUT recording a receipt, so a
# blocked Codex run leaves only the attempt its `begin` opened. The hook calls
# `check` with no --reviewer, so an Antigravity approval that outlived the newer
# review would ship the very diff that review rejected.
new_repo widget.ts
assert "an antigravity receipt is minted before the codex run" "mint antigravity"
assert "a codex review begins without recording a verdict" "begin_review codex"
push
assert "an older competing approval is BLOCKED after a blocked review" \
  "[ \"\$RC\" -ne 0 ] && grep -qF 'BLOCKED' <<<\"\$OUT\""
assert "nothing reached the origin" \
  "! git -C '$ORIGIN' rev-parse --verify --quiet refs/heads/feature >/dev/null"
# This closes a bypass, not the lane: the re-run that approves must still ship.
assert "the codex re-run records its approval" "finish_review passed"
push
assert "the approving re-run ships the commit" "[ \"\$RC\" -eq 0 ]"
cleanup

# ── A receipt whose classification was edited is refused ──────────────
new_repo widget.ts
assert "an antigravity receipt is minted before tampering" "mint antigravity"
python3 - "$R/.git/review-receipts/antigravity.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
record = json.loads(path.read_bytes())
record["classification"]["required_lane"] = "any"
path.write_text(json.dumps(record))
PY
push
assert "an edited classification is BLOCKED" \
  "[ \"\$RC\" -ne 0 ] && grep -qF 'BLOCKED' <<<\"\$OUT\""
assert "the block names the classification mismatch" \
  "grep -qF 'classification does not match' <<<\"\$OUT\""
cleanup

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
