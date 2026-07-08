#!/usr/bin/env bash
# checker-lib.sh — shared helpers for the dotfiles checker scripts.
#
# Sourced (never executed) by the dotfiles-local checkers and their self-tests
# to remove the copy-pasted resolve_script_path() blocks (~13 copies) and the
# per-script colored-helper + violation-counter reinventions.
#
# NOT sourced by check-doc-truth.sh: that checker is vendored verbatim into other
# repos by /drift-sweep and must stay dependency-free / standalone.
#
# Locating this file: a caller cannot call resolve_script_path (defined here)
# before it has sourced this file, so it sources us via its own directory —
#   . "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
# which resolves because setup.sh symlinks every claude/scripts/*.sh (this file
# included) side-by-side into ~/.claude/scripts, and the self-tests copy this
# file into their fixture's claude/scripts/ next to the checker under test.

# shellcheck shell=bash

# resolve_script_path <path> — echo the real directory containing <path>,
# following symlinks. Portable: BSD readlink (macOS) has no -f.
resolve_script_path() {
  local target="$1" dir
  while [ -L "$target" ]; do
    dir="$(cd -P "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    case "$target" in /*) ;; *) target="$dir/$target" ;; esac
  done
  cd -P "$(dirname "$target")" && pwd
}

# checker_repo_root <path> — echo the dotfiles repo root, two levels up from the
# resolved directory of <path> (claude/scripts/foo.sh -> repo root).
checker_repo_root() {
  local dir
  dir="$(resolve_script_path "$1")"
  cd "$dir/../.." && pwd
}

# ── Colored line printers + violation counter ──────────────────────
# red() is the "fail" helper: it prints an error line AND bumps VIOLATIONS, so a
# checker can end with:  [ "$VIOLATIONS" -eq 0 ] || exit 1
VIOLATIONS=0
red()    { printf '\033[31m[ERR] %s\033[0m\n' "$1"; VIOLATIONS=$((VIOLATIONS + 1)); }
green()  { printf '\033[32m[OK] %s\033[0m\n' "$1"; }
yellow() { printf '\033[33m[WARN] %s\033[0m\n' "$1"; }
