#!/bin/bash
# Verify public-safe Codex dotfiles and warn about private/generated state.
# Run from anywhere: ~/dev/dotfiles/check-codex.sh

set +e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_SRC="$DOTFILES_DIR/codex"
# Shared workflow skills live in the agent-neutral agents/skills (single
# source for Codex and Antigravity), not under codex/.
SKILLS_SRC="$DOTFILES_DIR/agents/skills"
CODEX_DST="$HOME/.codex"
CODEX_MEMORY_REPO="$(dirname "$DOTFILES_DIR")/codex-memory"
ERRORS=0
WARNINGS=0
FIXED=0

# Shared check_link + report helpers (issue #199) — single source of truth
# with check-claude.sh, check-antigravity.sh, and setup.sh's audit path.
# Resolved relative to THIS script's directory; hard-fail if missing (under
# `set +e` a failed source would otherwise keep going and "pass" with no
# checks run). The lib includes the "exists but is not a regular file"
# branch this checker had drifted away from.
if [ ! -f "$DOTFILES_DIR/lib-checks.sh" ]; then
  echo "FATAL: $DOTFILES_DIR/lib-checks.sh is missing (broken checkout — restore it with 'git checkout lib-checks.sh')" >&2
  exit 1
fi
# shellcheck source=lib-checks.sh
source "$DOTFILES_DIR/lib-checks.sh"
CHECK_MISSING_HINT="~/.codex/"

echo "Checking Codex public-safe config..."
echo ""

if [ ! -d "$CODEX_DST" ]; then
  yellow "MISSING  ~/.codex (Codex has not been initialized on this machine)"
  WARNINGS=$((WARNINGS + 1))
else
  check_link "$CODEX_SRC/AGENTS.md" "$CODEX_DST/AGENTS.md" "AGENTS.md"

  if [ -d "$SKILLS_SRC" ]; then
    for skill_dir in "$SKILLS_SRC/"*/; do
      [ -d "$skill_dir" ] || continue
      skill_name="$(basename "$skill_dir")"
      for skill_file in "$skill_dir"*; do
        [ -f "$skill_file" ] || continue
        fname="$(basename "$skill_file")"
        check_link "$skill_file" "$CODEX_DST/skills/$skill_name/$fname" "skills/$skill_name/$fname"
      done
    done
  fi

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

# Branch hygiene status (silent if clean)
if [ -x "$DOTFILES_DIR/hygiene-status.sh" ]; then
  "$DOTFILES_DIR/hygiene-status.sh" --cli || true
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
