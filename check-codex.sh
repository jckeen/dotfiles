#!/bin/bash
# Verify public-safe Codex dotfiles and warn about private/generated state.
# Run from anywhere: ~/dev/dotfiles/check-codex.sh

set +e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_SRC="$DOTFILES_DIR/codex"
CODEX_DST="$HOME/.codex"
CODEX_MEMORY_REPO="$(dirname "$DOTFILES_DIR")/codex-memory"
ERRORS=0
WARNINGS=0
FIXED=0

red()    { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }

check_link() {
  local src="$1" dst="$2" label="$3"
  if [ -L "$dst" ]; then
    local target
    target="$(readlink "$dst")"
    if [ "$target" != "$src" ]; then
      red "WRONG  $label -> $target (expected $src)"
      ERRORS=$((ERRORS + 1))
    elif [ ! -e "$dst" ]; then
      red "BROKEN $label -> $target (target missing)"
      ERRORS=$((ERRORS + 1))
    fi
  elif [ -f "$dst" ]; then
    yellow "NOT LINKED  $label (exists but is a regular file, not a symlink)"
    WARNINGS=$((WARNINGS + 1))
  else
    yellow "MISSING  $label (not present in ~/.codex/)"
    WARNINGS=$((WARNINGS + 1))
  fi
}

warn_if_present() {
  local path="$1" label="$2"
  [ -e "$path" ] || return 0
  echo "LOCAL   $label exists; keep it private and out of public dotfiles"
}

echo "Checking Codex public-safe config..."
echo ""

if [ ! -d "$CODEX_DST" ]; then
  yellow "MISSING  ~/.codex (Codex has not been initialized on this machine)"
  WARNINGS=$((WARNINGS + 1))
else
  check_link "$CODEX_SRC/AGENTS.md" "$CODEX_DST/AGENTS.md" "AGENTS.md"

  if [ -d "$CODEX_MEMORY_REPO" ]; then
    for f in AGENTS.local.md MEMORY.md; do
      if [ -f "$CODEX_MEMORY_REPO/$f" ]; then
        check_link "$CODEX_MEMORY_REPO/$f" "$CODEX_DST/$f" "$f"
      fi
    done
  fi

  if [ -L "$CODEX_DST/config.toml" ]; then
    target="$(readlink "$CODEX_DST/config.toml")"
    red "UNSAFE  config.toml is a symlink -> $target"
    red "        Live Codex config stores machine-specific trust entries; keep it local."
    ERRORS=$((ERRORS + 1))
  elif [ -f "$CODEX_DST/config.toml" ]; then
    echo "LOCAL   config.toml is local, as expected"
  else
    echo "LOCAL   config.toml is absent; Codex will create it when needed"
  fi

  echo ""
  echo "Checking private/generated Codex state..."
  warn_if_present "$CODEX_DST/auth.json" "auth.json"
  warn_if_present "$CODEX_DST/history.jsonl" "history.jsonl"
  warn_if_present "$CODEX_DST/log" "log/"
  warn_if_present "$CODEX_DST/sessions" "sessions/"
  warn_if_present "$CODEX_DST/shell_snapshots" "shell_snapshots/"
  warn_if_present "$CODEX_DST/cache" "cache/"
  warn_if_present "$CODEX_DST/.tmp" ".tmp/"
  warn_if_present "$CODEX_DST/tmp" "tmp/"
  for f in "$CODEX_DST"/logs_*.sqlite* "$CODEX_DST"/state_*.sqlite*; do
    [ -e "$f" ] || continue
    warn_if_present "$f" "$(basename "$f")"
  done

  echo ""
  echo "Checking for orphaned managed symlinks..."
  while IFS= read -r link; do
    target="$(readlink "$link")"
    if [[ "$target" == "$DOTFILES_DIR"* ]] && [ ! -e "$link" ]; then
      label="${link#$CODEX_DST/}"
      if [ "${1:-}" = "--fix" ]; then
        rm "$link"
        green "CLEANED  $label (removed orphaned link -> $target)"
        FIXED=$((FIXED + 1))
      else
        red "ORPHAN  $label -> $target (source removed from dotfiles)"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  done < <(find "$CODEX_DST" -maxdepth 3 -type l 2>/dev/null)
fi

echo ""
if [ $ERRORS -eq 0 ]; then
  if [ $WARNINGS -eq 0 ]; then
    green "All good. Codex public config is in sync."
  else
    yellow "$WARNINGS warning(s) found."
    echo "Warnings are actionable config issues. LOCAL runtime state lines are informational."
  fi
  [ $FIXED -gt 0 ] && green "Cleaned up $FIXED item(s)."
  exit 0
else
  red "$ERRORS error(s) found."
  [ $WARNINGS -gt 0 ] && yellow "$WARNINGS warning(s) found."
  echo ""
  echo "Run './check-codex.sh --fix' to auto-clean managed orphaned links."
  exit 1
fi
