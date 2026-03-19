#!/bin/bash
# Verify Claude Code config symlinks are healthy.
# Run from anywhere: ~/dev/dotfiles/check-claude.sh
# Checks for: broken links, unlinked files, stale backups, drift.

set -e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SRC="$DOTFILES_DIR/claude"
CLAUDE_DST="$HOME/.claude"
ERRORS=0
WARNINGS=0

red()    { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }

check_link() {
  local src="$1" dst="$2" label="$3"
  if [ -L "$dst" ]; then
    local target
    target="$(readlink "$dst")"
    if [ "$target" != "$src" ]; then
      red "WRONG  $label -> $target (expected $src)"
      ERRORS=$((ERRORS + 1))
    elif [ ! -e "$dst" ]; then
      red "BROKEN $label -> $target (target missing)"
      ERRORS=$((ERRORS + 1))
    fi
  elif [ -f "$dst" ]; then
    yellow "NOT LINKED  $label (exists but is a regular file, not a symlink)"
    WARNINGS=$((WARNINGS + 1))
  else
    yellow "MISSING  $label (not present in ~/.claude/)"
    WARNINGS=$((WARNINGS + 1))
  fi
}

echo "Checking Claude Code config..."
echo ""

# Top-level files
for f in CLAUDE.md AgentPack.md settings.json statusline.sh; do
  [ -f "$CLAUDE_SRC/$f" ] && check_link "$CLAUDE_SRC/$f" "$CLAUDE_DST/$f" "$f"
done

# Hooks
for f in "$CLAUDE_SRC/hooks/"*.sh; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  check_link "$f" "$CLAUDE_DST/hooks/$name" "hooks/$name"
done

# Agents
for f in "$CLAUDE_SRC/agents/"*.md; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  check_link "$f" "$CLAUDE_DST/agents/$name" "agents/$name"
done

# Skills
for skill_dir in "$CLAUDE_SRC/skills/"*/; do
  [ -d "$skill_dir" ] || continue
  skill_name="$(basename "$skill_dir")"
  for skill_file in "$skill_dir"*; do
    [ -f "$skill_file" ] || continue
    fname="$(basename "$skill_file")"
    check_link "$skill_file" "$CLAUDE_DST/skills/$skill_name/$fname" "skills/$skill_name/$fname"
  done
done

# Check for broken symlinks in ~/.claude/
echo ""
echo "Checking for broken symlinks..."
while IFS= read -r broken; do
  red "BROKEN  $broken -> $(readlink "$broken")"
  ERRORS=$((ERRORS + 1))
done < <(find "$CLAUDE_DST" -maxdepth 3 -xtype l 2>/dev/null)

# Check for stale backup files
echo ""
echo "Checking for stale backups..."
while IFS= read -r backup; do
  yellow "STALE   $backup"
  WARNINGS=$((WARNINGS + 1))
done < <(find "$CLAUDE_DST" -maxdepth 3 -name "*.backup" 2>/dev/null)

# Summary
echo ""
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
  green "All good. Claude config is in sync."
else
  [ $ERRORS -gt 0 ] && red "$ERRORS error(s) found."
  [ $WARNINGS -gt 0 ] && yellow "$WARNINGS warning(s) found."
  echo ""
  echo "Run ./setup.sh to fix missing/broken links."
fi
