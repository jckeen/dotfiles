#!/usr/bin/env bash
# Install the git-hygiene timer as a systemd --user service (Linux/WSL2).
#
# Idempotent: safe to re-run on upgrades or after pulling new unit files.
#
# Usage:
#   bash ~/dev/dotfiles/claude/systemd/install.sh
#
# Requirements:
#   - systemd (WSL2: set `systemd=true` in /etc/wsl.conf under [boot])
#
# After install this script also attempts to enable user lingering via sudo,
# so the timer fires at boot without an interactive login. If sudo is
# unavailable, it prints the command for you to run manually.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.config/systemd/user"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yell()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;34m%s\033[0m\n' "$*"; }

info "==> Checking prerequisites"
command -v systemctl >/dev/null || { red "X systemctl not found — systemd required"; exit 1; }
mkdir -p "$DEST_DIR"

info "==> Installing git-hygiene timer"
HYG_SERVICE="git-hygiene.service"
HYG_TIMER="git-hygiene.timer"
HYG_SCRIPT="$HOME/dev/dotfiles/claude/scripts/hygiene-cron.sh"

if [ -f "$SRC_DIR/$HYG_SERVICE" ] && [ -f "$SRC_DIR/$HYG_TIMER" ] && [ -x "$HYG_SCRIPT" ]; then
    cp "$SRC_DIR/$HYG_SERVICE" "$DEST_DIR/$HYG_SERVICE"
    cp "$SRC_DIR/$HYG_TIMER" "$DEST_DIR/$HYG_TIMER"
    mkdir -p "$HOME/.local/state/hygiene"
    systemctl --user daemon-reload
    systemctl --user enable --now "$HYG_TIMER" >/dev/null 2>&1 || \
        systemctl --user enable "$HYG_TIMER" >/dev/null
    systemctl --user start "$HYG_TIMER" 2>/dev/null || true
    if systemctl --user is-enabled --quiet "$HYG_TIMER"; then
        green "OK $HYG_TIMER enabled"
        systemctl --user list-timers "$HYG_TIMER" --no-pager 2>/dev/null | tail -3 || true
    else
        yell "! $HYG_TIMER did not enable — check: systemctl --user status $HYG_TIMER"
    fi
else
    yell "! Skipping $HYG_TIMER install — unit files or hygiene-cron.sh missing"
    exit 1
fi

info "==> Enabling user lingering (timer fires without login)"
if loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
    green "OK Lingering already enabled"
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    sudo loginctl enable-linger "$USER" && green "OK Lingering enabled"
else
    yell "! Run this once manually to persist across boots:"
    yell "    sudo loginctl enable-linger $USER"
fi

echo
green "==> Done."
echo
echo "Useful commands:"
echo "  systemctl --user list-timers $HYG_TIMER"
echo "  systemctl --user start $HYG_SERVICE   # run hygiene check now"
echo "  tail -f ~/.local/state/hygiene/cron.log"
