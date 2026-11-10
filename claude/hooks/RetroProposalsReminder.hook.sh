#!/usr/bin/env bash
# RetroProposalsReminder.hook.sh — say that unread retro proposals exist.
#
# session-retro in auto mode writes its proposals to ~/.claude/retro-proposals/
# instead of blocking, and only an interactive /session-retro read them back.
# Nothing surfaced them, so they piled up unread (#741). A SessionStart hook's
# stdout is added to Claude's context, so this closes the loop with one line.
#
# A proposal is unread when it is newer than the .last-reviewed marker in the
# same directory, which `/session-retro --review` touches when it finishes.
# With no marker, every proposal is unread.
#
# The output is status only: a count, the newest file's date and the command
# that reads them. It never prints a proposal's text, which is written by an
# unattended run and must be read as a proposal, not as session context.
#
# TRIGGER: SessionStart (after HandoffReminder)
# EXIT: 0 always (advisory, never blocks)
# TEST: claude/scripts/tests/retro-proposals-reminder.test.sh

set -uo pipefail

PROPOSALS_DIR="${RETRO_PROPOSALS_DIR:-$HOME/.claude/retro-proposals}"
MARKER="$PROPOSALS_DIR/.last-reviewed"

[ -d "$PROPOSALS_DIR" ] || exit 0

newer=()
[ -f "$MARKER" ] && newer=(-newer "$MARKER")

# Filenames are date-prefixed (YYYY-MM-DD-<project>.md), so lexical sort puts
# the newest last. Regular files only: a link here is not a proposal.
unread="$(find "$PROPOSALS_DIR" -maxdepth 1 -type f -name '*.md' \
  "${newer[@]}" 2>/dev/null | sort)"
[ -n "$unread" ] || exit 0

count="$(printf '%s\n' "$unread" | wc -l | tr -d ' ')"
newest="$(basename "$(printf '%s\n' "$unread" | tail -1)")"
# Print the date only when the name really starts with one, so a file named by
# anything else cannot put its own text into the session context.
date_part=""
if [[ "$newest" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})- ]]; then
  date_part=" (newest ${BASH_REMATCH[1]})"
fi

noun="proposals"
[ "$count" = 1 ] && noun="proposal"
echo "${count} retro ${noun} unread${date_part}: /session-retro --review"
exit 0
