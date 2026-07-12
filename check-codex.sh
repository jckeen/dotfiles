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
AGENT_SKILLS_DST="$HOME/.agents/skills"
CODEX_MEMORY_REPO="$(dirname "$DOTFILES_DIR")/codex-memory"
ERRORS=0
WARNINGS=0
FIXED=0
ORPHAN_FIX="${1:-}"

report_orphan() {
  local link="$1" label="$2" target
  target="$(readlink "$link")"
  if [ "$ORPHAN_FIX" = "--fix" ]; then
    if rm "$link"; then
      green "CLEANED  $label (removed orphaned link -> $target)"
      FIXED=$((FIXED + 1))
    else
      red "FAILED  $label could not be removed"
      ERRORS=$((ERRORS + 1))
    fi
  else
    red "ORPHAN  $label -> $target (managed source removed)"
    ERRORS=$((ERRORS + 1))
  fi
}

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
# shellcheck disable=SC2088,SC2034  # display hint consumed by sourced lib-checks.sh; literal ~ intended
CHECK_MISSING_HINT="~/.codex/"
REPORTED_UNSAFE_DIRS=()

check_managed_parent_chain() {
  local root="$1" dir="$2" relative current component reported already_reported
  local -a components
  relative="${dir#"$root"}"
  relative="${relative#/}"
  IFS='/' read -r -a components <<< "$relative"
  current="$root"
  for component in "${components[@]}"; do
    [ -n "$component" ] || continue
    current="$current/$component"
    already_reported=0
    for reported in "${REPORTED_UNSAFE_DIRS[@]}"; do
      [ "$reported" = "$current" ] && already_reported=1
    done
    if [ -L "$current" ] && [ "$already_reported" -eq 0 ]; then
      red "UNSAFE  ${current#"$CODEX_DST"/} is a managed directory symlink -> $(readlink "$current")"
      red "        Managed skill ancestors must be real directories."
      ERRORS=$((ERRORS + 1))
      REPORTED_UNSAFE_DIRS+=("$current")
    fi
  done
}

echo "Checking Codex public-safe config..."
echo ""

if [ -L "$CODEX_DST" ]; then
  red "UNSAFE  ~/.codex is a directory symlink -> $(readlink "$CODEX_DST")"
  red "        Refusing to audit or clean through a symlinked runtime root."
  ERRORS=$((ERRORS + 1))
elif [ ! -d "$CODEX_DST" ]; then
  yellow "MISSING  ~/.codex (Codex has not been initialized on this machine)"
  WARNINGS=$((WARNINGS + 1))
else
  check_link "$CODEX_SRC/AGENTS.md" "$CODEX_DST/AGENTS.md" "AGENTS.md"

  if [ -L "$SKILLS_SRC" ]; then
    red "UNSAFE  shared source skill root is a directory symlink: $SKILLS_SRC"
    ERRORS=$((ERRORS + 1))
  elif [ -d "$SKILLS_SRC" ]; then
    for skill_dir in "$SKILLS_SRC/"*/; do
      if [ -L "${skill_dir%/}" ]; then
        red "UNSAFE  source skill root is a directory symlink: ${skill_dir#"$SKILLS_SRC"/}"
        ERRORS=$((ERRORS + 1))
        continue
      fi
      [ -d "$skill_dir" ] || continue
      skill_name="$(basename "$skill_dir")"
      skill_root_real="$(realpath "${skill_dir%/}")"
      skill_file_list="$(mktemp)"
      if [ -z "$skill_file_list" ]; then
        red "FAILED  unable to allocate skill traversal manifest"
        ERRORS=$((ERRORS + 1))
      elif find "$skill_dir" -name '.*' -prune -o \( -type f -o -type l \) -print0 > "$skill_file_list"; then
        while IFS= read -r -d '' skill_file; do
          if [ -L "$skill_file" ]; then
            skill_target_real="$(realpath "$skill_file" 2>/dev/null)"
            case "$skill_target_real" in
              "$skill_root_real"/*) ;;
              *)
                red "UNSAFE  source skill symlink escapes its bundle or is broken: ${skill_file#"$SKILLS_SRC"/}"
                ERRORS=$((ERRORS + 1))
                continue
                ;;
            esac
          fi
          skill_rel="${skill_file#"$skill_dir"}"
          skill_dst="$CODEX_DST/skills/$skill_name/$skill_rel"
          check_managed_parent_chain "$CODEX_DST" "$(dirname "$skill_dst")"
          check_link "$skill_file" "$skill_dst" "skills/$skill_name/$skill_rel"
        done < "$skill_file_list"
        check_link "${skill_dir%/}" "$AGENT_SKILLS_DST/$skill_name" "user-skills/$skill_name"
        rm -f "$skill_file_list"
      else
        rm -f "$skill_file_list"
        red "FAILED  unable to traverse complete skill bundle: $skill_name"
        ERRORS=$((ERRORS + 1))
      fi
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
  for source_and_link in \
    "$CODEX_SRC/AGENTS.md|$CODEX_DST/AGENTS.md" \
    "$CODEX_MEMORY_REPO/AGENTS.local.md|$CODEX_DST/AGENTS.local.md" \
    "$CODEX_MEMORY_REPO/MEMORY.md|$CODEX_DST/MEMORY.md"; do
    source="${source_and_link%%|*}"
    link="${source_and_link#*|}"
    [ -L "$link" ] || continue
    if [ "$(readlink "$link")" = "$source" ] && [ ! -e "$link" ]; then
      report_orphan "$link" "${link#"$CODEX_DST"/}"
    fi
  done

  if [ -e "$CODEX_DST/skills" ] || [ -L "$CODEX_DST/skills" ]; then
    skill_link_list="$(mktemp)"
    if [ -z "$skill_link_list" ]; then
      red "FAILED  unable to allocate orphan traversal manifest"
      ERRORS=$((ERRORS + 1))
    elif find "$CODEX_DST/skills" -type l -print0 > "$skill_link_list"; then
      while IFS= read -r -d '' link; do
        label="${link#"$CODEX_DST"/}"
        target="$(readlink "$link")"
        destination_rel="${link#"$CODEX_DST/skills/"}"
        destination_skill="${destination_rel%%/*}"
        if [ -d "$SKILLS_SRC/$destination_skill" ] && [ -d "$link" ]; then
          red "UNSAFE  $label is a directory symlink inside a managed skill -> $target"
          red "        Managed skill directories must be real directories."
          ERRORS=$((ERRORS + 1))
        elif [[ "$target" == "$SKILLS_SRC/"* ]] && [ ! -e "$link" ]; then
          source_rel="${target#"$SKILLS_SRC"/}"
          expected_link="$CODEX_DST/skills/$source_rel"
          if [[ "/$source_rel/" != *"/../"* ]] && [ "$link" = "$expected_link" ]; then
            report_orphan "$link" "$label"
          fi
        fi
      done < "$skill_link_list"
      rm -f "$skill_link_list"
    else
      rm -f "$skill_link_list"
      red "FAILED  unable to traverse managed skill destinations"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  if [ -d "$AGENT_SKILLS_DST" ]; then
    for link in "$AGENT_SKILLS_DST"/*; do
      [ -L "$link" ] || continue
      target="$(readlink "$link")"
      if [[ "$target" == "$SKILLS_SRC/"* ]] && [ ! -e "$link" ]; then
        expected="$SKILLS_SRC/$(basename "$link")"
        if [ "$target" = "$expected" ]; then
          report_orphan "$link" "user-skills/$(basename "$link")"
        fi
      fi
    done
  fi
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
