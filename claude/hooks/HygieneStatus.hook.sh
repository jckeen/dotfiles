#!/usr/bin/env bash
# SessionStart hook: surface branch-hygiene drift if the daily systemd timer
# detected any. Thin wrapper — the actual logic is in hygiene-status.sh so
# both Claude (this hook) and Codex (check-codex.sh) can share it.

exec "$HOME/dev/dotfiles/hygiene-status.sh" --reminder
