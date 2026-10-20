#!/usr/bin/env bash
# HandoffReminder.hook.sh — surface a recent handoff note at session start.
#
# /handoff (Claude) and the Codex handoff skill both write notes to
# ~/.claude/handoffs/YYYY-MM-DD-<project>-handoff.md, but nothing surfaced
# them — resuming relied on the user remembering the note exists. A
# SessionStart hook's stdout is added to Claude's context, so this closes
# the loop: the session starts already knowing a handoff is available.
#
# TRIGGER: SessionStart (after SymlinkRepair)
# EXIT: 0 always (advisory, never blocks)

set -uo pipefail

HANDOFF_DIR="$HOME/.claude/handoffs"
MAX_AGE_DAYS=7

[ -d "$HANDOFF_DIR" ] || exit 0

project="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
[ -n "$project" ] || exit 0

# One directory only, via a glob: stock macOS find has no GNU -maxdepth, and a
# hidden find error left this silently empty there (issue #700). Per file,
# `find FILE -prune -mtime` is POSIX. Newest by mtime (-nt); on a tie the
# later name wins, as the old date-prefixed lexical sort did.
latest=""
for f in "$HANDOFF_DIR"/*-"${project}"-handoff.md; do
  [ -f "$f" ] || continue
  [ -n "$(find "$f" -prune -mtime -"$MAX_AGE_DAYS" 2>/dev/null)" ] || continue
  if [ -z "$latest" ] || [ ! "$latest" -nt "$f" ]; then
    latest="$f"
  fi
done
[ -n "$latest" ] || exit 0

echo "A recent handoff note exists for this project: ${latest}"
echo "If this session resumes that work, read the note before starting."
exit 0
