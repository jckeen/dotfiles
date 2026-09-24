# lib-services.sh — agent-service selection for setup.sh (issue #425).
#
# SOURCED, never executed (no shebang, mode 644), like lib-symlinks.sh and
# lib-checks.sh. setup.sh uses it to decide which of the three agent runtimes
# (Claude Code, Codex, Antigravity) it installs, links, and health-checks.
#
# The choice is machine-local state, never tracked data: it lives in
# $XDG_CONFIG_HOME/dotfiles/services (default ~/.config/dotfiles/services),
# outside the repo. Format — one assignment, comments allowed:
#     services=claude,codex
# The file is parsed, never sourced, so it cannot execute anything.
#
# Migration rule: an install with no saved selection manages all three
# services, exactly as setup.sh did before selection existed. The first real
# (non-dry-run) setup.sh run records that selection, so reruns change nothing
# unless the operator opts out with --services or --select-services.
# shellcheck shell=bash

# Canonical service names, in canonical order.
DOTFILES_KNOWN_SERVICES="claude codex antigravity"
# shellcheck disable=SC2034  # consumed by setup.sh, which sources this file
DOTFILES_ALL_SERVICES="claude,codex,antigravity"

# services_config_path — echo the machine-local selection file path. A
# relative or empty XDG_CONFIG_HOME is ignored, as the XDG spec requires.
services_config_path() {
  local base="${XDG_CONFIG_HOME:-}"
  case "$base" in
    /*) ;;
    *) base="$HOME/.config" ;;
  esac
  printf '%s/dotfiles/services\n' "$base"
}

# services_label <name> — human-readable name for output.
services_label() {
  case "$1" in
    claude) echo "Claude Code" ;;
    codex) echo "Codex" ;;
    antigravity) echo "Antigravity" ;;
    *) echo "$1" ;;
  esac
}

# services_normalize <list> — accept a comma- and/or space-separated list
# (case-insensitive; aliases: claude-code, agy, all) and echo the canonical
# comma-separated selection in canonical order. Returns 1 with a message on
# stderr for an unknown name or an empty selection.
services_normalize() {
  local raw tok s want=" " out=""
  local -a toks
  raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  IFS=', ' read -r -a toks <<< "$raw"
  for tok in ${toks[@]+"${toks[@]}"}; do
    [ -n "$tok" ] || continue
    case "$tok" in
      claude | claude-code) want="$want claude " ;;
      codex) want="$want codex " ;;
      antigravity | agy) want="$want antigravity " ;;
      all) want="$want claude codex antigravity " ;;
      *)
        echo "unknown agent service: '$tok' (expected: claude, codex, antigravity, or all)" >&2
        return 1
        ;;
    esac
  done
  for s in $DOTFILES_KNOWN_SERVICES; do
    case "$want" in *" $s "*) out="${out:+$out,}$s" ;; esac
  done
  if [ -z "$out" ]; then
    echo "no agent service selected (choose at least one of: claude, codex, antigravity)" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# services_load_saved <file> — echo the saved canonical selection.
# Returns 0 when found and valid, 1 when the file is absent, 2 when it exists
# but holds no valid `services=` line (message on stderr).
services_load_saved() {
  local file="$1" line value="" found=0
  [ -e "$file" ] || [ -L "$file" ] || return 1
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "saved service selection is not a readable file: $file" >&2
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    case "$line" in
      services=*) value="${line#services=}"; found=1 ;;
    esac
  done < "$file"
  if [ "$found" -ne 1 ]; then
    echo "saved service selection has no 'services=' line: $file" >&2
    return 2
  fi
  services_normalize "$value" || {
    echo "saved service selection is invalid: $file" >&2
    return 2
  }
}

# services_save <file> <canonical-list> — write the selection atomically
# (temp file + rename in the same directory). Returns non-zero on failure.
services_save() {
  local file="$1" list="$2" dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.services.XXXXXX")" || return 1
  if ! {
    printf '# Agent services managed by dotfiles setup.sh (issue #425).\n'
    printf '# Machine-local; change with: setup.sh --services <list> or --select-services\n'
    printf 'services=%s\n' "$list"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# service_selected <name> — 0 when <name> is in $DOTFILES_SELECTED_SERVICES.
service_selected() {
  case ",${DOTFILES_SELECTED_SERVICES:-}," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

# services_unselected <canonical-list> — echo the known services NOT in the
# list, comma-separated (empty when all are selected).
services_unselected() {
  local s out=""
  for s in $DOTFILES_KNOWN_SERVICES; do
    case ",$1," in *",$s,"*) ;; *) out="${out:+$out,}$s" ;; esac
  done
  printf '%s\n' "$out"
}
