#!/usr/bin/env bash
# Install this directory's systemd --user timers (Linux/WSL2).
#
# Idempotent: safe to re-run on upgrades or after pulling new unit files.
#
# Adding a timer means adding one row to UNITS below — nothing else in this
# script is per-unit. A row is "<unit base>|<script, repo-relative>|<state dir,
# $HOME-relative>"; the state dir is created before the timer is enabled so the
# first firing has somewhere to write.
#
# Usage:
#   bash ~/dev/dotfiles/claude/systemd/install.sh
#
# Requirements:
#   - systemd (WSL2: set `systemd=true` in /etc/wsl.conf under [boot])
#
# After install this script also attempts to enable user lingering via sudo,
# so the timers fire at boot without an interactive login. If sudo is
# unavailable, it prints the command for you to run manually.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.config/systemd/user"
REPO_DIR="$(cd "$SRC_DIR/../.." && pwd)"

UNITS=(
  "git-hygiene|claude/scripts/hygiene-cron.sh|.local/state/hygiene"
  "jules-dispatch|claude/scripts/jules-dispatch.sh|.local/state/jules"
)

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yell()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;34m%s\033[0m\n' "$*"; }

info "==> Checking prerequisites"
command -v systemctl >/dev/null || { red "X systemctl not found — systemd required"; exit 1; }
mkdir -p "$DEST_DIR"

failed=0
installed=()

for row in "${UNITS[@]}"; do
    IFS='|' read -r base script state <<< "$row"
    service="$base.service"
    timer="$base.timer"
    script_path="$REPO_DIR/$script"

    info "==> Installing $timer"
    if [ ! -f "$SRC_DIR/$service" ] || [ ! -f "$SRC_DIR/$timer" ] || [ ! -x "$script_path" ]; then
        yell "! Skipping $timer install — unit files or $script missing/not executable"
        failed=$((failed + 1))
        continue
    fi

    cp "$SRC_DIR/$service" "$DEST_DIR/$service"
    cp "$SRC_DIR/$timer" "$DEST_DIR/$timer"
    mkdir -p "$HOME/$state"
    systemctl --user daemon-reload
    systemctl --user enable --now "$timer" >/dev/null 2>&1 || \
        systemctl --user enable "$timer" >/dev/null
    systemctl --user start "$timer" 2>/dev/null || true
    if systemctl --user is-enabled --quiet "$timer"; then
        green "OK $timer enabled"
        installed+=("$base")
        systemctl --user list-timers "$timer" --no-pager 2>/dev/null | tail -3 || true
    else
        yell "! $timer did not enable — check: systemctl --user status $timer"
        failed=$((failed + 1))
    fi
done

if [ "$failed" -gt 0 ]; then
    red "X $failed timer(s) did not install"
    exit 1
fi

info "==> Enabling user lingering (timers fire without login)"
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
for base in "${installed[@]}"; do
    echo "  systemctl --user list-timers $base.timer"
    echo "  systemctl --user start $base.service   # run it now"
done
echo "  tail -f ~/.local/state/hygiene/cron.log"
echo "  tail -f ~/.local/state/jules/dispatch.log"
