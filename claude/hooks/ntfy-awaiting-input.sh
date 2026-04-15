#!/usr/bin/env bash
# ntfy-awaiting-input.sh — Push notification when Claude is waiting for user input
#
# TRIGGER: PreToolUse (matcher: AskUserQuestion)
#
# Sends a push notification via ntfy.sh so the user gets an Android alert
# when Claude asks a question or needs a decision. Uses $NTFY_TOPIC from
# environment (set in settings.json env block).
#
# Also works for permission prompts if Claude uses AskUserQuestion before
# triggering an "ask" rule.
#
# DEPENDENCIES: curl, jq (optional — falls back to generic message)
# CONFIGURATION: NTFY_TOPIC env var (required), NTFY_SERVER env var (optional, defaults to ntfy.sh)

set -euo pipefail

NTFY_SERVER="${NTFY_SERVER:-ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"

# Bail silently if no topic configured
if [[ -z "$NTFY_TOPIC" ]]; then
  exit 0
fi

# Read stdin (hook input JSON)
INPUT="$(cat)"

# Try to extract the question header/text for a meaningful notification
SUMMARY="Claude needs your input"
if command -v jq &>/dev/null; then
  HEADER=$(echo "$INPUT" | jq -r '.tool_input.questions[0].header // empty' 2>/dev/null)
  QUESTION=$(echo "$INPUT" | jq -r '.tool_input.questions[0].question // empty' 2>/dev/null)

  if [[ -n "$HEADER" ]]; then
    SUMMARY="$HEADER"
  elif [[ -n "$QUESTION" ]]; then
    # Truncate to first 80 chars
    SUMMARY="${QUESTION:0:80}"
  fi
fi

# Send push notification (non-blocking, fire-and-forget)
curl -s -o /dev/null \
  -H "Title: Claude Code" \
  -H "Priority: default" \
  -H "Tags: robot" \
  -d "$SUMMARY" \
  "https://${NTFY_SERVER}/${NTFY_TOPIC}" &

exit 0
