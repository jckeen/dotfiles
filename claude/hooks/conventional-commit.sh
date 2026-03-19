#!/usr/bin/env bash
# PreToolUse hook: enforce conventional commit message format.
# Validates that commit messages match: type: description
# Valid types: feat, fix, refactor, chore, docs, test, style
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

# Validate: first line must match type: description
VALID_TYPES="feat|fix|refactor|chore|docs|test|style|auto"
if ! echo "$MSG" | head -1 | grep -qE "^($VALID_TYPES): .+"; then
  deny "Commit message must start with a conventional type: 'feat:', 'fix:', 'refactor:', 'chore:', 'docs:', 'test:', or 'style:'. Got: '$(echo "$MSG" | head -1 | cut -c1-60)'"
fi

exit 0
