# shellcheck shell=bash
# Sourced by health checkers; callers enumerate exact historical links only.

heal_retired_skill_link() {
  local link="$1" source="$2" bundle="$3" ancestor target result
  [ "${HEAL:-0}" -eq 1 ] || return 0
  [[ "$link" == /* && "$source" == /* && "$bundle" == /* ]] || return 0
  # A restored bundle is current again, even if one historical file is absent.
  [ ! -e "$bundle" ] && [ ! -L "$bundle" ] || return 0
  [ -L "$link" ] || return 0
  # Preserve target bytes; remove only readlink's terminator and our sentinel.
  target="$(readlink "$link" && printf .)" || return 0
  target=${target%$'\n.'}
  [ "$target" = "$source" ] || return 0
  for ancestor in "$link" "$bundle"; do
    while [ "$ancestor" != / ]; do
      # Absolute parent extraction preserves newline bytes in directory names.
      ancestor=${ancestor%/*}
      [ -n "$ancestor" ] || ancestor=/
      [ ! -L "$ancestor" ] || return 0
      # An inaccessible ancestor makes an existing bundle look absent to -e.
      if [ -e "$ancestor" ] && { [ ! -d "$ancestor" ] || [ ! -x "$ancestor" ]; }; then
        return 0
      fi
    done
  done
  # A pathname recheck cannot make rm conditional on the checked symlink:
  # a concurrent replacement could still be deleted. Capture the entry first.
  command -v python3 >/dev/null 2>&1 || return 0
  if python3 "${BASH_SOURCE[0]%/*}/retired-skill-links.py" "$link" "$source" "$bundle"; then
    green "RETIRED  ${link#"$HOME"/} (removed known retired skill link)"
    FIXED=$((FIXED + 1))
  else
    result=$?
    [ "$result" -eq 1 ] && return 0
    red "FAILED  ${link#"$HOME"/} could not remove retired skill link"
    ERRORS=$((ERRORS + 1))
  fi
}
