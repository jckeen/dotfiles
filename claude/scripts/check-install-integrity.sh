#!/usr/bin/env bash
# check-install-integrity.sh — guard the two fresh-clone install regressions
# the June 2026 audit found (issues #120, #121), promoted from discipline into CI.
#
# Two static checks, no install performed:
#
#   1. Exec bits — every tracked *.sh with a `#!` shebang must be mode 100755 in
#      the git index. core.fileMode=false on the maintainer's box means a new
#      script can be committed 100644; on a fresh clone `./script.sh` then fails
#      with Permission denied, and any `[ -x script ]` guard silently skips it
#      (exactly how check-codex.sh's missing bit disabled the Codex health check).
#
#   2. Marketplace arms — every `@marketplace` referenced in claude/plugins.txt
#      must have a matching registration arm in setup.sh's marketplace `case`.
#      A plugin whose marketplace has no arm falls through to the "Unknown
#      marketplace" branch and never installs (how codex@openai-codex silently
#      failed on fresh machines).
#
# Usage:  claude/scripts/check-install-integrity.sh
# Run from anywhere; resolves its own repo root (it is symlinked into ~/.claude).

set -euo pipefail

# --- Locate the repo to scan ------------------------------------------------
# Use the repo containing the current directory (mirrors check-doc-truth.sh), so
# the fixture-based self-test can drive this checker by cd-ing into a throwaway
# repo. CI runs it from the dotfiles checkout, so that is what gets scanned.
if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "✖ check-install-integrity: not inside a git repo" >&2
  exit 1
fi
cd "$REPO_ROOT"

fail=0

# --- Check 1: shebanged *.sh scripts are executable in the index ------------
# `git ls-files -s` prints "<mode> <sha> <stage>\t<path>" — mode/sha/stage are
# space-separated, so default IFS (space+tab) splits all four fields. (Repo
# *.sh paths have no spaces; a spaced path would need a tab-only split.)
while read -r mode _ _ path; do
  [ -z "${path:-}" ] && continue
  # Only enforce on files that are actually meant to be run (have a shebang).
  first="$(head -n1 -- "$path" 2>/dev/null || true)"
  case "$first" in
    '#!'*) : ;;
    *) continue ;;
  esac
  if [ "$mode" != "100755" ]; then
    echo "FAIL(exec-bit): $path is tracked $mode, expected 100755 (git update-index --chmod=+x '$path')"
    fail=1
  fi
done < <(git ls-files -s -- '*.sh')

# --- Check 2: every plugins.txt marketplace has a setup.sh case arm ---------
PLUGIN_LIST="claude/plugins.txt"
SETUP="setup.sh"
if [ -f "$PLUGIN_LIST" ] && [ -f "$SETUP" ]; then
  # Same extraction setup.sh uses: trim, keep `plugin@marketplace` lines, take
  # the marketplace field, dedupe.
  while IFS= read -r mp; do
    [ -z "$mp" ] && continue
    if ! grep -Eq "^[[:space:]]*${mp}\)" "$SETUP"; then
      echo "FAIL(marketplace): '$mp' is referenced in $PLUGIN_LIST but has no registration arm in $SETUP"
      fail=1
    fi
  done < <(sed 's/[[:space:]]*$//; s/^[[:space:]]*//' "$PLUGIN_LIST" \
             | awk -F'@' '/^[^#[:space:]]/ && NF==2 {print $2}' \
             | sort -u)
fi

if [ "$fail" -eq 0 ]; then
  echo "check-install-integrity: OK (exec bits + marketplace arms)"
fi
exit "$fail"
