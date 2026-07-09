#!/bin/bash
# Verify public-safe Antigravity (agy) dotfiles and warn about private state.
# Run from anywhere: ~/dev/dotfiles/check-antigravity.sh
#
# The global customization root is ~/.gemini/config/ (GEMINI.md rules, skills/).
# Live runtime state lives under ~/.gemini/antigravity-cli/ and must stay local.

set +e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
AGY_SRC="$DOTFILES_DIR/antigravity"
AGY_DST="$HOME/.gemini/config"
AGY_STATE="$HOME/.gemini/antigravity-cli"
AGY_MEMORY_REPO="$(dirname "$DOTFILES_DIR")/agy-memory"
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
  elif [ -e "$dst" ]; then
    yellow "NOT LINKED  $label (exists but is not a symlink)"
    WARNINGS=$((WARNINGS + 1))
  else
    yellow "MISSING  $label (not present in ~/.gemini/config/)"
    WARNINGS=$((WARNINGS + 1))
  fi
}

warn_if_present() {
  local path="$1" label="$2"
  [ -e "$path" ] || return 0
  echo "LOCAL   $label exists; keep it private and out of public dotfiles"
}

echo "Checking Antigravity public-safe config..."
echo ""

if [ ! -d "$AGY_DST" ]; then
  yellow "MISSING  ~/.gemini/config (Antigravity has not been initialized on this machine)"
  WARNINGS=$((WARNINGS + 1))
else
  check_link "$AGY_SRC/GEMINI.md" "$AGY_DST/GEMINI.md" "GEMINI.md"
  check_link "$AGY_SRC/hooks.json" "$AGY_DST/hooks.json" "hooks.json"

  # Shared workflow skills: dir-level symlinks into the agent-neutral set
  # maintained at agents/skills (single source for Codex and Antigravity).
  if [ -d "$DOTFILES_DIR/agents/skills" ]; then
    for skill_dir in "$DOTFILES_DIR/agents/skills/"*/; do
      [ -d "$skill_dir" ] || continue
      skill_name="$(basename "$skill_dir")"
      check_link "${skill_dir%/}" "$AGY_DST/skills/$skill_name" "skills/$skill_name"
    done
  fi

  # Antigravity-only skills (browser-verify, ...).
  if [ -d "$AGY_SRC/skills" ]; then
    for skill_dir in "$AGY_SRC/skills/"*/; do
      [ -d "$skill_dir" ] || continue
      skill_name="$(basename "$skill_dir")"
      check_link "${skill_dir%/}" "$AGY_DST/skills/$skill_name" "skills/$skill_name"
    done
  fi

  # MCP servers: the live config is LOCAL by design (seeded from the template
  # by setup.sh); empty/missing means the runtime/browser lane has no tooling.
  if [ ! -s "$AGY_DST/mcp_config.json" ]; then
    yellow "MISSING  mcp_config.json is absent or empty — the browser/runtime lane has no MCP tooling (re-run setup.sh to seed from antigravity/mcp_config.json.example)"
    WARNINGS=$((WARNINGS + 1))
  else
    echo "LOCAL   mcp_config.json present (local by design; template: antigravity/mcp_config.json.example)"
  fi

  if [ -d "$AGY_MEMORY_REPO" ]; then
    for f in GEMINI.local.md MEMORY.md; do
      if [ -f "$AGY_MEMORY_REPO/$f" ]; then
        check_link "$AGY_MEMORY_REPO/$f" "$AGY_DST/$f" "$f"
      fi
    done
  fi

  echo ""
  echo "Checking private/generated Antigravity state..."
  warn_if_present "$AGY_STATE/antigravity-oauth-token" "antigravity-oauth-token"
  warn_if_present "$AGY_STATE/conversations" "conversations/"
  warn_if_present "$AGY_STATE/brain" "brain/"
  warn_if_present "$AGY_STATE/knowledge" "knowledge/"
  warn_if_present "$AGY_STATE/history.jsonl" "history.jsonl"
  for f in "$AGY_STATE"/*.db*; do
    [ -e "$f" ] || continue
    warn_if_present "$f" "$(basename "$f")"
  done

  echo ""
  echo "Checking for orphaned managed symlinks..."
  while IFS= read -r link; do
    target="$(readlink "$link")"
    if [[ "$target" == "$DOTFILES_DIR"* ]] && [ ! -e "$link" ]; then
      label="${link#$AGY_DST/}"
      if [ "${1:-}" = "--fix" ]; then
        rm "$link"
        green "CLEANED  $label (removed orphaned link -> $target)"
        FIXED=$((FIXED + 1))
      else
        red "ORPHAN  $label -> $target (source removed from dotfiles)"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  done < <(find "$AGY_DST" -maxdepth 2 -type l 2>/dev/null)
fi

echo ""
if [ $ERRORS -eq 0 ]; then
  if [ $WARNINGS -eq 0 ]; then
    green "All good. Antigravity public config is in sync."
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
  echo "Run './check-antigravity.sh --fix' to auto-clean managed orphaned links."
  exit 1
fi
