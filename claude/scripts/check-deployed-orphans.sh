#!/usr/bin/env bash
# check-deployed-orphans.sh — sweep the DEPLOYED ~/.claude for decommissioned
# artifacts (issue #215).
#
# check-claude.sh audits the symlink farm (broken/wrong/orphaned links) but
# never looks at REGULAR files squatting in ~/.claude — exactly where a
# decommissioned integration leaves debris. ADR-0002 removed PAI, yet its hook
# framework (hooks/handlers/, hooks/lib/, hooks/security/, a 25KB
# hooks/README.md) survived as regular files, alongside
# settings.json.doctor-bak and an empty commands/ dir.
#
# What is legitimate in ~/.claude:
#   - symlinks — into ~/dev/dotfiles or ~/dev/claude-memory; their health
#     (broken/wrong/orphan) is check-claude.sh's job, so ANY symlink is
#     skipped here
#   - runtime state Claude Code itself writes (projects/, tasks/, plugins/,
#     shell-snapshots/, …) — the allowlists below
#
# Checks:
#   1. hooks/ debris     — any non-symlink entry in ~/.claude/hooks/
#                          (dotfiles-managed hooks are symlinks; a regular file
#                          there is unexpected — possibly PAI-era, ADR-0002)
#   2. settings backups  — settings.json.doctor-bak / *.doctor-bak at top level
#   3. empty commands/   — the dir survives holding nothing but a .gitignore
#                          (slash commands migrated to skills/)
#   4. unknown top-level — not a symlink, not known runtime state: reported as
#                          UNKNOWN for a human to triage; never fails --strict
#                          (new Claude Code versions grow new runtime dirs)
#
# Usage: check-deployed-orphans.sh [--strict]
#   default   report findings and exit 0 (safe for cron/status hooks)
#   --strict  exit 1 when any orphan (checks 1-3) is found
# Env: CLAUDE_DIR overrides ~/.claude (used by the fixture self-test:
#      tests/deployed-orphans.test.sh).

set -uo pipefail

# Shared helpers (yellow/green printers). Sits beside this script both in the
# repo and in ~/.claude/scripts (setup.sh links them side-by-side). Hard-fail
# if it's missing: under `set +e` a failed source would otherwise keep going
# and sweep with the helpers undefined (issue #230).
_LIB="$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
if [ ! -f "$_LIB" ]; then
  echo "FATAL: $_LIB is missing (broken checkout — restore it with 'git checkout claude/scripts/checker-lib.sh')" >&2
  exit 1
fi
# shellcheck source=claude/scripts/checker-lib.sh
. "$_LIB"

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    *) echo "check-deployed-orphans: unknown flag '$arg' (usage: [--strict])" >&2; exit 2 ;;
  esac
done

if [ ! -d "$CLAUDE_DIR" ]; then
  echo "check-deployed-orphans: $CLAUDE_DIR not found — nothing deployed to audit" >&2
  exit 1
fi

# Runtime state Claude Code (and the deployed tooling) writes itself. Top-level
# entries in this list are never flagged. Enumerated from a live ~/.claude plus
# what setup.sh/check-claude.sh manage as real directories-of-symlinks
# (agents/, skills/, scripts/, chrome/, hooks/).
RUNTIME_DIRS=(
  Plans agents backups cache chrome commands daemon downloads file-history
  handoffs hooks ide jobs ledger logs paste-cache plugins projects
  retro-proposals scripts security session-env sessions shell-snapshots
  skills statsig tasks teams test-results todos uploads worktrees
)
RUNTIME_FILES=(
  .DS_Store .credentials.json .gitattributes .gitignore .gitmodules
  .last-cleanup .last-update-result.json .lsp.json .mcp.json LICENSE
  daemon.log dev-dir history.jsonl mcp-needs-auth-cache.json
  # operator-queue.md: durable operator-action queue (PR #223) — written by
  # handoffs, read by OperatorQueueReminder.hook.sh.
  operator-queue.md
  settings.local.json
)

in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

ORPHANS=0
UNKNOWNS=0
orphan() { yellow "ORPHAN  $1"; ORPHANS=$((ORPHANS + 1)); }

echo "Checking deployed $CLAUDE_DIR for decommissioned artifacts..."

# --- 1. hooks/ debris: non-symlink entries -----------------------------------
if [ -d "$CLAUDE_DIR/hooks" ]; then
  while IFS= read -r entry; do
    name="${entry#"$CLAUDE_DIR"/}"
    if [ -d "$entry" ]; then
      count="$(find "$entry" -type f 2>/dev/null | wc -l | tr -d ' ')"
      orphan "$name/ — unexpected regular directory ($count file(s)) in hooks/; dotfiles-managed hooks are symlinks (possibly PAI-era, see ADR-0002)"
    else
      orphan "$name — unexpected regular file in hooks/; dotfiles-managed hooks are symlinks (possibly PAI-era, see ADR-0002)"
    fi
  done < <(find "$CLAUDE_DIR/hooks" -mindepth 1 -maxdepth 1 ! -type l 2>/dev/null | sort)
fi

# --- 2. settings backup files -------------------------------------------------
while IFS= read -r entry; do
  name="${entry#"$CLAUDE_DIR"/}"
  orphan "$name — stale settings backup (the live settings.json is symlinked from claude-memory)"
done < <(find "$CLAUDE_DIR" -mindepth 1 -maxdepth 1 ! -type l \
           \( -name 'settings.json.*bak*' -o -name '*.doctor-bak' \) 2>/dev/null | sort)

# --- 3. empty commands/ dir ---------------------------------------------------
if [ -d "$CLAUDE_DIR/commands" ] && [ ! -L "$CLAUDE_DIR/commands" ]; then
  remaining="$(find "$CLAUDE_DIR/commands" -mindepth 1 ! -name '.gitignore' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$remaining" -eq 0 ]; then
    orphan "commands/ — empty (slash commands migrated to skills/); safe to remove"
  fi
fi

# --- 4. unknown top-level entries (informational, never fails --strict) ------
while IFS= read -r entry; do
  name="${entry#"$CLAUDE_DIR"/}"
  # Symlinks are check-claude.sh's domain; skip.
  [ -L "$entry" ] && continue
  # Already reported by check 2.
  case "$name" in settings.json.*bak* | *.doctor-bak) continue ;; esac
  if [ -d "$entry" ]; then
    in_list "$name" "${RUNTIME_DIRS[@]}" && continue
  else
    in_list "$name" "${RUNTIME_FILES[@]}" && continue
  fi
  yellow "UNKNOWN $name — not a symlink and not known runtime state; triage manually"
  UNKNOWNS=$((UNKNOWNS + 1))
done < <(find "$CLAUDE_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | sort)

# --- Summary ------------------------------------------------------------------
echo ""
if [ "$ORPHANS" -eq 0 ] && [ "$UNKNOWNS" -eq 0 ]; then
  green "No decommissioned artifacts found in $CLAUDE_DIR."
else
  [ "$ORPHANS" -gt 0 ] && yellow "$ORPHANS orphan(s) from decommissioned integrations. Back up first (tar czf), verify (tar tzf), then delete."
  [ "$UNKNOWNS" -gt 0 ] && yellow "$UNKNOWNS unknown top-level entr(y/ies) — triage manually (does not fail --strict)."
fi

if [ "$STRICT" -eq 1 ] && [ "$ORPHANS" -gt 0 ]; then
  exit 1
fi
exit 0
