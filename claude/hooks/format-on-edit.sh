#!/usr/bin/env bash
# PostToolUse hook: auto-format files after Claude edits them.
# Handles the last 10% of formatting that Claude misses.
# Runs prettier/eslint for JS/TS, black for Python, etc.
# Exit 0 = success (always allow, formatting is best-effort).

set -euo pipefail

INPUT=$(cat)

# Extract tool name
TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

# Only run after file edits
if [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Write" ]; then
  exit 0
fi

# Extract the file path from tool input
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

# Get file extension
EXT="${FILE_PATH##*.}"

# Format based on file type
case "$EXT" in
  js|jsx|ts|tsx|json|css|scss|md|html|yaml|yml)
    # Use prettier if available in the project
    if command -v npx &>/dev/null && [ -f "$(dirname "$FILE_PATH")/node_modules/.bin/prettier" ] 2>/dev/null || [ -f "./node_modules/.bin/prettier" ] 2>/dev/null; then
      npx prettier --write "$FILE_PATH" 2>/dev/null || true
    elif command -v prettier &>/dev/null; then
      prettier --write "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
  py)
    if command -v black &>/dev/null; then
      black --quiet "$FILE_PATH" 2>/dev/null || true
    elif command -v ruff &>/dev/null; then
      ruff format "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
  rs)
    if command -v rustfmt &>/dev/null; then
      rustfmt "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
  go)
    if command -v gofmt &>/dev/null; then
      gofmt -w "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
esac

exit 0
