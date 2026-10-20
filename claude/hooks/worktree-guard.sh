#!/usr/bin/env bash
# PreToolUse(Bash) worktree guard.
#
# Prevents the "two sessions sharing one checkout" collision: when a parallel
# session has worktrees open, creating or switching a branch in the PRIMARY
# checkout switches the shared working tree out from under the other session
# (this is exactly what happened on 2026-06-18 — a `git checkout -b` in the
# shared tree stranded another session's commits).
#
# Policy (smart / contention-gated):
#   - Only branch CREATE/SWITCH ops are guarded (`checkout -b/-B/--orphan`,
#     any `git switch`). The command is split into segments on `&&`, `||`,
#     `;`, `|`, `&`, newlines, `$(`, backticks and parentheses, and EVERY
#     segment is checked, so `git worktree list && git switch -c x` is still
#     caught (#681).
#   - Fail closed: a segment is guarded when its raw text (quotes kept)
#     matches a broad branch-op pattern, so quoted global options
#     (`git -c 'user.name=A B' switch …`) cannot hide the subcommand, and a
#     quoted mention (`bash -c "git switch x"`, a commit message) counts too.
#     The only exemption is a segment that is plainly `git worktree …` — the
#     fix, not the problem. `git -C dir worktree add -b switch …` is therefore
#     a known false positive, which is safe. After `--`, checkout arguments
#     are pathspecs (`git checkout -- -backup` is allowed). Constructs the
#     splitter does not model (`eval`, heredocs) fall back to a whole-text
#     match.
#   - Allow freely when run from a linked worktree (.../worktrees/<name>).
#   - In the PRIMARY checkout, DENY only when >1 worktree exists (a parallel
#     session is likely active). Solo work (1 worktree) is never blocked.
#
# Environment errors (no jq, not in a repo, git failing) still exit 0 (allow),
# so a broken guard never wedges git outside the contention case.

# No globbing: segments are word-split into tokens below, and a `*` in the
# command must stay a literal token, not expand against the cwd.
set -f

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$CMD" ] && exit 0

# segment_is_branch_op <segment> — true when any `git` invocation in the
# segment runs `switch`, or `checkout` with -b/-B/--orphan. Global options
# before the subcommand (-C <path>, -c <k=v>, --git-dir=…) are skipped.
segment_is_branch_op() {
  local -a toks
  local i n sub j t
  # shellcheck disable=SC2206  # word splitting is the tokenizer here
  toks=($1)
  n=${#toks[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    if [ "$t" = git ] || [ "${t##*/}" = git ]; then
      j=$((i + 1))
      while [ "$j" -lt "$n" ]; do
        case "${toks[$j]}" in
          -C|-c|--git-dir|--work-tree|--namespace) j=$((j + 2)) ;;
          -*) j=$((j + 1)) ;;
          *) break ;;
        esac
      done
      sub="${toks[$j]:-}"
      case "$sub" in
        switch) return 0 ;;
        checkout)
          j=$((j + 1))
          while [ "$j" -lt "$n" ]; do
            case "${toks[$j]}" in
              --) break ;;  # pathspecs follow: `checkout -- -backup` is a file (#695)
              -b|-B|--orphan|-b*|-B*) return 0 ;;
            esac
            j=$((j + 1))
          done
          ;;
      esac
    fi
    i=$((i + 1))
  done
  return 1
}

# Broad branch-op text, matched on a segment's RAW text (quotes kept): a git
# word followed anywhere later by `switch` or `checkout … -b/-B/--orphan`.
# Quoted global options (`git -c 'user.name=A B' switch …`, `-C "dir x"`)
# cannot hide the subcommand from this, unlike a word-split parse.
BROAD_RE='(^|[^[:alnum:]_-])git([[:space:]].*)?[[:space:]](switch([[:space:]]|$)|checkout[[:space:]]+(-[^-[:space:]]*[bB]|--orphan))'

is_branch_op() {
  local cmd="$1" seg
  # Turn every separator character into a newline: this splits `&&`, `||`,
  # `;`, `|`, `&`, `$(…)`, `(…)` and backticks alike. Quotes are kept.
  while IFS= read -r seg; do
    # Exempt only a segment that is plainly `git worktree …` (how you
    # comply). Anything fancier before the subcommand is not exempt, so
    # `git -C x worktree add -b switch …` is a known, safe false positive.
    if printf '%s\n' "$seg" | grep -qE '^[[:space:]]*git[[:space:]]+worktree([[:space:]]|$)'; then
      continue
    fi
    printf '%s\n' "$seg" | grep -qE "$BROAD_RE" && return 0
    # The word-level parse adds forms the regex misses (`checkout main -b x`);
    # it can only add blocks, never exempt.
    segment_is_branch_op "$(printf '%s' "$seg" | tr -d "\"'")" && return 0
  done < <(printf '%s\n' "$cmd" | tr ';|&()`' '\n\n\n\n\n\n')
  # Fail closed on constructs the splitter does not model.
  if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])eval([[:space:]]|$)|<<'; then
    printf '%s' "$cmd" | grep -qE 'git[[:space:]].*(checkout[[:space:]]+-|switch([[:space:]]|$))' && return 0
  fi
  return 1
}

is_branch_op "$CMD" || exit 0

# Linked worktree? Its git dir lives under .../worktrees/<name>. Allow.
gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
case "$gitdir" in */worktrees/*) exit 0 ;; esac

# Primary checkout. Only guard when another worktree exists (contention).
wt=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')
[ "${wt:-1}" -le 1 ] && exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
reason="Worktree guard: you're in the PRIMARY checkout and ${wt} worktrees exist — another session may be active, and creating/switching a branch here can switch it out from under them. Work in an isolated worktree instead:  git worktree add ../$(basename "$root")-<branch> -b <branch>  then cd there. ('git worktree add' is always allowed; branch ops inside any linked worktree are never blocked.)"
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
