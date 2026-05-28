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

# Portable `readlink -f` — BSD/macOS readlink has no -f, and stock macOS ships
# no realpath. Prefer those when available, else walk the symlink chain by hand
# (POSIX). Returns the canonical absolute path of its argument.
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"; return
  fi
  if readlink -f "$1" >/dev/null 2>&1; then
    readlink -f "$1"; return
  fi
  local src="$1" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
  printf '%s/%s\n' "$dir" "$(basename "$src")"
}

# Resolve where this script really lives (it is symlinked onto PATH via
# setup.sh, so $0 is usually ~/.local/bin/pai-mode.sh). resolve_path follows
# the symlink chain to the real file inside the dotfiles checkout.
SCRIPT_PATH="$(resolve_path "$0")"
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

# Print the active mode by inspecting BOTH symlinks (raw readlink, no -f):
#   "pai"     — both point at PAI config
#   "plain"   — both point at the plain files
#   "mixed"   — a partially-applied toggle (one swapped, one not)
#   "unknown" — either is not a symlink
# cmd_off/cmd_on treat anything other than their own target state as work to do,
# so an interrupted toggle self-heals on the next run instead of being skipped.
current_mode() {
  if [ ! -L "$CLAUDE_MD" ] || [ ! -L "$SETTINGS" ]; then
    echo "unknown"
    return
  fi
  local c_plain=0 s_plain=0
  case "$(readlink "$CLAUDE_MD" 2>/dev/null)" in */claude/plain/CLAUDE.md) c_plain=1 ;; esac
  case "$(readlink "$SETTINGS" 2>/dev/null)" in */settings.plain.json) s_plain=1 ;; esac
  if [ "$c_plain" = 1 ] && [ "$s_plain" = 1 ]; then
    echo "plain"
  elif [ "$c_plain" = 0 ] && [ "$s_plain" = 0 ]; then
    echo "pai"
  else
    echo "mixed"
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

  # Never clobber a real file — we only swap symlinks. This toggle requires the
  # symlink-based PAI layout that claude-memory/bootstrap.sh creates. If setup.sh
  # copied pai-config into ~/.claude/ as regular files (the bootstrap-absent
  # fallback), convert them to symlinks first rather than risk overwriting them.
  if [ ! -L "$CLAUDE_MD" ] || [ ! -L "$SETTINGS" ]; then
    err "Refusing: ~/.claude/CLAUDE.md or settings.json is not a symlink."
    err "This toggle requires the symlink-based PAI layout from"
    err "claude-memory/bootstrap.sh. Run that to convert the regular-file PAI"
    err "config into symlinks, then retry pai-off."
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

  # Save the current PAI targets so pai-on can restore them exactly — but ONLY
  # from a clean "pai" state. Saving from a "mixed" state (a prior interrupted
  # toggle) would record a plain target as the restore point and break pai-on.
  if [ "$mode" = "pai" ]; then
    {
      readlink "$CLAUDE_MD"
      readlink "$SETTINGS"
    } >"$STATE"
  fi

  # Generate plain settings from the current settings target (resolved through
  # the symlink) into a temp file first; only swap if jq succeeds, so a failure
  # never leaves a dangling or half-written settings symlink. The STRIP filter
  # is idempotent, so regenerating from an already-plain target is harmless.
  local pai_settings tmp
  pai_settings="$(resolve_path "$SETTINGS")"
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
  # Symmetric with cmd_off: never clobber a regular file. `ln -sfn` over a real
  # file silently destroys it, so refuse if either path exists and isn't a symlink.
  if { [ -e "$CLAUDE_MD" ] && [ ! -L "$CLAUDE_MD" ]; } ||
     { [ -e "$SETTINGS" ] && [ ! -L "$SETTINGS" ]; }; then
    err "Refusing: ~/.claude/CLAUDE.md or settings.json is a regular file, not a symlink."
    err "Restore the symlink-based PAI layout via claude-memory/bootstrap.sh first."
    return 1
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
  # Don't relink to a target that no longer exists (e.g. the checkout moved) —
  # that would print success while leaving dangling symlinks.
  if [ ! -e "$claude_target" ] || [ ! -e "$settings_target" ]; then
    err "Saved PAI target missing — checkout moved? Re-run claude-memory/bootstrap.sh."
    err "  CLAUDE.md     <- $claude_target"
    err "  settings.json <- $settings_target"
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
