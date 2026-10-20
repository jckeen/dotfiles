#!/usr/bin/env bash
# hook-guards.test.sh — command parsing in the PreToolUse Bash hooks the public
# settings template enables (#681): conventional-commit.sh, worktree-guard.sh
# and PreMergeCodexHarvest.hook.sh. Each case feeds the REAL hook a tool-call
# JSON and asserts allow (no output) or deny / harvester invocation.
#   - conventional-commit: extraction without `grep -P` (a shim on PATH rejects
#     -P, as macOS grep does), and a message that cannot be extracted fails
#     closed.
#   - worktree-guard: in a primary checkout with a second worktree, every
#     segment of a compound command is checked (`&&`, `;`, `$(…)`, newline);
#     `git worktree add` stays allowed, and a linked worktree is never guarded.
#   - PreMergeCodexHarvest: only a segment that STARTS with the merge command
#     (after VAR=value assignments) runs the harvester; a search for the text
#     does not.
# Run directly; exit 1 on any failure.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOOKS="$REPO_ROOT/claude/hooks"

pass=0
failed=0
ok()   { pass=$((pass + 1));   echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

command -v jq >/dev/null 2>&1 || { echo "hook-guards: jq is required" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# input <command> — the PreToolUse JSON for a Bash call.
input() { jq -nc --arg c "$1" --arg d "${2:-$PWD}" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}'; }
denied() { grep -q '"permissionDecision": *"deny"' <<<"$1"; }

# ── conventional-commit.sh, with a grep that rejects -P ──────────────────
REAL_GREP="$(command -v grep)"
mkdir -p "$T/nogrepP"
cat > "$T/nogrepP/grep" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in --) break ;; -*P*) case "\$a" in --*) ;; *) echo "grep: invalid option -- P" >&2; exit 2 ;; esac ;; esac
done
exec "$REAL_GREP" "\$@"
EOF
chmod +x "$T/nogrepP/grep"
cc() { input "$1" | PATH="$T/nogrepP:$PATH" "$HOOKS/conventional-commit.sh" 2>/dev/null; }

if ! printf 'x\n' | PATH="$T/nogrepP:$PATH" grep -P x >/dev/null 2>&1; then
  ok "test shim: grep -P is rejected, as on macOS"
else
  fail "test shim did not reject grep -P"
fi
denied "$(cc 'git commit -m "bad message"')" \
  && ok "commit-msg: an invalid inline -m message is denied without grep -P" \
  || fail "commit-msg: invalid inline -m message allowed (extraction failed open?)"
[ -z "$(cc 'git commit -m "feat: add thing"')" ] \
  && ok "commit-msg: a valid double-quoted message is allowed" \
  || fail "commit-msg: valid double-quoted message denied"
[ -z "$(cc "git commit -q -m 'fix(hooks): portable'")" ] \
  && ok "commit-msg: a valid single-quoted message with a scope is allowed" \
  || fail "commit-msg: valid single-quoted message denied"
denied "$(cc "git commit -m 'oops no type'")" \
  && ok "commit-msg: an invalid single-quoted message is denied" \
  || fail "commit-msg: invalid single-quoted message allowed"
denied "$(cc 'git commit -m "feat: never closed')" \
  && ok "commit-msg: an unextractable message fails closed" \
  || fail "commit-msg: unextractable message allowed"
heredoc_ok="$(printf '%s\n' 'git commit -m "$(cat <<'"'"'EOF'"'"'' 'docs: heredoc subject' '' 'body' 'EOF' ')"')"
[ -z "$(cc "$heredoc_ok")" ] \
  && ok "commit-msg: a valid heredoc message is allowed" \
  || fail "commit-msg: valid heredoc message denied"
heredoc_bad="$(printf '%s\n' 'git commit -m "$(cat <<'"'"'EOF'"'"'' 'just words' 'EOF' ')"')"
denied "$(cc "$heredoc_bad")" \
  && ok "commit-msg: an invalid heredoc message is denied" \
  || fail "commit-msg: invalid heredoc message allowed"

# ── worktree-guard.sh in a primary checkout with a second worktree ────────
PRIMARY="$T/primary"
git init -q -b main "$PRIMARY"
git -C "$PRIMARY" -c user.name=t -c user.email=t@t.t commit -q --allow-empty -m init
git -C "$PRIMARY" worktree add -q "$T/linked" -b linked-branch
wg() { (cd "${2:-$PRIMARY}" && input "$1" | "$HOOKS/worktree-guard.sh" 2>/dev/null); }

for blocked in \
  'git worktree list && git switch -c x' \
  'echo hi; git checkout -b y' \
  'echo $(git switch z)' \
  "git status
git switch w" \
  'git -C . switch main' \
  'bash -c "git checkout -B v"' \
  'git worktree list || git switch -c u'; do
  denied "$(wg "$blocked")" \
    && ok "worktree-guard blocks: $(tr '\n' ' ' <<<"$blocked")" \
    || fail "worktree-guard let through: $(tr '\n' ' ' <<<"$blocked")"
done
for allowed in 'git worktree add ../p -b q' 'git worktree list' 'git status && git log -1' 'git checkout -- file.txt'; do
  [ -z "$(wg "$allowed")" ] \
    && ok "worktree-guard allows: $allowed" \
    || fail "worktree-guard blocked: $allowed"
done
[ -z "$(wg 'git switch -c feature' "$T/linked")" ] \
  && ok "worktree-guard never blocks inside a linked worktree" \
  || fail "worktree-guard blocked a branch op inside a linked worktree"

# ── PreMergeCodexHarvest.hook.sh: anchored match ─────────────────────────
mkdir -p "$T/hm/.claude/scripts"
cat > "$T/hm/.claude/scripts/harvest-codex-comments.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/harvest-calls"
EOF
chmod +x "$T/hm/.claude/scripts/harvest-codex-comments.sh"
pm() { : > "$T/harvest-calls"; input "$1" "$T" | HOME="$T/hm" "$HOOKS/PreMergeCodexHarvest.hook.sh" >/dev/null 2>&1; cat "$T/harvest-calls"; }

MERGE="gh pr"" merge"
[ -z "$(pm "rg -n '$MERGE' .")" ] \
  && ok "pre-merge: a search for the merge command text does not run the harvester" \
  || fail "pre-merge: harvester ran on a mere mention"
[ -z "$(pm "echo $MERGE 5")" ] \
  && ok "pre-merge: an echo of the merge command does not run the harvester" \
  || fail "pre-merge: harvester ran on an echo"
grep -q -- '--pr 5' <<<"$(pm "$MERGE 5 --squash")" \
  && ok "pre-merge: an executed merge of PR 5 runs the harvester for PR 5" \
  || fail "pre-merge: executed merge did not run the harvester"
grep -q -- '--pr 7' <<<"$(pm "GH_REPO=a/b $MERGE 7")" \
  && ok "pre-merge: env assignments before the merge are allowed" \
  || fail "pre-merge: env-prefixed merge not recognised"
grep -q -- '--pr 9' <<<"$(pm "cd x && $MERGE 9 --auto")" \
  && ok "pre-merge: a merge as a later segment of a compound command is caught" \
  || fail "pre-merge: compound-command merge missed"

echo ""
echo "hook-guards: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
