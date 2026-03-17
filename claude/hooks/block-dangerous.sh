#!/usr/bin/env bash
# Pre-tool hook: block dangerous patterns that should never run autonomously.
# Registered in settings.json as a PreToolUse hook for Bash.
# Exit 2 = block the tool call. Exit 0 = allow.
# Uses pure bash — no jq dependency.

set -euo pipefail

# Read the tool input JSON from stdin
INPUT=$(cat)

# Extract tool_name using grep/sed (avoid jq dependency)
TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

# Only inspect Bash calls
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Extract the command field
COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

# Block recursive deletion of home, root, or broad paths
if echo "$COMMAND" | grep -qE "rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive)\s+(/|~|\\\$HOME|\.\.)"; then
  echo "BLOCKED: Recursive deletion of broad path. Be more specific about what to delete."
  exit 2
fi

# Block force push to main/master
if echo "$COMMAND" | grep -qE "git\s+push\s+.*--force.*\s+(main|master)"; then
  echo "BLOCKED: Force push to main/master. Use a feature branch or ask the user explicitly."
  exit 2
fi

# Block dropping databases or tables
if echo "$COMMAND" | grep -qiE "(DROP\s+(DATABASE|TABLE|SCHEMA))"; then
  echo "BLOCKED: DROP DATABASE/TABLE detected. This requires explicit user confirmation."
  exit 2
fi

# Block modifying production environment files
if echo "$COMMAND" | grep -qE "(\.env\.prod|\.env\.production)"; then
  echo "BLOCKED: Modifying production environment files. Confirm with the user first."
  exit 2
fi

# Block git reset --hard
if echo "$COMMAND" | grep -qE "git\s+reset\s+--hard"; then
  echo "BLOCKED: git reset --hard can destroy uncommitted work. Use a safer alternative."
  exit 2
fi

# Block git clean -f (can delete untracked files permanently)
if echo "$COMMAND" | grep -qE "git\s+clean\s+-[a-zA-Z]*f"; then
  echo "BLOCKED: git clean -f can permanently delete untracked files."
  exit 2
fi

exit 0
