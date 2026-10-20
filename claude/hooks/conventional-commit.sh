#!/usr/bin/env bash
# PreToolUse hook: enforce conventional commit message format.
# Validates that commit messages match: type(scope)?!?: description
# Types kept in sync with claude/scripts/check-commit-format.sh (the CI backstop).
set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
  exit 0
fi

deny() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Only inspect git commit commands (not amend, merge, rebase)
if ! echo "$COMMAND" | grep -qE 'git\s+commit\s'; then
  exit 0
fi

# Skip if --amend (amending existing message)
if echo "$COMMAND" | grep -qE '\-\-amend'; then
  exit 0
fi

# Skip if no -m flag (interactive editor — user controls the message)
if ! echo "$COMMAND" | grep -qE '\s-m\s'; then
  exit 0
fi

# Extract the commit message — handle both heredoc (cat <<) and inline -m "..."
if echo "$COMMAND" | grep -q 'cat <<'; then
  # Heredoc style: git commit -m "$(cat <<'EOF' ... EOF )"
  # Extract content between the heredoc markers
  MSG=$(echo "$COMMAND" | sed -n "/cat <<.*EOF/,/EOF/p" | grep -v 'cat <<' | grep -v '^[[:space:]]*EOF' | head -1 | sed 's/^[[:space:]]*//')
else
  # Inline style: git commit -m "message"
  MSG=$(echo "$COMMAND" | grep -oP '(?<=-m\s)["\x27]?\K[^"\x27]*' | head -1 || true)
fi

if [ -z "$MSG" ]; then
  exit 0
fi

# Heredoc-constructed commit bodies frequently open with a blank line before the
# actual subject (e.g. when the heredoc is built by appending sections). Skip
# leading blank/whitespace-only lines
# so the conventional-commit regex check applies to the FIRST NON-BLANK line —
# which is the real subject — instead of erroring on a leading blank.
FIRST_LINE=$(printf '%s\n' "$MSG" | grep -v -m1 '^[[:space:]]*$' || true)

# Validate: first non-blank line must match  type(scope)?!?: description
# Type list and subject regex are kept identical to the CI backstop
# claude/scripts/check-commit-format.sh so a message can't pass one gate and
# fail the other. Update both together.
VALID_TYPES="feat|fix|refactor|chore|docs|test|style|perf|build|ci|revert"
SUBJECT_RE="^(${VALID_TYPES})(\([a-z0-9._/-]+\))?!?: .+"
if ! printf '%s' "$FIRST_LINE" | grep -qE "$SUBJECT_RE"; then
  deny "Commit message must start with a conventional type: ${VALID_TYPES//|/, } (optionally with (scope) and/or ! before the colon). Got: '$(printf '%s' "$FIRST_LINE" | cut -c1-60)'"
fi

exit 0
