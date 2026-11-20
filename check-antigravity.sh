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
ERRORS=0
WARNINGS=0
STALE_BINARIES=0
FIXED=0
FIX=0
HEAL=0
HEALED=0
STRICT=0
AGY_DST_MASKED=0
AGY_STATE_MASKED=0
AGY_MOUNTINFO_READABLE=0
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
# The sibling repo follows DOTFILES_DEV_DIR like setup.sh does (#701); the
# explicit AGY_MEMORY_REPO still wins.
if [ -z "${AGY_MEMORY_REPO:-}" ]; then
  _agy_dev_dir="$(dotfiles_dev_dir "$DOTFILES_DIR")" || exit 1
  AGY_MEMORY_REPO="${_agy_dev_dir%/}/agy-memory"
fi
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
[ -r "$AGY_MOUNTINFO_FILE" ] && AGY_MOUNTINFO_READABLE=1
agy_sandbox_masked() {
  local escaped="$1"
  [ "$AGY_MOUNTINFO_READABLE" -eq 1 ] || return 1
  escaped="${escaped//\\/\\134}"
  escaped="${escaped// /\\040}"
  escaped="${escaped//$'\t'/\\011}"
  escaped="${escaped//$'\n'/\\012}"
  MP="$escaped" awk '
    BEGIN { mp = ENVIRON["MP"] }
    $5 == mp && $4 ~ /^\/setup\/deny/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "-" && $(i+1) == "tmpfs") { found = 1; exit }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$AGY_MOUNTINFO_FILE"
}

# Verify mountinfo shows /proc is a real proc mount without hidepid restrictions.
agy_proc_mount_complete() {
  [ "$AGY_MOUNTINFO_READABLE" -eq 1 ] || return 1
  awk '
    function options_unrestricted(field,    opts, n, k, opt) {
      n = split(field, opts, ",")
      for (k = 1; k <= n; k++) {
        opt = opts[k]
        if (opt == "hidepid" || substr(opt, 1, 8) == "hidepid=") {
          if (opt != "hidepid=0" && opt != "hidepid=off") {
            return 0
          }
        }
      }
      return 1
    }
    BEGIN { FS = "[ ]"; ok = 0 }
    $5 == "/proc" {
      ok = 0
      for (i = 7; i <= NF; i++) {
        if ($i == "-") {
          if (i + 3 <= NF && $(i + 1) == "proc" && options_unrestricted($6) && options_unrestricted($(i + 3))) {
            ok = 1
          }
          break
        }
      }
    }
    END { exit(ok ? 0 : 1) }
  ' "$AGY_MOUNTINFO_FILE"
}

agy_shell_quote() {
  local s="$1" out=""
  while [[ "$s" == *"'"* ]]; do
    out="${out}${s%%"'"*}'\\''"
    s="${s#*"'"}"
  done
  printf "'%s%s'" "$out" "$s"
}

agy_warn_literal() {
  if [ -t 1 ]; then
    printf '\033[33m[WARN] %s\033[0m\n' "$1"
  else
    printf '[WARN] %s\n' "$1"
  fi
}

agy_err_literal() {
  if [ -t 1 ]; then
    printf '\033[31m[ERR] %s\033[0m\n' "$1"
  else
    printf '[ERR] %s\n' "$1"
  fi
}

# Reject empty, relative, non-canonical (. / ..), non-directory, unsearchable, or symlinked ancestors/leaf.
agy_validate_bin_dir() {
  local raw="$1" p="$1" cur="" seg
  local -a segs
  if [ -z "$raw" ] || [ "${raw#/}" = "$raw" ]; then
    agy_err_literal "UNSAFE  AGY_BIN_DIR must be a non-empty absolute path (got '$raw')"
    ERRORS=$((ERRORS + 1))
    return 1
  fi
  case "$raw" in
    *$'\n'*)
      agy_err_literal "UNSAFE  AGY_BIN_DIR contains a newline character"
      ERRORS=$((ERRORS + 1))
      return 1
      ;;
  esac
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do
    p="${p%/}"
  done
  IFS=/ read -ra segs <<< "$p"
  for seg in "${segs[@]}"; do
    [ -n "$seg" ] || continue
    case "$seg" in
      .|..)
        agy_err_literal "UNSAFE  AGY_BIN_DIR '$raw' contains a non-canonical '.' or '..' segment"
        red "        Refusing to inspect Antigravity binaries through a non-canonical path."
        ERRORS=$((ERRORS + 1))
        return 1
        ;;
    esac
    cur="$cur/$seg"
    if [ -L "$cur" ]; then
      agy_err_literal "UNSAFE  $cur is a directory symlink -> $(readlink "$cur")"
      red "        Refusing to inspect Antigravity binaries through a symlinked path component."
      ERRORS=$((ERRORS + 1))
      return 1
    fi
    if [ -e "$cur" ] && [ ! -d "$cur" ]; then
      agy_err_literal "UNSAFE  $cur exists but is not a directory"
      ERRORS=$((ERRORS + 1))
      return 1
    fi
    if [ -d "$cur" ] && [ ! -x "$cur" ]; then
      agy_err_literal "UNREADABLE $cur is not searchable — cannot inspect $raw"
      ERRORS=$((ERRORS + 1))
      return 1
    fi
  done
  AGY_BIN_DIR="${cur:-/}"
  return 0
}

echo "Checking Antigravity public-safe config..."
echo ""

agy_sandbox_masked "$AGY_DST" && AGY_DST_MASKED=1
agy_sandbox_masked "$AGY_STATE" && AGY_STATE_MASKED=1

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
      AGY_PERM_ARGS=(--settings "$AGY_SETTINGS" --rules "$AGY_SRC/permissions.json")
      if [ -f "$AGY_MEMORY_REPO/permissions.local.json" ]; then
        AGY_PERM_ARGS+=(--overlay "$AGY_MEMORY_REPO/permissions.local.json")
      fi
      # --heal applies the additive merge first (same idempotent step setup.sh runs).
      if [ "$HEAL" -eq 1 ]; then
        python3 "$DOTFILES_DIR/claude/scripts/agy-apply-permissions.py" apply \
          "${AGY_PERM_ARGS[@]}" >/dev/null 2>&1 || true
      fi
      if baseline_out="$(python3 "$DOTFILES_DIR/claude/scripts/agy-apply-permissions.py" check \
          "${AGY_PERM_ARGS[@]}" 2>&1)"; then
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
echo "Checking Antigravity CLI binary state..."
if [ "${AGY_BIN_DIR+x}" != "x" ]; then
  AGY_BIN_DIR="$HOME/.local/bin"
fi
if agy_validate_bin_dir "$AGY_BIN_DIR" && [ -d "$AGY_BIN_DIR" ]; then
  if [ ! -r "$AGY_BIN_DIR" ] || [ ! -x "$AGY_BIN_DIR" ] || ! ls -A -- "$AGY_BIN_DIR" >/dev/null 2>&1; then
    agy_err_literal "UNREADABLE $AGY_BIN_DIR cannot be enumerated — binary audit unavailable"
    ERRORS=$((ERRORS + 1))
  else
    OLD_AGY_BINS=()
    for old_bin in "$AGY_BIN_DIR"/agy.*.old; do
      [ ! -L "$old_bin" ] && [ -f "$old_bin" ] || continue
      OLD_AGY_BINS+=("$old_bin")
    done
    if [ "${#OLD_AGY_BINS[@]}" -gt 0 ]; then
      AGY_MAIN_OK=1
      if [ ! -f "$AGY_BIN_DIR/agy" ] || [ ! -s "$AGY_BIN_DIR/agy" ] || [ ! -x "$AGY_BIN_DIR/agy" ]; then
        agy_err_literal "BROKEN  $AGY_BIN_DIR/agy is missing or not a non-empty executable alongside ${#OLD_AGY_BINS[@]} agy.*.old backup(s)"
        ERRORS=$((ERRORS + 1))
        AGY_MAIN_OK=0
      fi
      AGY_PROC_DIR="${AGY_PROC_DIR:-/proc}"
      while [ "$AGY_PROC_DIR" != "/" ] && [ "${AGY_PROC_DIR%/}" != "$AGY_PROC_DIR" ]; do
        AGY_PROC_DIR="${AGY_PROC_DIR%/}"
      done
      PROC_VIEW_COMPLETE=0
      if [ "$AGY_MOUNTINFO_READABLE" -eq 1 ] && [ "$AGY_DST_MASKED" -eq 0 ] && [ "$AGY_STATE_MASKED" -eq 0 ] && [ -d "$AGY_PROC_DIR" ] && [ -r "$AGY_PROC_DIR" ] && [ -x "$AGY_PROC_DIR" ] && ls -A -- "$AGY_PROC_DIR" >/dev/null 2>&1 && agy_proc_mount_complete; then
        if [ "$AGY_PROC_DIR" != "/proc" ] || [ -L "/proc/self/exe" ]; then
          PROC_VIEW_COMPLETE=1
        fi
      fi
      for old_bin in "${OLD_AGY_BINS[@]}"; do
        old_name="$(basename "$old_bin")"
        if [ "$AGY_MAIN_OK" -eq 0 ]; then
          continue
        fi
        if [ "$AGY_BIN_DIR/agy" -ef "$old_bin" ]; then
          agy_warn_literal "STALE   $old_name (active rollback target of agy — keep)"
          STALE_BINARIES=$((STALE_BINARIES + 1))
          continue
        fi
        in_use=0
        unreadable_exe=0
        scanned_pids=0
        proc_complete="$PROC_VIEW_COMPLETE"
        if [ "$proc_complete" -eq 1 ]; then
          old_real=""
          if command -v python3 >/dev/null 2>&1; then
            old_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$old_bin" 2>/dev/null || true)"
          fi
          for pid_dir in "$AGY_PROC_DIR"/[0-9]*; do
            [ -d "$pid_dir" ] || continue
            scanned_pids=$((scanned_pids + 1))
            exe="$pid_dir/exe"
            if [ "$exe" -ef "$old_bin" ]; then
              in_use=1
              break
            fi
            if exe_target="$(readlink "$exe" 2>/dev/null)" && [ -n "$exe_target" ]; then
              exe_target="${exe_target% (deleted)}"
              if { [ -n "$old_real" ] && [ "$exe_target" = "$old_real" ]; } || [ "$exe_target" = "$old_bin" ]; then
                in_use=1
                break
              fi
            else
              unreadable_exe=1
            fi
          done
        fi
        [ "$scanned_pids" -eq 0 ] && proc_complete=0
        quoted_old_bin="$(agy_shell_quote "$old_bin" && printf x)"
        quoted_old_bin="${quoted_old_bin%x}"
        if [ "$in_use" -eq 1 ]; then
          agy_warn_literal "STALE   $old_name (in use by an older agy process; remove manually after that process exits — see GEMINI.md Runtime Resilience)"
        elif [ "$proc_complete" -eq 0 ] || [ "$unreadable_exe" -eq 1 ]; then
          agy_warn_literal "STALE   $old_name (auto-update backup; full host process visibility unavailable or restricted — confirm no older agy session is running on the host, then remove manually: rm -- $quoted_old_bin)"
        else
          agy_warn_literal "STALE   $old_name (auto-update backup; no visible process matched — after confirming no older agy session is running, remove manually: rm -- $quoted_old_bin)"
        fi
        STALE_BINARIES=$((STALE_BINARIES + 1))
      done
    fi
  fi
fi

echo ""
[ "$HEALED" -gt 0 ] && green "Self-healed $HEALED missing link(s)."
if [ $ERRORS -eq 0 ]; then
  if [ $WARNINGS -eq 0 ]; then
    green "All good. Antigravity public config is in sync."
    [ "$STALE_BINARIES" -gt 0 ] && yellow "$STALE_BINARIES stale agy.*.old binary note(s) above (advisory; does not fail --strict)."
  else
    yellow "$WARNINGS warning(s) found."
    echo "Warnings are actionable config issues. LOCAL runtime state lines are informational."
    [ "$STALE_BINARIES" -gt 0 ] && yellow "$STALE_BINARIES stale agy.*.old binary note(s) above (advisory; does not fail --strict)."
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
