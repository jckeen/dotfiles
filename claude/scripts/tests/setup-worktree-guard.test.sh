#!/usr/bin/env bash
# setup-worktree-guard.test.sh — setup.sh must refuse to publish $HOME links
# from a linked git worktree. Managed links resolve against the checkout that
# runs setup.sh, so a temporary worktree leaves ~/.claude pointing at a path
# that is deleted when the branch lands (two ~/.claude/scripts links dangled
# at /tmp/trnn-gate-*/ this way). Clones the repo into a scratch dir so the
# real worktree list is never touched, copies the working-tree setup.sh into
# both checkouts so an uncommitted change is what gets tested, and asserts:
# refusal + zero $HOME writes from the linked worktree, the documented
# override proceeds, and the main checkout is unaffected.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
failed=0
ok()   { pass=$((pass + 1));   echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
TESTHOME="$ROOT/home"
MAIN="$ROOT/main"
WT="$ROOT/linked"
mkdir -p "$TESTHOME"

git clone -q "$REPO_ROOT" "$MAIN"
git -C "$MAIN" worktree add -q --detach "$WT" HEAD
cp "$REPO_ROOT/setup.sh" "$MAIN/setup.sh"
cp "$REPO_ROOT/setup.sh" "$WT/setup.sh"

snapshot() { (cd "$1" && find . -mindepth 1 | sort); }
before="$(snapshot "$TESTHOME")"

out="$(HOME="$TESTHOME" "$WT/setup.sh" --yes --dry-run 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'refusing to run setup.sh from a linked git worktree' <<< "$out"; then
  ok "linked worktree is refused with a clear error (exit $rc)"
else
  fail "linked worktree was not refused (exit $rc):"
  sed 's/^/      | /' <<< "$out"
fi
if grep -Fq "Run $MAIN/setup.sh instead" <<< "$out"; then
  ok "refusal names the main checkout's setup.sh"
else
  fail "refusal does not point at the main checkout"
fi
if [ "$(snapshot "$TESTHOME")" = "$before" ]; then
  ok "refused run made zero writes under \$HOME"
else
  fail "refused run wrote under \$HOME"
fi

out="$(HOME="$TESTHOME" "$WT/setup.sh" --check 2>&1)"
if ! grep -q 'refusing to run setup.sh' <<< "$out"; then
  ok "--check stays usable from a linked worktree (read-only)"
else
  fail "--check was refused from a linked worktree"
fi

out="$(HOME="$TESTHOME" DOTFILES_ALLOW_LINKED_WORKTREE=1 "$WT/setup.sh" --yes --dry-run 2>&1)"
if ! grep -q 'refusing to run setup.sh' <<< "$out" && grep -q 'Mode: DRY-RUN' <<< "$out"; then
  ok "DOTFILES_ALLOW_LINKED_WORKTREE=1 overrides the guard"
else
  fail "override did not proceed past the guard"
fi

out="$(HOME="$TESTHOME" "$MAIN/setup.sh" --yes --dry-run 2>&1)"
if ! grep -q 'refusing to run setup.sh' <<< "$out" && grep -q 'Mode: DRY-RUN' <<< "$out"; then
  ok "main checkout is not refused"
else
  fail "main checkout was refused:"
  sed 's/^/      | /' <<< "$out" | head -5
fi

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
