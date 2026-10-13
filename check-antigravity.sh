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
AGY_MEMORY_REPO="${AGY_MEMORY_REPO:-$(dirname "$DOTFILES_DIR")/agy-memory}"
ERRORS=0
WARNINGS=0
FIXED=0
FIX=0
HEAL=0
HEALED=0
STRICT=0
# shellcheck disable=SC2034  # HEAL is consumed by the sourced link helpers.
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    --heal) HEAL=1 ;;
    --strict) STRICT=1 ;;
  esac
done

# Shared check_link + report helpers (issue #199) — single source of truth
# with check-claude.sh, check-codex.sh, and setup.sh's audit path. Resolved
# relative to THIS script's directory; hard-fail if missing (under `set +e`
# a failed source would otherwise keep going and "pass" with no checks run).
if [ ! -f "$DOTFILES_DIR/lib-checks.sh" ]; then
  echo "FATAL: $DOTFILES_DIR/lib-checks.sh is missing (broken checkout — restore it with 'git checkout lib-checks.sh')" >&2
  exit 1
fi
# shellcheck source=lib-checks.sh
source "$DOTFILES_DIR/lib-checks.sh"
if [ ! -f "$DOTFILES_DIR/claude/scripts/retired-skill-links.sh" ]; then
  echo "FATAL: retired-skill-links.sh is missing (broken checkout)" >&2
  exit 1
fi
# shellcheck source=claude/scripts/retired-skill-links.sh
source "$DOTFILES_DIR/claude/scripts/retired-skill-links.sh"
# shellcheck disable=SC2088,SC2034  # display hint consumed by sourced lib-checks.sh; literal ~ intended
CHECK_MISSING_HINT="~/.gemini/config/"

# Detect whether a path is masked by Antigravity's Linux terminal sandbox
# (bwrap mounts a read-only tmpfs from /setup/deny* over ~/.gemini/config and
# ~/.gemini/antigravity-cli, re-binding only GEMINI.md as a regular file,
# projects/, skills/, and selected runtime subdirectories).
AGY_MOUNTINFO_FILE="${AGY_MOUNTINFO_FILE:-/proc/self/mountinfo}"
agy_sandbox_masked() {
  local target="$1"
  [ -r "$AGY_MOUNTINFO_FILE" ] || return 1
  awk -v mp="$target" '
    $5 == mp && $4 ~ /^\/setup\/deny/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "-" && $(i+1) == "tmpfs") { found = 1; exit }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$AGY_MOUNTINFO_FILE"
}

echo "Checking Antigravity public-safe config..."
echo ""

if [ -L "$HOME/.gemini" ]; then
  red "UNSAFE  ~/.gemini is a directory symlink -> $(readlink "$HOME/.gemini")"
  red "        Refusing to audit or clean through a symlinked runtime parent."
  ERRORS=$((ERRORS + 1))
elif [ -L "$AGY_DST" ]; then
  red "UNSAFE  ~/.gemini/config is a directory symlink -> $(readlink "$AGY_DST")"
  red "        Refusing to audit or clean through a symlinked runtime root."
  ERRORS=$((ERRORS + 1))
elif [ ! -d "$AGY_DST" ]; then
  red "MISSING  ~/.gemini/config (Antigravity has not been initialized on this machine)"
  ERRORS=$((ERRORS + 1))
else
  AGY_DST_MASKED=0
  agy_sandbox_masked "$AGY_DST" && AGY_DST_MASKED=1
  AGY_STATE_MASKED=0
  agy_sandbox_masked "$AGY_STATE" && AGY_STATE_MASKED=1

  if [ "$AGY_DST_MASKED" -eq 1 ] && [ ! -L "$AGY_DST/GEMINI.md" ] && [ -f "$AGY_DST/GEMINI.md" ]; then
    if cmp -s "$AGY_SRC/GEMINI.md" "$AGY_DST/GEMINI.md"; then
      echo "SANDBOX GEMINI.md matches antigravity/GEMINI.md (bind-mounted inside sandbox)"
    else
      yellow "DRIFT   GEMINI.md inside sandbox differs from $AGY_SRC/GEMINI.md"
      WARNINGS=$((WARNINGS + 1))
    fi
  else
    check_link "$AGY_SRC/GEMINI.md" "$AGY_DST/GEMINI.md" "GEMINI.md"
  fi

  if [ "$AGY_DST_MASKED" -eq 1 ] && [ ! -e "$AGY_DST/hooks.json" ] && [ ! -L "$AGY_DST/hooks.json" ]; then
    echo "SANDBOX hooks.json masked by Antigravity terminal sandbox (verified on host at launch)"
  else
    check_link "$AGY_SRC/hooks.json" "$AGY_DST/hooks.json" "hooks.json"
  fi

  # Permission baseline (antigravity/permissions.json) is merged into the
  # machine-local ~/.gemini/antigravity-cli/settings.json by setup.sh, never
  # linked: that file also holds trustedWorkspaces and prompt-saved grants.
  AGY_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"
  if [ -f "$AGY_SRC/permissions.json" ] && command -v python3 >/dev/null 2>&1; then
    if [ "$AGY_STATE_MASKED" -eq 1 ] && [ ! -e "$AGY_SETTINGS" ]; then
      echo "SANDBOX permission baseline: settings.json masked by Antigravity terminal sandbox (verified on host at launch)"
    else
      # --heal applies the additive merge first (same idempotent step setup.sh runs).
      if [ "$HEAL" -eq 1 ]; then
        python3 "$DOTFILES_DIR/claude/scripts/agy-apply-permissions.py" apply \
          --settings "$AGY_SETTINGS" --rules "$AGY_SRC/permissions.json" >/dev/null 2>&1 || true
      fi
      if baseline_out="$(python3 "$DOTFILES_DIR/claude/scripts/agy-apply-permissions.py" check \
          --settings "$AGY_SETTINGS" --rules "$AGY_SRC/permissions.json" 2>&1)"; then
        echo "OK      permission baseline: $baseline_out"
      else
        yellow "DRIFT   permission baseline: $baseline_out (re-run setup.sh)"
        WARNINGS=$((WARNINGS + 1))
      fi
    fi
  fi

  AGY_SKILLS_UNSAFE=0
  if [ -L "$AGY_DST/skills" ]; then
    red "UNSAFE  skills is a managed directory symlink -> $(readlink "$AGY_DST/skills")"
    red "        Managed skill ancestors must be real directories."
    ERRORS=$((ERRORS + 1))
    AGY_SKILLS_UNSAFE=1
  fi
  if [ "$AGY_SKILLS_UNSAFE" -eq 0 ]; then
    heal_retired_skill_link "$AGY_DST/skills/fable-mode" \
      "$DOTFILES_DIR/agents/skills/fable-mode" "$DOTFILES_DIR/agents/skills/fable-mode"
  fi

  # Shared workflow skills: dir-level symlinks into the agent-neutral set
  # maintained at agents/skills (single source for Codex and Antigravity).
  if [ "$AGY_SKILLS_UNSAFE" -eq 0 ] && [ -d "$DOTFILES_DIR/agents/skills" ]; then
    for skill_dir in "$DOTFILES_DIR/agents/skills/"*/; do
      [ -d "$skill_dir" ] || continue
      skill_name="$(basename "$skill_dir")"
      check_link "${skill_dir%/}" "$AGY_DST/skills/$skill_name" "skills/$skill_name"
    done
  fi

  # Antigravity-only skills (browser-verify, ...).
  if [ "$AGY_SKILLS_UNSAFE" -eq 0 ] && [ -d "$AGY_SRC/skills" ]; then
    for skill_dir in "$AGY_SRC/skills/"*/; do
      [ -d "$skill_dir" ] || continue
      skill_name="$(basename "$skill_dir")"
      check_link "${skill_dir%/}" "$AGY_DST/skills/$skill_name" "skills/$skill_name"
    done
  fi

  # MCP servers: the live config is LOCAL by design (seeded from the template
  # by setup.sh); empty/missing means the runtime/browser lane has no tooling.
  if [ "$AGY_DST_MASKED" -eq 1 ] && [ ! -e "$AGY_DST/mcp_config.json" ] && [ ! -L "$AGY_DST/mcp_config.json" ]; then
    echo "SANDBOX mcp_config.json masked by Antigravity terminal sandbox (verified on host at launch)"
  elif [ ! -s "$AGY_DST/mcp_config.json" ]; then
    yellow "MISSING  mcp_config.json is absent or empty — the browser/runtime lane has no MCP tooling (re-run setup.sh to seed from antigravity/mcp_config.json.example)"
    WARNINGS=$((WARNINGS + 1))
  elif ! command -v jq >/dev/null 2>&1; then
    red "INVALID  mcp_config.json cannot be validated because jq is unavailable"
    ERRORS=$((ERRORS + 1))
  elif ! jq -e 'type == "object" and ((.mcpServers // .mcp_servers) | type == "object")' \
    "$AGY_DST/mcp_config.json" >/dev/null 2>&1; then
    red "INVALID  mcp_config.json must be valid JSON with an MCP server object"
    ERRORS=$((ERRORS + 1))
  else
    echo "LOCAL   mcp_config.json present (local by design; template: antigravity/mcp_config.json.example)"
  fi

  if [ -d "$AGY_MEMORY_REPO" ]; then
    for f in GEMINI.local.md MEMORY.md; do
      if [ -f "$AGY_MEMORY_REPO/$f" ]; then
        if [ "$AGY_DST_MASKED" -eq 1 ] && [ ! -e "$AGY_DST/$f" ] && [ ! -L "$AGY_DST/$f" ]; then
          echo "SANDBOX $f masked by Antigravity terminal sandbox (verified on host at launch)"
        else
          check_link "$AGY_MEMORY_REPO/$f" "$AGY_DST/$f" "$f"
        fi
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
      if [ "$FIX" -eq 1 ]; then
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
[ "$HEALED" -gt 0 ] && green "Self-healed $HEALED missing link(s)."
if [ $ERRORS -eq 0 ]; then
  if [ $WARNINGS -eq 0 ]; then
    green "All good. Antigravity public config is in sync."
  else
    yellow "$WARNINGS warning(s) found."
    echo "Warnings are actionable config issues. LOCAL runtime state lines are informational."
    [ "$STRICT" -eq 1 ] && exit 1
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
