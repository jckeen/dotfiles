#!/bin/bash
# Verify Claude Code config symlinks are healthy.
# Run from anywhere: ~/dev/dotfiles/check-claude.sh
# Checks for: broken links, unlinked files, orphaned links, stale backups.

set +e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SRC="$DOTFILES_DIR/claude"
CLAUDE_DST="$HOME/.claude"

# Shared symlink enumerator (issue #135) — the claude/ tree walk + nolink
# loading live in lib-symlinks.sh, shared with setup.sh so this checker can't
# drift from the installer. Resolved relative to THIS script's directory (this
# script is invoked via its real path), not the cwd.
# shellcheck source=lib-symlinks.sh
source "$DOTFILES_DIR/lib-symlinks.sh"

ERRORS=0
WARNINGS=0
FIXED=0
HEALED=0

# Flags:
#   --fix    auto-clean orphaned symlinks and stale backups (existing behavior)
#   --heal   auto-create MISSING links whose source exists. Guardrail: MISSING
#            only — nothing exists at the destination, so creating the link
#            clobbers nothing and the source is guaranteed present (callers only
#            iterate existing source files). Ambiguous states (NOT LINKED regular
#            file, WRONG target, orphan) stay report-only, since those can be
#            intentional divergence. `cc` passes --heal at launch so startup
#            self-heals the safe case without prompting; standalone runs stay
#            pure reporters.
FIX=0
HEAL=0
for arg in "$@"; do
  case "$arg" in
    --fix)  FIX=1 ;;
    --heal) HEAL=1 ;;
  esac
done

# Gate ANSI colors on a real TTY so piped/redirected output stays grep-friendly.
if [ -t 1 ]; then
  c_red='\033[31m'; c_yellow='\033[33m'; c_green='\033[32m'; c_reset='\033[0m'
else
  c_red=''; c_yellow=''; c_green=''; c_reset=''
fi

# Severity helpers prepend a plain-text tag ([OK]/[WARN]/[ERR]) for non-TTY consumers.
red()    { echo -e "${c_red}[ERR] $1${c_reset}"; }
yellow() { echo -e "${c_yellow}[WARN] $1${c_reset}"; }
green()  { echo -e "${c_green}[OK] $1${c_reset}"; }

check_link() {
  local src="$1" dst="$2" label="$3"
  if [ -L "$dst" ]; then
    local target
    target="$(readlink "$dst")"
    if [ "$target" != "$src" ]; then
      red "WRONG  $label -> $target (expected $src)"
      ERRORS=$((ERRORS + 1))
    elif [ ! -e "$dst" ]; then
      red "BROKEN $label -> $target (target missing)"
      ERRORS=$((ERRORS + 1))
    fi
  elif [ -f "$dst" ]; then
    yellow "NOT LINKED  $label (exists but is a regular file, not a symlink)"
    WARNINGS=$((WARNINGS + 1))
  elif [ -e "$dst" ]; then
    # Some other path type (directory, fifo, …) sits where a symlink belongs.
    # $dst is not a symlink (handled above) and not a regular file, yet exists.
    # Ambiguous — report, never heal: linking here would drop the symlink
    # *inside* a directory rather than create it at $dst.
    yellow "NOT LINKED  $label (exists but is not a symlink)"
    WARNINGS=$((WARNINGS + 1))
  elif [ "$HEAL" -eq 1 ]; then
    # Guardrail self-heal: nothing exists at $dst, so linking clobbers nothing.
    # Re-validate the source right before linking (it could vanish between the
    # caller enumerating it and here) and confirm the link resolves afterward,
    # so a disappeared source or a racing run can't yield a false HEALED.
    if [ ! -e "$src" ]; then
      yellow "MISSING  $label (source gone — run ./setup.sh)"
      WARNINGS=$((WARNINGS + 1))
    else
      mkdir -p "$(dirname "$dst")"
      ln -s "$src" "$dst" 2>/dev/null
      # Assert exactly what HEALED claims: $dst is a symlink to $src that
      # resolves. readlink==src rules out a racing run that linked elsewhere
      # (reported as a WRONG target on the next read-only check); -e confirms
      # it dereferences.
      if [ "$(readlink "$dst" 2>/dev/null)" = "$src" ] && [ -e "$dst" ]; then
        green "HEALED  $label (created missing symlink)"
        HEALED=$((HEALED + 1))
      else
        yellow "MISSING  $label (auto-link failed — run ./setup.sh)"
        WARNINGS=$((WARNINGS + 1))
      fi
    fi
  else
    yellow "MISSING  $label (not present in ~/.claude/)"
    WARNINGS=$((WARNINGS + 1))
  fi
}

echo "Checking Claude Code config..."
echo ""

# The nolink manifest is the single source of truth (no fallback). If it's
# missing the enumerator can't tell which files to skip, so fail loudly.
if ! symlink_require_manifest "$CLAUDE_SRC"; then
  red "claude/nolink.txt missing at $CLAUDE_SRC/nolink.txt — cannot audit"
  exit 1
fi

# Memory repo check
echo "Checking memory repo..."
# Derive dev dir from dotfiles repo location (parent of this repo)
DEV_DIR="$(dirname "$DOTFILES_DIR")"
MEMORY_REPO="$DEV_DIR/claude-memory"
MEMORY_PROJECT_DIR="$(echo "$DEV_DIR" | sed 's|^/||; s|/|-|g')"
MEMORY_DST="$CLAUDE_DST/projects/-${MEMORY_PROJECT_DIR}/memory"

if [ -L "$MEMORY_DST" ]; then
  if [ ! -e "$MEMORY_DST" ]; then
    red "BROKEN  memory -> $(readlink "$MEMORY_DST") (target missing)"
    ERRORS=$((ERRORS + 1))
  fi
elif [ -d "$MEMORY_DST" ]; then
  yellow "NOT LINKED  memory (exists as directory, not symlink — run setup.sh)"
  WARNINGS=$((WARNINGS + 1))
elif [ -d "$MEMORY_REPO" ]; then
  yellow "MISSING  memory symlink (repo exists but not linked — run setup.sh)"
  WARNINGS=$((WARNINGS + 1))
fi
echo ""

# Walk the whole claude/ tree from the shared enumerator (lib-symlinks.sh):
# top-level (nolink-filtered) → hooks → skills → agents → scripts → chrome.
# One source of truth with setup.sh's installer and audit. The executable flag
# (4th field) is unused here — this checker reports link state, not +x drift.
while IFS=$'\t' read -r src dst label _flags; do
  [ -n "$src" ] || continue
  check_link "$src" "$dst" "$label"
done < <(symlink_enumerate "$CLAUDE_SRC" "$CLAUDE_DST")

# Check for orphaned symlinks — symlinks in ~/.claude/ pointing into dotfiles
# whose source was removed (e.g., AgentPack.md after we stopped linking it)
echo ""
echo "Checking for orphaned symlinks..."
while IFS= read -r link; do
  target="$(readlink "$link")"
  # Only check symlinks that point into our dotfiles repo
  if [[ "$target" == "$DOTFILES_DIR"* ]] && [ ! -e "$link" ]; then
    label="${link#$CLAUDE_DST/}"
    if [ "$FIX" -eq 1 ]; then
      rm "$link"
      green "CLEANED  $label (removed orphaned link -> $target)"
      FIXED=$((FIXED + 1))
    else
      red "ORPHAN  $label -> $target (source removed from dotfiles)"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done < <(find "$CLAUDE_DST" -maxdepth 3 -type l 2>/dev/null)

# Check for broken symlinks (pointing elsewhere, not into dotfiles)
echo ""
echo "Checking for broken symlinks..."
while IFS= read -r broken; do
  target="$(readlink "$broken")"
  # Skip dotfiles-managed links (already handled above)
  [[ "$target" == "$DOTFILES_DIR"* ]] && continue
  red "BROKEN  $broken -> $target"
  ERRORS=$((ERRORS + 1))
done < <(find "$CLAUDE_DST" -maxdepth 3 -xtype l 2>/dev/null)

# Check for stale backup files created by setup.sh's link_file()
# Only flags .backup files where a working symlink exists for the original
echo ""
echo "Checking for stale backups..."
while IFS= read -r backup; do
  original="${backup%.backup}"
  # Only flag if the non-backup version exists and is a working symlink
  # (meaning setup.sh already replaced it successfully)
  if [ -L "$original" ] && [ -e "$original" ]; then
    if [ "$FIX" -eq 1 ]; then
      rm "$backup"
      green "CLEANED  $backup"
      FIXED=$((FIXED + 1))
    else
      yellow "STALE   $backup"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
done < <(find "$CLAUDE_DST" -maxdepth 3 -name "*.backup" 2>/dev/null)

# Branch hygiene status (silent if clean)
if [ -x "$DOTFILES_DIR/hygiene-status.sh" ]; then
  "$DOTFILES_DIR/hygiene-status.sh" --cli || true
fi

# Hook-wiring drift (silent if clean): warn when a hook file exists but isn't
# registered in settings.json — the failure mode that left every hook inert.
if [ -x "$DOTFILES_DIR/claude/scripts/check-hooks-wired.sh" ]; then
  "$DOTFILES_DIR/claude/scripts/check-hooks-wired.sh" --quiet || true
fi

# Summary
echo ""
[ $HEALED -gt 0 ] && green "Self-healed $HEALED missing link(s)."
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
  green "All good. Claude config is in sync."
  [ $FIXED -gt 0 ] && green "Cleaned up $FIXED item(s)."
  exit 0
else
  [ $ERRORS -gt 0 ] && red "$ERRORS error(s) found."
  [ $WARNINGS -gt 0 ] && yellow "$WARNINGS warning(s) found."
  echo ""
  echo "Run './check-claude.sh --fix' to auto-clean orphans and backups."
  echo "Run './setup.sh' to recreate missing links."
  exit 1
fi
