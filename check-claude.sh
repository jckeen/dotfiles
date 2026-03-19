#!/bin/bash
# Verify Claude Code config symlinks are healthy.
# Run from anywhere: ~/dev/dotfiles/check-claude.sh
# Checks for: broken links, unlinked files, orphaned links, stale backups.

set +e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SRC="$DOTFILES_DIR/claude"
CLAUDE_DST="$HOME/.claude"
ERRORS=0
WARNINGS=0
FIXED=0

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

# Files kept in dotfiles but NOT symlinked (loaded on-demand)
NOLINK="AgentPack.md"

# Top-level files (auto-discovered from dotfiles, not hardcoded)
for f in "$CLAUDE_SRC/"*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  case " $NOLINK " in *" $name "*) continue ;; esac
  check_link "$f" "$CLAUDE_DST/$name" "$name"
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

# Check for orphaned symlinks — symlinks in ~/.claude/ pointing into dotfiles
# whose source was removed (e.g., AgentPack.md after we stopped linking it)
echo ""
echo "Checking for orphaned symlinks..."
while IFS= read -r link; do
  target="$(readlink "$link")"
  # Only check symlinks that point into our dotfiles repo
  if [[ "$target" == "$DOTFILES_DIR"* ]] && [ ! -e "$link" ]; then
    label="${link#$CLAUDE_DST/}"
    if [ "${1:-}" = "--fix" ]; then
      rm "$link"
      green "CLEANED  $label (removed orphaned link -> $target)"
      FIXED=$((FIXED + 1))
    else
      red "ORPHAN  $label -> $target (source removed from dotfiles)"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done < <(find "$CLAUDE_DST" -maxdepth 3 -type l 2>/dev/null)

# Check for broken symlinks (pointing elsewhere, not into dotfiles)
echo ""
echo "Checking for broken symlinks..."
while IFS= read -r broken; do
  target="$(readlink "$broken")"
  # Skip dotfiles-managed links (already handled above)
  [[ "$target" == "$DOTFILES_DIR"* ]] && continue
  red "BROKEN  $broken -> $target"
  ERRORS=$((ERRORS + 1))
done < <(find "$CLAUDE_DST" -maxdepth 3 -xtype l 2>/dev/null)

# Check for stale backup files created by setup.sh's link_file()
# Only flags .backup files where a working symlink exists for the original
echo ""
echo "Checking for stale backups..."
while IFS= read -r backup; do
  original="${backup%.backup}"
  # Only flag if the non-backup version exists and is a working symlink
  # (meaning setup.sh already replaced it successfully)
  if [ -L "$original" ] && [ -e "$original" ]; then
    if [ "${1:-}" = "--fix" ]; then
      rm "$backup"
      green "CLEANED  $backup"
      FIXED=$((FIXED + 1))
    else
      yellow "STALE   $backup"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
done < <(find "$CLAUDE_DST" -maxdepth 3 -name "*.backup" 2>/dev/null)

# Summary
echo ""
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
  green "All good. Claude config is in sync."
  [ $FIXED -gt 0 ] && green "Cleaned up $FIXED item(s)."
  exit 0
else
  [ $ERRORS -gt 0 ] && red "$ERRORS error(s) found."
  [ $WARNINGS -gt 0 ] && yellow "$WARNINGS warning(s) found."
  echo ""
  echo "Run './check-claude.sh --fix' to auto-clean orphans and backups."
  echo "Run './setup.sh' to recreate missing links."
  exit 1
fi
