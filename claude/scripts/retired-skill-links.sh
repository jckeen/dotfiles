# shellcheck shell=bash
# Sourced by health checkers; callers enumerate exact historical links only.

heal_retired_skill_link() {
  local link="$1" source="$2" bundle="$3" ancestor
  [ "${HEAL:-0}" -eq 1 ] || return 0
  [[ "$link" == /* && "$source" == /* && "$bundle" == /* ]] || return 0
  # A restored bundle is current again, even if one historical file is absent.
  [ ! -e "$bundle" ] && [ ! -L "$bundle" ] || return 0
  [ -L "$link" ] && [ "$(readlink "$link")" = "$source" ] || return 0
  for ancestor in "$(dirname "$link")" "$(dirname "$bundle")"; do
    while [ "$ancestor" != / ]; do
      [ ! -L "$ancestor" ] || return 0
      ancestor="$(dirname "$ancestor")"
    done
  done
  if rm -- "$link"; then
    green "RETIRED  ${link#"$HOME"/} (removed known retired skill link)"
    FIXED=$((FIXED + 1))
  else
    red "FAILED  ${link#"$HOME"/} could not remove retired skill link"
    ERRORS=$((ERRORS + 1))
  fi
}
