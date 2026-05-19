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

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"

# Bail silently if no topic configured
if [[ -z "$NTFY_TOPIC" ]]; then
  exit 0
fi

# M4: Validate NTFY_SERVER against a strict pattern.
# - Must be `https://` (no plaintext HTTP — env-controlled URL is a classic
#   downgrade vector).
# - Hostname charset is the DNS-safe set [a-z0-9.-].
# - Optional :PORT, optional /PATH using a safe charset (no `..`, no `?`, no `#`).
# Anything that doesn't match → silent skip (exit 0). No partial validation,
# no warning to stderr, no fallback to a default — failing closed is the
# correct behavior for a notification hook.
NTFY_SERVER_RE='^https://[a-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9_/-]*)?$'
if ! [[ "$NTFY_SERVER" =~ $NTFY_SERVER_RE ]]; then
  exit 0
fi

# Validate NTFY_TOPIC charset too (env-controlled, ends up in the URL path).
# ntfy.sh's own rules: alphanumeric, underscore, hyphen.
if ! [[ "$NTFY_TOPIC" =~ ^[A-Za-z0-9_-]+$ ]]; then
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

# M4: Sanitize SUMMARY before sending.
# - tr -cd '[:print:]\n' strips control bytes (CR/LF/escapes) that could be
#   interpreted as new HTTP headers when injected into curl args.
# - cut -c -500 caps the body length.
SUMMARY_SAFE=$(printf '%s' "$SUMMARY" | tr -cd '[:print:]\n' | cut -c -500)

# Send push notification (non-blocking, fire-and-forget).
# Body is piped via stdin (`--data-binary @-`) instead of inlined as a curl
# argument. This eliminates CRLF / special-char attacks against curl's
# argument parsing and removes any risk of process-list leakage of the body.
# NTFY_SERVER already includes the scheme (validated above), so we don't
# prepend `https://`.
printf '%s' "$SUMMARY_SAFE" | curl -s -o /dev/null \
  -H "Title: Claude Code" \
  -H "Priority: default" \
  -H "Tags: robot" \
  --data-binary "@-" \
  "${NTFY_SERVER}/${NTFY_TOPIC}" &

exit 0
