#!/usr/bin/env bash
# Syncs Claude config from dotfiles repo to ~/.claude/
# Source: ~/dev/dotfiles/claude/ → ~/.claude/
# Run after editing dotfiles, or add to a cron/hook.

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)/claude"
CLAUDE_DIR="$HOME/.claude"

# Sync skills — copy files (symlinks don't work with Claude Code's skill scanner)
SKILLS_SRC="$DOTFILES_DIR/skills"
SKILLS_DST="$CLAUDE_DIR/skills"
mkdir -p "$SKILLS_DST"

if [ -d "$SKILLS_SRC" ]; then
    for f in "$SKILLS_SRC"/*.md; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        # Only copy if source is newer or destination doesn't exist
        if [ ! -f "$SKILLS_DST/$name" ] || [ "$f" -nt "$SKILLS_DST/$name" ]; then
            # Remove symlink if present, then copy
            rm -f "$SKILLS_DST/$name"
            cp "$f" "$SKILLS_DST/$name"
            echo "  updated skill: $name"
        fi
    done
    # Remove skills that no longer exist in dotfiles
    for f in "$SKILLS_DST"/*.md; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        [[ "$name" == *.backup ]] && continue
        if [ ! -f "$SKILLS_SRC/$name" ]; then
            rm "$f"
            echo "  removed skill: $name"
        fi
    done
fi

# Sync top-level config files
for f in CLAUDE.md AgentPackJCK.md settings.json; do
    if [ -f "$DOTFILES_DIR/$f" ]; then
        if [ ! -f "$CLAUDE_DIR/$f" ] || ! diff -q "$DOTFILES_DIR/$f" "$CLAUDE_DIR/$f" > /dev/null 2>&1; then
            cp "$DOTFILES_DIR/$f" "$CLAUDE_DIR/$f"
            echo "  updated: $f"
        fi
    fi
done

# Sync hooks directory
if [ -d "$DOTFILES_DIR/hooks" ]; then
    mkdir -p "$CLAUDE_DIR/hooks"
    rsync -a --delete "$DOTFILES_DIR/hooks/" "$CLAUDE_DIR/hooks/"
fi

echo "Claude config sync complete."
