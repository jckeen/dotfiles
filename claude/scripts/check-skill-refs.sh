#!/usr/bin/env bash
# check-skill-refs.sh — warn when an instruction surface tells the model to run
# a skill that does not exist or that the live settings switch off.
#
# Scans orchestrate's SKILL.md, claude/CLAUDE.md, claude/MULTI-AGENT.md and the
# "The Workflow" section of CLAUDE-GUIDE.md for `/name` refs and "the `name`
# skill". Each must be a dir under claude/skills/ or a bundled skill / built-in
# command (ALLOW below), and must not be "off" in `skillOverrides` of the live
# ~/.claude/settings.json. A ref whose own sentence (wrapped lines joined) hedges
# with "if available" / "if it is enabled" / "where enabled" is exempt, as is a
# ref that the possessive of another runtime names directly ("Codex's
# `/review`", "Antigravity's `x` skill"); a hedge in a neighbouring clause, or
# a "Codex's" elsewhere in the clause, does not carry over. Those overrides live in the private
# claude-memory repo, so public CI cannot see them: this is a LOCAL guard, run at
# `cc` launch via check-claude.sh, like check-hooks-wired.sh.
#
# Usage:  check-skill-refs.sh [--strict] [--quiet]
#   --strict: exit 1 on any flag; --quiet: suppress the success line
set -euo pipefail
STRICT=0
QUIET=0
for a in "$@"; do
  case "$a" in
    --strict) STRICT=1 ;;
    --quiet)  QUIET=1 ;;  # for callers that run it every launch
  esac
done

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
REPO_ROOT="$(checker_repo_root "${BASH_SOURCE[0]}")"
SETTINGS="$HOME/.claude/settings.json"
# Bundled skills, then built-in commands the surfaces name (not skills at all).
ALLOW=" verify simplify code-review security-review run loop goal schedule effort compact clear model "
BT="$(printf '\140')"  # a literal backtick, kept out of the quoted patterns below

command -v jq >/dev/null 2>&1 || { yellow "jq not found — skipping skill-ref check"; exit 0; }
[ -f "$SETTINGS" ] || { yellow "no $SETTINGS — skipping skill-ref check"; exit 0; }
OFF=" $(jq -r '.skillOverrides // {} | to_entries[] | select(.value=="off") | .key' "$SETTINGS" | tr '\n' ' ') "

# section <file> — the file, or only CLAUDE-GUIDE's "The Workflow" section.
section() {
  case "$1" in
    */CLAUDE-GUIDE.md) awk '/^## /{on=($0=="## The Workflow")} on' "$1" ;;
    *) cat "$1" ;;
  esac
}

# units <text> — one record per sentence: "LINE<TAB>SENTENCE". Lines of one
# paragraph or list item are joined (Markdown wraps them), then split at a
# sentence end (. ; : ! ?) followed by a space or the end. Inside a sentence a
# hedge attaches to one ref (see the walk below), so "Run /changelog. Run
# /simplify if available." flags /changelog, and "(the `review` skill if
# available)" exempts only `review`.
units() {
  awk '
    function flush(   i, n, parts) {
      if (unit == "") return
      n = split(unit, parts, /[.;:!?]( +|$)/)
      for (i = 1; i <= n; i++) if (parts[i] ~ /[^ \t]/) printf "%d\t%s\n", start, parts[i]
      unit = ""
    }
    /^[ \t]*$/ || /^#/ || /^[ \t]*([-*]|[0-9]+\.)[ \t]/ || /^[ \t]*\|/ { flush(); start = NR }
    { gsub(/^[ \t]+/, ""); unit = (unit == "" ? $0 : unit " " $0) }
    END { flush() }
  ' <<<"$1"
}

flags=0
for rel in claude/skills/orchestrate/SKILL.md claude/CLAUDE.md CLAUDE-GUIDE.md claude/MULTI-AGENT.md; do
  f="$REPO_ROOT/$rel"; [ -f "$f" ] || continue
  text="$(section "$f")"
  off=0; [ "$rel" = CLAUDE-GUIDE.md ] && off=$(($(grep -n '^## The Workflow$' "$f" | cut -d: -f1) - 1))
  while IFS=$'\t' read -r n cur || [ -n "$cur" ]; do
    [ -n "$cur" ] || continue
    # A slash ref is not preceded by a word char, '.', '~', ':' or '/' (paths,
    # URLs, "3/5", "changelog.d/") and not followed by '/' or a word char.
    # Every separator byte is doubled so the trailing char one match consumes
    # cannot hide the next ref ("/orchestrate,/nosuch" keeps both). Refs (R),
    # hedges (H) and another runtime's possessive (T) are listed with their
    # byte offsets and walked in order: a hedge covers the ref right before it
    # ("/x (if available)", "/x where enabled") or, with no ref before it in
    # the sentence, the next one ("If available, run /x"); a possessive covers
    # only the ref inside its own match ("Codex's /x"). Each covers one
    # occurrence and a spent hedge does not carry forward, so "(the `review`
    # skill if available)" leaves the `/code-review` before it uncovered,
    # "Codex's /x and then our /x" reports the second /x, and "Codex's /review
    # if available, then /x" reports /x.
    # (Patterns below allow runs of spaces and backticks, since those are doubled too.)
    doubled="$(sed 's#[^A-Za-z0-9_/.~:-]#&&#g' <<<"$cur")"
    names="$( { grep -obE '(^|[^A-Za-z0-9_./~:-])/[a-z][a-z0-9-]*([^A-Za-z0-9_/.-]|\.([^A-Za-z0-9_/-]|$)|$)' <<<"$doubled" \
          | sed -E 's#^([0-9]+):[^/]*/([a-z0-9-]+).*#\1 R \2#'
        grep -obE "${BT}+[a-z][a-z0-9-]+${BT}+ +skill" <<<"$doubled" | sed -E "s#^([0-9]+):${BT}+([^${BT}]+)${BT}.*#\1 R \2#"
        grep -obiE "(if|where) +(it +is +|they +are +)?(available|enabled)" <<<"$doubled" | sed -E 's#^([0-9]+):.*#\1 H -#'
        grep -obiE "(codex|antigravity)'+s +(the +)?${BT}*/?[a-z][a-z0-9-]*" <<<"$doubled" \
          | awk -v bt="$BT" '{ off = $0; sub(/:.*/, "", off); m = $0; sub(/^[0-9]+:/, "", m);
              nm = m; sub(/.*('"'"'s +)(the +)?/, "", nm); gsub(bt, "", nm); sub(/^\//, "", nm);
              print off " T " nm " " off + length(m) }'
        true; } 2>/dev/null \
      | sort -n | awk '
          # Items in text order. A hedge covers the ref right before it; when
          # that ref is already covered the hedge is spent, not carried on.
          # Only a hedge with no ref before it in the sentence waits for the
          # next ref ("If available, run /x"). A possessive covers exactly the
          # ref inside its own match ("Codex'"'"'s /x"), by span and name, so
          # "After Codex'"'"'s review, run /x" covers nothing. Uncovered refs print.
          $2 == "R" { n++; name[n] = $3; cov[n] = 0
                      if (t_end > 0 && $1 < t_end && $3 == t_name) { cov[n] = 1; t_end = 0 }
                      else if (wait > 0) { cov[n] = 1; wait-- }
                      last = n; next }
          $2 == "H" { if (last > 0) { if (!cov[last]) cov[last] = 1 } else wait++; next }
          $2 == "T" { t_name = $3; t_end = $4; next }
          END { for (i = 1; i <= n; i++) if (!cov[i]) print name[i] }
        ' )"
    [ -n "$names" ] || continue
    for sk in $names; do
      why=""
      if [ ! -d "$REPO_ROOT/claude/skills/$sk" ] && [[ "$ALLOW" != *" $sk "* ]]; then why="no such skill"
      elif [[ "$OFF" == *" $sk "* ]]; then why="off in skillOverrides"; fi
      [ -n "$why" ] || continue
      flags=$((flags + 1)); yellow "$rel:$((n + off)): $sk — $why (hedge with \"if available\" or fix the ref)"
    done
  done < <(units "$text")
done
[ "$flags" -eq 0 ] && { [ "$QUIET" -eq 1 ] || green "skill refs OK"; exit 0; }
[ "$STRICT" -eq 1 ] && exit 1 || exit 0
