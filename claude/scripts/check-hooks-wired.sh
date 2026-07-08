#!/usr/bin/env bash
# check-hooks-wired.sh — warn when a hook FILE exists but isn't wired in settings.
#
# The hooks under claude/hooks/ only run if they're registered in the live
# ~/.claude/settings.json `hooks` block. That wiring lives in the private
# claude-memory repo, so it can drift out of sync with the hook files here with
# nothing to catch it — which is exactly how every documented hook silently went
# inert (no `hooks` key at all). Public CI can't see the private settings, so
# this is a LOCAL guard: run at `cc` launch (via check-claude.sh) where the real
# merged settings.json is present.
#
# For every claude/hooks/*.{sh,ts} that is NOT in the opt-out list below, verify
# its filename appears among the settings' hook commands. Warn (advisory) on any
# that don't, with the fix hint. Exit 0 unless --strict is given.
#
# Usage:  check-hooks-wired.sh [--strict]   (--strict: exit 1 on drift)

set -euo pipefail

STRICT=0
QUIET=0
for a in "$@"; do
  case "$a" in
    --strict) STRICT=1 ;;
    --quiet)  QUIET=1 ;;  # suppress the success line (for callers that run it every launch)
  esac
done

# Hooks intentionally NOT wired — keep this list in sync with the decision in
# CLAUDE-GUIDE's hooks table. Anything here is skipped (no warning).
OPT_OUT=(
)

# --- Load shared helpers, then resolve repo root via the real path -----
# checker-lib.sh (beside this script) provides checker_repo_root, which follows
# symlinks so REPO_ROOT lands on the dotfiles checkout, plus the green()/yellow()
# printers used below.
# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
REPO_ROOT="$(checker_repo_root "${BASH_SOURCE[0]}")"
HOOKS_DIR="$REPO_ROOT/claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

[ -d "$HOOKS_DIR" ] || { green "no hooks dir — nothing to check"; exit 0; }
if [ ! -f "$SETTINGS" ]; then
  yellow "settings.json not found at $SETTINGS — cannot verify hook wiring."
  [ "$STRICT" -eq 1 ] && exit 1 || exit 0
fi
command -v jq >/dev/null 2>&1 || { yellow "jq not found — skipping hook-wiring check"; exit 0; }

# All command strings referenced anywhere under .hooks (recursive).
WIRED_COMMANDS="$(jq -r '.hooks // {} | .. | .command? // empty' "$SETTINGS" 2>/dev/null || true)"

is_opted_out() {
  local name="$1" o
  for o in "${OPT_OUT[@]}"; do [ "$name" = "$o" ] && return 0; done
  return 1
}

drift=0
for f in "$HOOKS_DIR"/*.sh "$HOOKS_DIR"/*.ts; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  is_opted_out "$name" && continue
  if ! printf '%s\n' "$WIRED_COMMANDS" | grep -qF "$name"; then
    [ "$drift" -eq 0 ] && yellow "Hook files present but NOT wired in settings.json (they will not run):"
    drift=$((drift + 1))
    printf '    - %s\n' "$name"
  fi
done

if [ "$drift" -ne 0 ]; then
  echo "  Fix: add them to the .hooks block of $SETTINGS (this lives in the"
  echo "  private claude-memory repo), or add to OPT_OUT in check-hooks-wired.sh"
  echo "  if intentionally disabled."
  [ "$STRICT" -eq 1 ] && exit 1
  exit 0
fi

[ "$QUIET" -eq 1 ] || green "hook wiring OK — every non-opted-out hook is registered in settings.json"
