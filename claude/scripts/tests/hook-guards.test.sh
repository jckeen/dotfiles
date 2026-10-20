#!/usr/bin/env bash
# hook-guards.test.sh — command parsing in the PreToolUse Bash hooks the public
# settings template enables (#681): conventional-commit.sh, worktree-guard.sh
# and PreMergeCodexHarvest.hook.sh. Each case feeds the REAL hook a tool-call
# JSON and asserts allow (no output) or deny / harvester invocation.
#   - conventional-commit: extraction without `grep -P` (a shim on PATH rejects
#     -P, as macOS grep does), and a message that cannot be extracted fails
#     closed.
#     A multi-line quoted message and a blank-leading heredoc are validated on
#     their first (non-blank) line.
#   - worktree-guard: in a primary checkout with a second worktree, every
#     segment of a compound command is checked (`&&`, `;`, `$(…)`, newline),
#     quoted options and quoted separators cannot hide a `switch`, a plain
#     `git worktree …` and a `--` pathspec stay allowed (#695), and a linked
#     worktree is never guarded.
#   - PreMergeCodexHarvest: only a command that STARTS with the merge command
#     (after VAR=value assignments) runs the harvester; a search, an echo or
#     quoted text does not, and compound/construct merges are a documented
#     miss.
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
multi_ok="$(printf '%s\n' 'git commit -m "feat: subject line' '' 'Body paragraph."')"
[ -z "$(cc "$multi_ok")" ] \
  && ok "commit-msg: a valid multi-line quoted -m message is allowed" \
  || fail "commit-msg: valid multi-line quoted -m message denied"
multi_bad="$(printf '%s\n' 'git commit -m "no type here' '' 'feat: not the subject"')"
denied "$(cc "$multi_bad")" \
  && ok "commit-msg: a multi-line message is validated on its first line" \
  || fail "commit-msg: multi-line message with a bad first line allowed"
[ -z "$(cc 'git commit -m "docs: document cat <<EOF syntax"')" ] \
  && ok "commit-msg: literal heredoc text inside an inline message is just text" \
  || fail "commit-msg: inline message mentioning a heredoc denied"
# A long heredoc body: `head -1` under pipefail could SIGPIPE its writer and
# wipe a correctly extracted subject. Run it repeatedly; every run must allow.
long_body="$(seq 1 4000 | sed 's/^/body line /')"
heredoc_long="$(printf '%s\n' 'git commit -m "$(cat <<'"'"'EOF'"'"'' 'feat: long heredoc subject' '' "$long_body" 'EOF' ')"')"
long_denials=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -z "$(cc "$heredoc_long")" ] || long_denials=$((long_denials + 1))
done
[ "$long_denials" -eq 0 ] \
  && ok "commit-msg: a long valid heredoc is never denied (no SIGPIPE race)" \
  || fail "commit-msg: long valid heredoc denied in $long_denials of 10 runs"
heredoc_blank="$(printf '%s\n' 'git commit -m "$(cat <<'"'"'EOF'"'"'' '' 'fix: heredoc subject after a blank line' '' 'body' 'EOF' ')"')"
[ -z "$(cc "$heredoc_blank")" ] \
  && ok "commit-msg: a heredoc message with a leading blank line is allowed" \
  || fail "commit-msg: blank-leading heredoc message denied"
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
  'git worktree list || git switch -c u' \
  "git -c 'user.name=Review User' switch -c feature" \
  'git -C "dir with space" switch -c feature' \
  'git -C "" switch -c feature' \
  "git -c 'user.name=Review (Bot)' switch -c feature" \
  "git -c 'user.name=a;b' switch -c feature" \
  "git -c 'user.name=A (B)' checkout main -b newbranch" \
  "git -c x=y 'switch' -c quoted-sub" \
  'git checkout -q --orphan=newbranch' \
  'git checkout -bfoo' \
  'ls -- x && git switch -c after-dashdash' \
  "echo 'a -- b' && git -c 'n=(q)' switch -c quoted-after-dashdash" \
  "git checkout -- f; git -c 'a (b)' checkout main -b split-after-pathspec" \
  'git -C . worktree add -b switch ../p2'; do
  denied "$(wg "$blocked")" \
    && ok "worktree-guard blocks: $(tr '\n' ' ' <<<"$blocked")" \
    || fail "worktree-guard let through: $(tr '\n' ' ' <<<"$blocked")"
done
# The last blocked case above is the documented safe false positive: only a
# segment that is plainly `git worktree …` is exempt.
for allowed in 'git worktree add ../p -b q' 'git worktree list' 'git status && git log -1' \
  'git checkout -- file.txt' 'git checkout -- -backup' 'git worktree add -b switch ../p3'; do
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
grep -q -- '--pr 9' <<<"$(pm "$MERGE 9 --auto")" \
  && ok "pre-merge: an --auto merge runs the harvester" \
  || fail "pre-merge: --auto merge did not run the harvester"
[ -z "$(pm "NOTE=\"x $MERGE 5\"")" ] \
  && ok "pre-merge: a quoted assignment value holding the merge text does not run the harvester" \
  || fail "pre-merge: quoted assignment value ran the harvester"
[ -z "$(pm "NOTE=<<EOF
$MERGE 5
EOF")" ] \
  && ok "pre-merge: merge text inside a heredoc after an assignment does not run the harvester" \
  || fail "pre-merge: heredoc-held merge text ran the harvester"
[ -z "$(pm "NOTE=;: $MERGE 5")" ] \
  && ok "pre-merge: an assignment value holding a shell operator does not run the harvester" \
  || fail "pre-merge: operator in an assignment value ran the harvester"
grep -q -- '--pr 6' <<<"$(pm "GH_REPO=org/repo-name.x GH_HOST=github.com $MERGE 6")" \
  && ok "pre-merge: plain-word assignments before the merge are still recognised" \
  || fail "pre-merge: plain-word assignment prefix no longer recognised"
# Quoted text can never trigger it: there is no splitting at all.
[ -z "$(pm "printf \"%s\\n\" \"\$HOME; $MERGE 5\"")" ] \
  && ok "pre-merge: merge text inside a quoted printf argument does not run the harvester" \
  || fail "pre-merge: quoted merge text ran the harvester"
# Deliberate trade-off (hook header): a merge in a compound command or inside
# another construct is not recognised — the close-time workflow harvests
# every PR anyway, while a false trigger files a junk issue.
[ -z "$(pm "cd x && $MERGE 9 --auto")" ] \
  && ok "pre-merge: a compound-command merge is left to the close-time harvest (documented)" \
  || fail "pre-merge: compound handling changed; update the hook header and this test"
[ -z "$(pm "out=\$($MERGE 3 --squash)")" ] \
  && ok "pre-merge: a merge inside \$(…) is left to the close-time harvest (documented)" \
  || fail "pre-merge: construct handling changed; update the hook header and this test"

echo ""
echo "hook-guards: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
