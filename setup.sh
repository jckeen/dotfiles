#!/bin/bash
# Symlink dotfiles into place
# Run from the dotfiles repo root: ./setup.sh

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"

echo "Installing dotfiles from $DOTFILES_DIR"

# Claude Code config
mkdir -p "$HOME_DIR/.claude"
cp "$DOTFILES_DIR/claude/settings.json" "$HOME_DIR/.claude/settings.json"
cp "$DOTFILES_DIR/claude/CLAUDE.md" "$HOME_DIR/.claude/CLAUDE.md"
echo "  -> Claude config installed"

# Git config
cp "$DOTFILES_DIR/.gitconfig" "$HOME_DIR/.gitconfig"
echo "  -> .gitconfig installed"

echo "Done!"
