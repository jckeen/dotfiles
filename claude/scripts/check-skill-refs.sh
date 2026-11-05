#!/usr/bin/env bash
# check-skill-refs.sh — warn when an instruction surface tells the model to run
# a skill that does not exist or that the live settings switch off.
#
# Scans orchestrate's SKILL.md, claude/CLAUDE.md, claude/MULTI-AGENT.md and the
# "The Workflow" section of CLAUDE-GUIDE.md for `/name` refs and "the `name`
# skill". Each must be a dir under claude/skills/ or a bundled skill / built-in
# command (ALLOW below), and must not be "off" in `skillOverrides` of the live
# ~/.claude/settings.json. A ref whose own sentence (wrapped lines joined) hedges
# with "if available" / "if it is enabled" / "where enabled", or names another
# runtime's skill ("Codex's", "Antigravity's"), is exempt; a hedge in a
# neighbouring sentence does not carry over. Those overrides live in the private
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
# sentence end (. ; : ! ?) followed by a space or the end, so a hedge applies
# only to the refs in its own sentence: "Run /changelog. Run /simplify if
# available." hedges /simplify and still flags /changelog.
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
    # Separators are doubled so a consumed trailing char cannot hide the next ref.
    names="$( { sed 's/[ `(]/&&/g' <<<"$cur" \
        | grep -oE '(^|[^A-Za-z0-9_./~:-])/[a-z][a-z0-9-]*([^A-Za-z0-9_/.-]|\.([^A-Za-z0-9_/-]|$)|$)' \
        | sed -E 's#^[^/]*/([a-z0-9-]+).*#\1#'
      grep -oE '`[a-z][a-z0-9-]+` skill' <<<"$cur" | sed -E 's/`([^`]+)`.*/\1/'; } || true)"
    [ -n "$names" ] || continue
    hedged=0
    tr -s ' \t' ' ' <<<"$cur" \
      | grep -qiE "(if|where) (it is |they are )?(available|enabled)|(codex|antigravity)'s" && hedged=1
    for sk in $names; do
      [ "$hedged" -eq 1 ] && continue
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
