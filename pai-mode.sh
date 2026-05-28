#!/usr/bin/env bash
# pai-mode.sh — toggle Claude Code between the full PAI system and a lean
# "plain" baseline, reversibly and without losing MCP servers or permissions.
#
# Both ~/.claude/CLAUDE.md and ~/.claude/settings.json are symlinks into a
# private config repo (claude-memory/pai-config). This script swaps WHICH
# files those two symlinks point at — it never edits the PAI source.
#
#   pai-mode.sh off     → plain Claude: lean CLAUDE.md + settings minus PAI
#                         hooks/context/identity. MCP + permissions kept.
#   pai-mode.sh on      → restore the exact PAI symlink targets.
#   pai-mode.sh status  → report which mode is active.
#
# Plain settings are GENERATED at runtime into ~/.claude/settings.plain.json
# (never committed) so personal MCP config stays local. The PAI targets are
# DETECTED at runtime and saved to ~/.claude/.pai-mode.state so `on` restores
# the exact prior state — nothing about the user's layout is hardcoded here.
#
# Requires: jq. A Claude Code restart is needed for either switch to take effect.

set -euo pipefail

# Resolve where this script really lives (it is symlinked onto PATH via
# setup.sh, so $0 is usually ~/.local/bin/pai-mode.sh). readlink -f follows
# the symlink chain to the real file inside the dotfiles checkout.
SCRIPT_PATH="$(readlink -f "$0")"
DOTFILES_DIR="$(dirname "$SCRIPT_PATH")"

CLAUDE_DIR="$HOME/.claude"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
SETTINGS="$CLAUDE_DIR/settings.json"
PLAIN_CLAUDE_MD="$DOTFILES_DIR/claude/plain/CLAUDE.md"
PLAIN_SETTINGS="$CLAUDE_DIR/settings.plain.json"
STATE="$CLAUDE_DIR/.pai-mode.state"

# Keys removed from settings.json in plain mode: everything that makes Claude
# behave like PAI. Everything else (mcpServers, permissions, enabledPlugins,
# env, ...) is retained so plain mode stays usable.
STRIP='del(.hooks, .statusLine, .dynamicContext, .contextFiles, .loadAtStartup,
           .pai, .daidentity, .principal, .voiceEnabled, .spinnerVerbs,
           .spinnerTipsOverride, .skillOverrides, .teammateMode, .contextDisplay)'

err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

restart_hint() {
  info ""
  info "Restart Claude Code for this to take effect (exit and relaunch, or /clear won't do it)."
}

# Print the active mode: "plain", "pai", or "unknown".
current_mode() {
  if [ ! -L "$CLAUDE_MD" ]; then
    echo "unknown"
    return
  fi
  if [ "$(readlink -f "$CLAUDE_MD")" = "$(readlink -f "$PLAIN_CLAUDE_MD")" ]; then
    echo "plain"
  else
    echo "pai"
  fi
}

cmd_status() {
  local mode
  mode="$(current_mode)"
  info "PAI mode: $mode"
  info ""
  info "  CLAUDE.md      -> $(readlink "$CLAUDE_MD" 2>/dev/null || echo '(not a symlink)')"
  info "  settings.json  -> $(readlink "$SETTINGS" 2>/dev/null || echo '(not a symlink)')"
  if [ -f "$STATE" ]; then
    info ""
    info "  saved PAI targets (for pai-on):"
    info "    CLAUDE.md     <- $(sed -n '1p' "$STATE")"
    info "    settings.json <- $(sed -n '2p' "$STATE")"
  fi
}

cmd_off() {
  local mode
  mode="$(current_mode)"
  if [ "$mode" = "plain" ]; then
    info "Already in plain mode. (pai-on to restore PAI)"
    return 0
  fi

  # Never clobber a real file — we only swap symlinks.
  if [ ! -L "$CLAUDE_MD" ] || [ ! -L "$SETTINGS" ]; then
    err "Refusing: ~/.claude/CLAUDE.md or settings.json is not a symlink."
    err "This toggle only swaps symlinks. Resolve that manually first."
    return 1
  fi
  if [ ! -f "$PLAIN_CLAUDE_MD" ]; then
    err "Missing plain CLAUDE.md at: $PLAIN_CLAUDE_MD"
    err "Is the dotfiles checkout complete?"
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    err "jq is required to generate plain settings but was not found on PATH."
    return 1
  fi

  # Save the current (PAI) targets so pai-on can restore them exactly.
  {
    readlink "$CLAUDE_MD"
    readlink "$SETTINGS"
  } >"$STATE"

  # Generate plain settings from the live PAI settings (resolved through the
  # symlink) into a temp file first; only swap if jq succeeds, so a failure
  # never leaves a dangling or half-written settings symlink.
  local pai_settings tmp
  pai_settings="$(readlink -f "$SETTINGS")"
  tmp="$(mktemp "${PLAIN_SETTINGS}.XXXXXX")"
  if ! jq "$STRIP" "$pai_settings" >"$tmp"; then
    rm -f "$tmp"
    err "Failed to generate plain settings from $pai_settings"
    return 1
  fi
  mv "$tmp" "$PLAIN_SETTINGS"

  ln -sfn "$PLAIN_CLAUDE_MD" "$CLAUDE_MD"
  ln -sfn "$PLAIN_SETTINGS" "$SETTINGS"

  ok "PAI is OFF — plain Claude active (MCP + permissions kept, PAI hooks/context/identity dropped)."
  restart_hint
}

cmd_on() {
  local mode
  mode="$(current_mode)"
  if [ "$mode" = "pai" ]; then
    info "Already in PAI mode."
    return 0
  fi
  if [ ! -f "$STATE" ]; then
    err "No saved PAI targets at $STATE — can't auto-restore."
    err "Re-link manually, or run: bash ~/dev/claude-memory/bootstrap.sh"
    return 1
  fi

  local claude_target settings_target
  claude_target="$(sed -n '1p' "$STATE")"
  settings_target="$(sed -n '2p' "$STATE")"
  if [ -z "$claude_target" ] || [ -z "$settings_target" ]; then
    err "State file $STATE is malformed."
    return 1
  fi

  ln -sfn "$claude_target" "$CLAUDE_MD"
  ln -sfn "$settings_target" "$SETTINGS"

  ok "PAI is ON — full PAI system restored."
  restart_hint
}

usage() {
  info "Usage: pai-mode.sh {off|on|status}"
  info ""
  info "  off     Switch to plain Claude (lean CLAUDE.md, settings minus PAI hooks)."
  info "  on      Restore the full PAI system."
  info "  status  Show which mode is active."
}

main() {
  case "${1:-}" in
    off)    cmd_off ;;
    on)     cmd_on ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *) err "Unknown command: $1"; usage; return 1 ;;
  esac
}

main "$@"
