#!/usr/bin/env bash
# Install the PAI Voice Server as a systemd --user service (Linux/WSL2).
#
# Idempotent: safe to re-run on upgrades or after pulling a new unit file.
#
# Usage:
#   bash ~/dev/dotfiles/claude/systemd/install.sh
#
# Requirements:
#   - systemd (WSL2: set `systemd=true` in /etc/wsl.conf under [boot])
#   - bun installed at ~/.bun/bin/bun
#   - ~/.claude/VoiceServer/server.ts present (shipped with PAI)
#   - ~/.env (or symlink) containing ELEVENLABS_API_KEY
#
# After install this script also attempts to enable user lingering via sudo,
# so the service starts at boot without an interactive login. If sudo is
# unavailable, it prints the command for you to run manually.

set -euo pipefail

SERVICE_NAME="pai-voice-server.service"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_UNIT="$SRC_DIR/$SERVICE_NAME"
DEST_DIR="$HOME/.config/systemd/user"
DEST_UNIT="$DEST_DIR/$SERVICE_NAME"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yell()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;34m%s\033[0m\n' "$*"; }

info "==> Checking prerequisites"
command -v systemctl >/dev/null || { red "X systemctl not found — systemd required"; exit 1; }
[ -x "$HOME/.bun/bin/bun" ] || { red "X bun not found at ~/.bun/bin/bun — install bun first"; exit 1; }
[ -f "$HOME/.claude/VoiceServer/server.ts" ] || { red "X ~/.claude/VoiceServer/server.ts missing — install PAI first"; exit 1; }
[ -f "$SRC_UNIT" ] || { red "X Source unit missing: $SRC_UNIT"; exit 1; }
if [ ! -e "$HOME/.env" ]; then
    yell "! ~/.env not found — voice server will error on ELEVENLABS_API_KEY. Create it or symlink it before starting."
fi

info "==> Installing unit -> $DEST_UNIT"
mkdir -p "$DEST_DIR"
mkdir -p "$HOME/.claude/VoiceServer/logs"
cp "$SRC_UNIT" "$DEST_UNIT"

info "==> Reloading systemd user daemon"
systemctl --user daemon-reload

info "==> Enabling and (re)starting $SERVICE_NAME"
systemctl --user enable "$SERVICE_NAME" >/dev/null
systemctl --user restart "$SERVICE_NAME"

sleep 2

if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    green "OK $SERVICE_NAME is active"
else
    red "X $SERVICE_NAME failed to start — check: journalctl --user -u $SERVICE_NAME -n 50"
    exit 1
fi

info "==> Health check"
if curl -sf http://localhost:8888/health >/dev/null; then
    green "OK Voice server responding on :8888"
else
    yell "! Service is running but /health did not respond yet (may still be warming up)"
fi

info "==> Enabling user lingering (service starts without login)"
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
echo "  systemctl --user status  $SERVICE_NAME"
echo "  systemctl --user restart $SERVICE_NAME"
echo "  systemctl --user stop    $SERVICE_NAME"
echo "  journalctl --user -u $SERVICE_NAME -f"
echo "  tail -f ~/.claude/VoiceServer/logs/voice-server.log"
