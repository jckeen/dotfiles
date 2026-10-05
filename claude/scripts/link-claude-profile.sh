#!/usr/bin/env bash
# link-claude-profile.sh — wire a second Claude Code config directory (a
# "profile") so a second account runs with this machine's setup.
#
# Claude Code keeps one login per config directory and selects the directory
# with CLAUDE_CONFIG_DIR. Everything follows that variable, not just the
# credentials: settings, skills, agents, plugins and the projects/ tree
# (transcripts + memory). This script links the account-neutral entries of a
# profile back to ~/.claude, so the profile differs from the default one only
# in what is bound to the account: .credentials.json, .claude.json, history
# and live session state.
#
# Each link targets ~/.claude/<name>, never the dotfiles or memory repo
# directly, so ~/.claude stays the single wiring check-claude.sh has to heal.
# Sharing projects/ and file-history/ is what lets a session started on one
# account be resumed on the other.
#
# User-scope MCP servers live in the account-bound .claude.json, so they are
# copied from ~/.claude.json when they differ. Their OAuth grants are stored
# with the credentials and are per account.
#
# Usage: link-claude-profile.sh [--check] <profile-dir>
#   --check   report drift without changing anything
# Exit: 0 wired, 1 drift it will not repair (a real file or foreign link in
# the way — nothing is ever overwritten — or MCP servers it could not
# compare), 2 usage.
# Tests: tests/claude-profile.test.sh

set -uo pipefail

SHARED="settings.json CLAUDE.md keybindings.json skills agents commands rules output-styles plugins projects file-history"
# State directories Claude creates by itself on first use. They are linked even
# when the default profile has not made them yet: skipping one would let a
# session on this profile create a private copy that then blocks the link.
ENSURED=" plugins projects file-history "

CHECK=0
PROFILE=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -*) echo "link-claude-profile: unknown flag $arg" >&2; exit 2 ;;
    *) PROFILE="$arg" ;;
  esac
done

BASE="$HOME/.claude"
case "$PROFILE" in
  /*) ;;
  *) echo "Usage: link-claude-profile.sh [--check] <absolute-profile-dir>" >&2; exit 2 ;;
esac
# Compare physical paths: "$HOME/./.claude" or a symlinked parent would pass a
# lexical test and then have the loop below link ~/.claude onto itself.
leaf="$(basename "$PROFILE")"
parent="$(cd -P "$(dirname "$PROFILE")" 2>/dev/null && pwd -P)" || parent=""
if [ -z "$parent" ] || [ "$leaf" = "." ] || [ "$leaf" = ".." ]; then
  echo "link-claude-profile: $PROFILE must name a directory under an existing parent" >&2
  exit 2
fi
PROFILE="${parent%/}/$leaf"
BASE_REAL="$(cd -P "$BASE" 2>/dev/null && pwd -P)" || BASE_REAL="$BASE"
case "$PROFILE/" in
  "$BASE/"*|"$BASE_REAL/"*)
    echo "link-claude-profile: $PROFILE is the default config dir (or inside it)" >&2
    exit 2
    ;;
esac
if [ -L "$PROFILE" ]; then
  echo "link-claude-profile: $PROFILE is a symlink — a profile must be a real directory" >&2
  exit 2
fi

rc=0
drift() { echo "  $1" >&2; rc=1; }

if [ ! -d "$PROFILE" ]; then
  if [ "$CHECK" -eq 1 ]; then
    drift "MISSING  $PROFILE"
    exit "$rc"
  fi
  mkdir -p "$PROFILE" && chmod 700 "$PROFILE" || { drift "cannot create $PROFILE"; exit "$rc"; }
fi

for name in $SHARED; do
  src="$BASE/$name"
  dst="$PROFILE/$name"
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    case "$ENSURED" in
      *" $name "*)
        if [ "$CHECK" -eq 0 ]; then
          mkdir -p "$src" || { drift "cannot create $src"; continue; }
        fi
        ;;
      *)
        # Nothing to share until the default profile has it — but a copy that
        # exists only here would make the two accounts behave differently.
        if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then continue; fi
        if [ -d "$dst" ] && [ ! -L "$dst" ] && [ "$CHECK" -eq 0 ]; then
          rmdir "$dst" 2>/dev/null || true
        fi
        if [ -e "$dst" ] || [ -L "$dst" ]; then
          drift "PRIVATE  $dst exists only in this profile — move it to $src or remove it, re-run"
        fi
        continue
        ;;
    esac
  fi
  if [ -L "$dst" ]; then
    [ "$(readlink "$dst")" = "$src" ] || drift "WRONG  $dst -> $(readlink "$dst") (expected $src)"
    continue
  fi
  # Claude creates empty state directories on first run; an empty one holds
  # nothing to lose, so it yields to the link. rmdir refuses anything else.
  if [ -d "$dst" ] && [ "$CHECK" -eq 0 ]; then
    rmdir "$dst" 2>/dev/null || true
  fi
  if [ -e "$dst" ]; then
    drift "NOT SHARED  $dst is a real $([ -d "$dst" ] && echo directory || echo file) — merge it into $src, remove it, re-run"
    continue
  fi
  if [ "$CHECK" -eq 1 ]; then
    drift "MISSING  $dst -> $src"
  else
    ln -sn "$src" "$dst" || drift "cannot link $dst"
  fi
done

# User-scope MCP servers. The default profile's state file sits beside
# ~/.claude, a named profile's inside its own directory.
BASE_STATE="$HOME/.claude.json"
PROFILE_STATE="$PROFILE/.claude.json"
if [ -f "$BASE_STATE" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    drift "jq not found — cannot compare MCP servers in $PROFILE_STATE with $BASE_STATE"
  else
    want="$(jq -cS '.mcpServers // {}' "$BASE_STATE" 2>/dev/null)" || want=""
    have="{}"
    if [ -f "$PROFILE_STATE" ]; then
      have="$(jq -cS '.mcpServers // {}' "$PROFILE_STATE" 2>/dev/null)" || have=""
    fi
    if [ -z "$want" ] || [ -z "$have" ]; then
      drift "UNREADABLE  $([ -z "$want" ] && echo "$BASE_STATE" || echo "$PROFILE_STATE") is not valid JSON — MCP servers not synced"
    elif [ "$want" != "$have" ]; then
      if [ "$CHECK" -eq 1 ]; then
        drift "STALE  MCP servers in $PROFILE_STATE differ from $BASE_STATE"
      else
        # Same-directory temp + rename, so a reader never sees a partial file.
        tmp="$(umask 077 && mktemp "$PROFILE/.claude.json.XXXXXX")" || tmp=""
        if [ -n "$tmp" ] && {
          if [ -f "$PROFILE_STATE" ]; then
            jq --argjson servers "$want" '.mcpServers = $servers' "$PROFILE_STATE"
          else
            jq -n --argjson servers "$want" '{mcpServers: $servers}'
          fi
        } > "$tmp" && mv "$tmp" "$PROFILE_STATE"; then
          :
        else
          [ -n "$tmp" ] && rm -f "$tmp"
          drift "cannot write MCP servers to $PROFILE_STATE"
        fi
      fi
    fi
  fi
fi

exit "$rc"
