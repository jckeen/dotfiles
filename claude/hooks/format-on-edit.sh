#!/usr/bin/env bash
# PostToolUse hook: auto-format files after Claude edits them.
# Handles the last 10% of formatting that Claude misses.
#
# PROJECT-GATED (by design): a formatter runs ONLY when the file's project opts
# in to that tool — a local prettier for the JS/TS/CSS/MD family, or a config /
# manifest marker for black, rustfmt, gofmt. There is deliberately NO global
# fallback: working across many repos with different conventions, a global
# formatter would reformat files (including hand-wrapped Markdown docs) against
# a repo's own style. No marker → no formatting.
# Exit 0 = success (always allow, formatting is best-effort).
set -euo pipefail

INPUT=$(cat)

# Only run after file edits
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Write" ]; then
  exit 0
fi

# Extract the file path from tool_input (correct nesting)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# H4 + DF-4 guards: require non-empty, absolute path, and reject `..` traversal.
# `..` in the path could let a hostile tool_input formatter-attack a file
# outside the workspace (e.g. /etc/passwd via /tmp/work/../../etc/passwd).
if [ -z "$FILE_PATH" ]; then
  exit 0
fi
if [[ "$FILE_PATH" != /* ]]; then
  exit 0
fi
if [[ "$FILE_PATH" == *".."* ]]; then
  exit 0
fi
if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

# Get file extension
EXT="${FILE_PATH##*.}"

# Walk up from the file to the project root, returning the first ancestor that
# contains ANY of the given markers. Bounded: stops at $HOME or after 8 hops —
# an unbounded `dirname` loop on `/mnt/c/...` crosses the WSL→DrvFS boundary on
# every edit and costs hundreds of ms. Echoes the dir, or empty if none found.
find_project_root() {
  local dir; dir="$(dirname "$FILE_PATH")"
  local limit=8 marker
  while [ "$dir" != "/" ] && [ "$dir" != "${HOME:-/}" ] && [ "$limit" -gt 0 ]; do
    for marker in "$@"; do
      [ -e "$dir/$marker" ] && { printf '%s' "$dir"; return 0; }
    done
    dir="$(dirname "$dir")"
    limit=$((limit - 1))
  done
  return 0  # not found → empty
}

# Format based on file type — each branch gates on a project opt-in marker.
case "$EXT" in
  js|jsx|ts|tsx|json|css|scss|md|html|yaml|yml)
    # Only a project-local prettier — never a global one (protects docs and
    # repos that don't use prettier from being reformatted to its defaults).
    root="$(find_project_root node_modules/.bin/prettier)"
    if [ -n "$root" ] && [ -x "$root/node_modules/.bin/prettier" ]; then
      "$root/node_modules/.bin/prettier" --write "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
  py)
    # Only if the project configures black/ruff.
    root="$(find_project_root pyproject.toml setup.cfg .ruff.toml ruff.toml)"
    if [ -n "$root" ]; then
      if command -v black &>/dev/null; then
        black --quiet "$FILE_PATH" 2>/dev/null || true
      elif command -v ruff &>/dev/null; then
        ruff format "$FILE_PATH" 2>/dev/null || true
      fi
    fi
    ;;
  rs)
    # Only inside a Cargo project (rustfmt honors its rustfmt.toml).
    root="$(find_project_root Cargo.toml)"
    if [ -n "$root" ] && command -v rustfmt &>/dev/null; then
      rustfmt "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
  go)
    # Only inside a Go module.
    root="$(find_project_root go.mod)"
    if [ -n "$root" ] && command -v gofmt &>/dev/null; then
      gofmt -w "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
esac

exit 0
