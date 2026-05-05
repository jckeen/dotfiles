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
#   - bun on PATH (symlinks to ~/.bun/bin/bun if elsewhere)
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

# Bun: the systemd unit hardcodes %h/.bun/bin/bun. Accept bun installed
# anywhere on PATH (brew, npm, curl installer) and symlink it into the
# canonical path so the unit works regardless of install method.
BUN_CANON="$HOME/.bun/bin/bun"
if [ ! -x "$BUN_CANON" ]; then
    BUN_FOUND="$(command -v bun 2>/dev/null || true)"
    if [ -n "$BUN_FOUND" ]; then
        info "    bun found at $BUN_FOUND — symlinking to $BUN_CANON"
        mkdir -p "$HOME/.bun/bin"
        ln -sf "$BUN_FOUND" "$BUN_CANON"
    else
        red "X bun not found on PATH or at $BUN_CANON — install bun first"
        exit 1
    fi
fi
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

info "==> Clearing port 8888 before restart"
# Stop any existing systemd instance first so anything still bound to :8888
# afterward can be identified as a foreign (non-systemd) squatter. This is the
# common WSL/Linux failure mode: a manually-started `bun run server.ts` squats
# the port and the unit crash-loops with EADDRINUSE forever.
systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
sleep 1
if command -v ss >/dev/null; then
    squatter_pids="$(ss -H -lntp 2>/dev/null | awk '$4 ~ /:8888$/' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)"
    if [ -n "$squatter_pids" ]; then
        yell "! Foreign process(es) holding :8888: $squatter_pids — killing so $SERVICE_NAME can bind"
        for p in $squatter_pids; do
            if ! kill "$p" 2>/dev/null; then
                yell "! Failed to terminate PID $p"
            fi
        done
        sleep 1
        squatter_pids="$(ss -H -lntp 2>/dev/null | awk '$4 ~ /:8888$/' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)"
        if [ -n "$squatter_pids" ]; then
            for p in $squatter_pids; do
                if ! kill -9 "$p" 2>/dev/null; then
                    yell "! Failed to force-kill PID $p"
                fi
            done
            sleep 1
        fi
    fi
else
    yell "! ss (iproute2) not available — skipping :8888 squatter check; restart may fail with EADDRINUSE"
fi
# Prior crash-loops may have tripped the start-rate limit; clear it so the
# first post-install start isn't blocked.
systemctl --user reset-failed "$SERVICE_NAME" 2>/dev/null || true

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

info "==> Installing git-hygiene timer"
HYG_SERVICE="git-hygiene.service"
HYG_TIMER="git-hygiene.timer"
HYG_SCRIPT="$HOME/dev/dotfiles/claude/scripts/hygiene-cron.sh"

if [ -f "$SRC_DIR/$HYG_SERVICE" ] && [ -f "$SRC_DIR/$HYG_TIMER" ] && [ -x "$HYG_SCRIPT" ]; then
    cp "$SRC_DIR/$HYG_SERVICE" "$DEST_DIR/$HYG_SERVICE"
    cp "$SRC_DIR/$HYG_TIMER" "$DEST_DIR/$HYG_TIMER"
    mkdir -p "$HOME/.local/share/git-hygiene" "$HOME/.claude/state"
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
echo
echo "  systemctl --user list-timers $HYG_TIMER"
echo "  systemctl --user start $HYG_SERVICE   # run hygiene check now"
echo "  tail -f ~/.local/share/git-hygiene/cron.log"
