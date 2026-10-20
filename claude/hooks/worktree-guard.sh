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
#     are pathspecs (`git checkout -- -backup` is allowed).
#   - Whole-command fallback: the splitter is not quote-aware, so the entire
#     command is also checked, and any of these blocks it: the original
#     whole-text matcher, the broad pattern on the raw text, or a word-based,
#     order-free check with quotes removed (a `git` word plus `switch`, or a
#     -b/-B-prefixed flag or --orphan[=…] after any `checkout` word and
#     before that checkout's own `--`). It is allowed only when it is a single
#     plain `git worktree …` with no separators. A splitter mistake (a `(` or
#     `;` inside quotes) can only add blocks.
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
              -b|-B|--orphan|--orphan=*|-b*|-B*|-[!-]*[bB]*) return 0 ;;
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
  local cmd="$1" seg seg_n
  # Turn every separator character into a newline: this splits `&&`, `||`,
  # `;`, `|`, `&`, `$(…)`, `(…)` and backticks alike. Quotes are kept.
  while IFS= read -r seg; do
    # A segment with neither word cannot be a branch op on its own (the
    # whole-command fallback below still sees it); skip it without forking.
    # Matched on a normalized copy (quotes and backslashes removed, no fork),
    # so `sw''itch` or `sw\itch` cannot hide the word.
    seg_n="${seg//\'/}"; seg_n="${seg_n//\"/}"; seg_n="${seg_n//\\/}"
    case "$seg_n" in *switch*|*checkout*) ;; *) continue ;; esac
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
  # Whole-command fail-closed fallback: the splitter above does not know
  # about quotes, so a separator inside a quoted argument
  # (`git -c 'user.name=A (B)' checkout main -b x`) can cut `git` from its
  # subcommand. So look at the entire command, quotes removed and newlines
  # folded, word by word and order-free: a `git` word plus a `switch` word,
  # or plus a `checkout` word and any -b/-B-style flag or --orphan[=…].
  # Only a single, plain `git worktree …` command (no separators at all) is
  # exempt. A splitter mistake can therefore only add blocks; the cost is
  # false positives (a commit message saying "switch") in a contended
  # primary checkout, which is the safe direction.
  local flat raw w='(^|[^[:alnum:]_-])' e='([^[:alnum:]_-]|$)' hit=0
  raw="$(printf '%s' "$cmd" | tr '\n' ' ')"
  flat="$(printf '%s' "$raw" | tr -d "\"'")"
  # (a) main's original whole-text matcher and the per-segment broad pattern,
  # on the raw text: the new checks below may only ADD blocks to these.
  if printf '%s' "$raw" | grep -qE 'git[[:space:]].*(checkout[[:space:]]+-[bB]|switch[[:space:]])' \
    || printf '%s' "$raw" | grep -qE "$BROAD_RE"; then
    hit=1
  fi
  # (b) word-based, order-free: a `git` word plus a `switch` word, or plus a
  # branch flag that follows ANY `checkout` word before that checkout's own
  # `--` (a `--` elsewhere never hides a later flag). Flags are a prefix
  # match, so clusters such as -bfoo or -qb count.
  if [ "$hit" -eq 0 ] && printf '%s' "$flat" | grep -qE "${w}git${e}"; then
    if printf '%s' "$flat" | grep -qE "${w}switch${e}"; then
      hit=1
    elif printf '%s\n' "$flat" | awk '{
        for (i = 1; i <= NF; i++) {
          if ($i == "checkout") co = 1
          else if ($i == "--") co = 0
          else if (co && $i ~ /^(-[A-Za-z]*[bB]|--orphan)/) { found = 1; exit }
        }
      } END { exit found ? 0 : 1 }'; then
      hit=1
    fi
  fi
  if [ "$hit" -eq 1 ]; then
    if printf '%s' "$cmd" | grep -qE '^[[:space:]]*git[[:space:]]+worktree([[:space:]]|$)' \
      && ! printf '%s' "$cmd" | grep -q '[;|&()`$]' \
      && [ "$(printf '%s\n' "$cmd" | wc -l | tr -d ' ')" -le 1 ]; then
      return 1
    fi
    return 0
  fi
  return 1
}

# Cheap exits first, so a huge command (a long heredoc body) costs one grep,
# not a parse per line.
# 1. Every pattern this guard blocks contains the word `switch` or
#    `checkout` once quotes and backslashes are removed (asserted in
#    hook-guards.test.sh), so a command whose NORMALIZED text has neither can
#    never be a block. Normalizing first means quote-splitting or escaping
#    (`git sw''itch`, `git sw\itch`) cannot hide the word from this exit.
STRIPPED="$(printf '%s' "$CMD" | tr -d "\"'\\\\" | tr '\n' ' ')"
grep -qE 'switch|checkout' <<<"$STRIPPED" || exit 0

# 2. Linked worktree? Its git dir lives under .../worktrees/<name>. Allow.
gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
case "$gitdir" in */worktrees/*) exit 0 ;; esac

# 3. Primary checkout. Only guard when another worktree exists (contention).
wt=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')
[ "${wt:-1}" -le 1 ] && exit 0

# The real checks run on the raw text AND the normalized text, OR'd: the raw
# pass keeps segment boundaries and quoted options intact, the normalized
# pass sees through quote-splitting and backslashes. Neither can remove a
# block the other finds.
is_branch_op "$CMD" || is_branch_op "$STRIPPED" || exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
reason="Worktree guard: you're in the PRIMARY checkout and ${wt} worktrees exist — another session may be active, and creating/switching a branch here can switch it out from under them. Work in an isolated worktree instead:  git worktree add ../$(basename "$root")-<branch> -b <branch>  then cd there. ('git worktree add' is always allowed; branch ops inside any linked worktree are never blocked.)"
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
