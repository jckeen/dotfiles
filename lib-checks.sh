# lib-checks.sh — shared link checker + report helpers (issue #199).
#
# SOURCED, never executed: no shebang (so check-install-integrity.sh's exec-bit
# rule doesn't apply) and mode 644 — the same pattern as lib-symlinks.sh.
# Source it relative to the sourcing script's own directory and HARD-FAIL with
# a clear message if it's missing (a partial checkout must not silently skip
# checks), e.g.:
#   if [ ! -f "$DOTFILES_DIR/lib-checks.sh" ]; then
#     echo "FATAL: $DOTFILES_DIR/lib-checks.sh is missing (broken checkout" \
#          "— restore it with 'git checkout lib-checks.sh')" >&2
#     exit 1
#   fi
#   source "$DOTFILES_DIR/lib-checks.sh"
#
# Before this, check_link and the red/yellow/green report helpers were written
# four times — check-claude.sh, check-codex.sh, check-antigravity.sh, and
# setup.sh's audit_link — and drifted (check-codex.sh lacked the "exists but
# is not a regular file" branch). This file is the single source of truth:
# the checkers consume check_link()/the report helpers, and setup.sh's
# audit_link consumes check_link_state() for state classification.
#
# check_link() communicates through the caller's globals (bash dynamic scope):
#   ERRORS / WARNINGS  — tallies, incremented per finding (callers init to 0)
#   HEAL / HEALED      — opt-in self-heal of MISSING links (default off)
#   CHECK_MISSING_HINT — location text for MISSING messages, e.g. "~/.claude/"
# shellcheck shell=bash

# Report helpers. ANSI colors are gated on a real TTY so piped/redirected
# output stays grep-friendly; a plain-text severity tag ([OK]/[WARN]/[ERR])
# is always prepended for non-TTY consumers.
if [ -t 1 ]; then
  c_red='\033[31m'; c_yellow='\033[33m'; c_green='\033[32m'; c_reset='\033[0m'
else
  c_red=''; c_yellow=''; c_green=''; c_reset=''
fi
red()    { echo -e "${c_red}[ERR] $1${c_reset}"; }
yellow() { echo -e "${c_yellow}[WARN] $1${c_reset}"; }
green()  { echo -e "${c_green}[OK] $1${c_reset}"; }

# warn_if_present <path> <label> — informational note for private/generated
# state that must stay local (never an error; shared by the Codex and
# Antigravity checkers).
warn_if_present() {
  local path="$1" label="$2"
  [ -e "$path" ] || return 0
  echo "LOCAL   $label exists; keep it private and out of public dotfiles"
}

# check_link_state <src> <dst> — classify a managed symlink destination.
# Echoes exactly one token (never fails):
#   OK               dst is a symlink to src and resolves
#   WRONG            dst is a symlink to something other than src
#   BROKEN           dst is a symlink to src but the target doesn't resolve
#   NOT_LINKED_FILE  dst exists as a regular file, not a symlink
#   NOT_LINKED_OTHER dst exists as some other type (directory, fifo, …)
#   MISSING          nothing exists at dst
# This is the state machine check_link() and setup.sh's audit_link share, so
# a new state (or a fixed branch) propagates to every consumer at once.
check_link_state() {
  local src="$1" dst="$2" target
  if [ -L "$dst" ]; then
    target="$(readlink "$dst")"
    if [ "$target" != "$src" ]; then
      echo WRONG
    elif [ ! -e "$dst" ]; then
      echo BROKEN
    else
      echo OK
    fi
  elif [ -f "$dst" ]; then
    echo NOT_LINKED_FILE
  elif [ -e "$dst" ]; then
    echo NOT_LINKED_OTHER
  else
    echo MISSING
  fi
}

# check_link <src> <dst> <label> — report on one managed symlink, updating the
# caller's ERRORS/WARNINGS (and HEALED when HEAL=1) tallies. Silent when the
# link is healthy. HEAL=1 opt-in (check-claude.sh --heal): auto-create MISSING
# links only — nothing exists at the destination, so creating the link clobbers
# nothing and the source is validated right before linking. Ambiguous states
# (NOT LINKED, WRONG, orphan) stay report-only, since those can be intentional
# divergence.
check_link() {
  local src="$1" dst="$2" label="$3" state target
  state="$(check_link_state "$src" "$dst")"
  case "$state" in
    OK) ;;
    WRONG)
      target="$(readlink "$dst")"
      red "WRONG  $label -> $target (expected $src)"
      ERRORS=$((ERRORS + 1))
      ;;
    BROKEN)
      target="$(readlink "$dst")"
      red "BROKEN $label -> $target (target missing)"
      ERRORS=$((ERRORS + 1))
      ;;
    NOT_LINKED_FILE)
      yellow "NOT LINKED  $label (exists but is a regular file, not a symlink)"
      WARNINGS=$((WARNINGS + 1))
      ;;
    NOT_LINKED_OTHER)
      # Some other path type (directory, fifo, …) sits where a symlink belongs.
      # Ambiguous — report, never heal: linking here would drop the symlink
      # *inside* a directory rather than create it at $dst.
      yellow "NOT LINKED  $label (exists but is not a symlink)"
      WARNINGS=$((WARNINGS + 1))
      ;;
    MISSING)
      if [ "${HEAL:-0}" -eq 1 ]; then
        # Guardrail self-heal: nothing exists at $dst, so linking clobbers
        # nothing. Re-validate the source right before linking (it could vanish
        # between the caller enumerating it and here) and confirm the link
        # resolves afterward, so a disappeared source or a racing run can't
        # yield a false HEALED.
        if [ ! -e "$src" ]; then
          yellow "MISSING  $label (source gone — run ./setup.sh)"
          WARNINGS=$((WARNINGS + 1))
        else
          mkdir -p "$(dirname "$dst")"
          ln -s "$src" "$dst" 2>/dev/null
          # Assert exactly what HEALED claims: $dst is a symlink to $src that
          # resolves. readlink==src rules out a racing run that linked
          # elsewhere; -e confirms it dereferences.
          if [ "$(readlink "$dst" 2>/dev/null)" = "$src" ] && [ -e "$dst" ]; then
            green "HEALED  $label (created missing symlink)"
            HEALED=$((HEALED + 1))
          else
            yellow "MISSING  $label (auto-link failed — run ./setup.sh)"
            WARNINGS=$((WARNINGS + 1))
          fi
        fi
      else
        yellow "MISSING  $label (not present in ${CHECK_MISSING_HINT:-the destination})"
        WARNINGS=$((WARNINGS + 1))
      fi
      ;;
  esac
}
