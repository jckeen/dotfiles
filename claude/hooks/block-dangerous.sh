#!/usr/bin/env bash
# PreToolUse hook: block dangerous patterns that should never run autonomously.
# Registered in settings.json for Bash tool calls.
# Uses jq for reliable JSON parsing. Output JSON for proper Claude integration.
set -euo pipefail

INPUT=$(cat)

# Only inspect Bash calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Extract the command from tool_input (the correct nesting)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Helper: output a deny decision in the format Claude Code expects
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

# Block recursive deletion of broad paths (/, ~, $HOME, .., ., *)
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive)\s+(/|~|\$HOME|\.\.|\./?$|\.\s|\*)'; then
  deny "Recursive deletion of broad path. Be more specific about what to delete."
fi

# Block force push to main/master (handles any argument order)
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force' && echo "$COMMAND" | grep -qE '(main|master)'; then
  deny "Force push to main/master. Use a feature branch."
fi

# Block dropping databases or tables
if echo "$COMMAND" | grep -qiE '(DROP\s+(DATABASE|TABLE|SCHEMA))'; then
  deny "DROP DATABASE/TABLE detected. Requires explicit user confirmation."
fi

# Block modifying production environment files
if echo "$COMMAND" | grep -qE '(\.env\.prod|\.env\.production)'; then
  deny "Modifying production environment files. Confirm with the user first."
fi

# Block git reset --hard
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
  deny "git reset --hard can destroy uncommitted work. Use a safer alternative."
fi

# Block git clean -f (deletes untracked files permanently)
if echo "$COMMAND" | grep -qE 'git\s+clean\s+-[a-zA-Z]*f'; then
  deny "git clean -f can permanently delete untracked files."
fi

# Block deleting Windows-side system paths from WSL
if echo "$COMMAND" | grep -qE 'rm\s+.*(/mnt/c/(Windows|Program)|/mnt/c/Users/[^/]+/(AppData|Desktop|Documents))'; then
  deny "Deleting Windows system or user directories from WSL."
fi

exit 0
