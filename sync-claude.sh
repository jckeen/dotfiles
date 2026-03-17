#!/usr/bin/env bash
# Syncs Claude config from dotfiles repo to ~/.claude/
# Source: ~/dev/dotfiles/claude/ → ~/.claude/
# Run after editing dotfiles, or add to a cron/hook.

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)/claude"
CLAUDE_DIR="$HOME/.claude"

# Sync skills — each skill is a directory with a SKILL.md file
SKILLS_SRC="$DOTFILES_DIR/skills"
SKILLS_DST="$CLAUDE_DIR/skills"
mkdir -p "$SKILLS_DST"

if [ -d "$SKILLS_SRC" ]; then
    # Sync skill directories from dotfiles
    for d in "$SKILLS_SRC"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        mkdir -p "$SKILLS_DST/$name"
        if [ ! -f "$SKILLS_DST/$name/SKILL.md" ] || ! diff -q "$d/SKILL.md" "$SKILLS_DST/$name/SKILL.md" > /dev/null 2>&1; then
            cp "$d/SKILL.md" "$SKILLS_DST/$name/SKILL.md"
            echo "  updated skill: $name"
        fi
    done
    # Remove skills that no longer exist in dotfiles
    for d in "$SKILLS_DST"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        if [ ! -d "$SKILLS_SRC/$name" ]; then
            rm -rf "$d"
            echo "  removed skill: $name"
        fi
    done
    # Clean up any old flat .md skill files
    for f in "$SKILLS_DST"/*.md; do
        [ -f "$f" ] || continue
        rm "$f"
        echo "  removed legacy flat skill: $(basename "$f")"
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
    chmod +x "$CLAUDE_DIR/hooks/"*.sh 2>/dev/null || true
    echo "  updated: hooks"
fi

# Sync agents directory
if [ -d "$DOTFILES_DIR/agents" ]; then
    AGENTS_DST="$CLAUDE_DIR/agents"
    mkdir -p "$AGENTS_DST"
    for f in "$DOTFILES_DIR/agents/"*.md; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        if [ ! -f "$AGENTS_DST/$name" ] || ! diff -q "$f" "$AGENTS_DST/$name" > /dev/null 2>&1; then
            cp "$f" "$AGENTS_DST/$name"
            echo "  updated agent: $name"
        fi
    done
    # Remove agents that no longer exist in dotfiles
    for f in "$AGENTS_DST/"*.md; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        if [ ! -f "$DOTFILES_DIR/agents/$name" ]; then
            rm "$f"
            echo "  removed agent: $name"
        fi
    done
fi

echo "Claude config sync complete."
