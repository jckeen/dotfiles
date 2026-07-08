#!/usr/bin/env bash
# check-doc-refs.sh — deterministic doc-reference drift-guard.
#
# Fails (exit 1) when a tracked Markdown doc references a hook or skill *file
# path* that does not exist on disk. Catches doc rot like the PAI decommission,
# where docs kept pointing at deleted hooks (PRWatcher*, PromptProcessing).
#
# Scope is deliberately narrow to avoid false positives on every PR:
#   - Hook refs:  <Word>.hook.ts / <Word>.hook.sh  → must exist in claude/hooks/
#   - Skill refs: (claude|codex)/skills/<name>/     → that dir must exist
# Bare slash-commands like /clear, /review are NOT treated as skill paths —
# many are built-in Claude commands, not repo dirs. Only explicit
# `skills/<name>/` path forms are checked.
#
# Historical docs that intentionally name removed files are excluded by path
# (CHANGELOG.md, SECURITY_FINDINGS_*.md, Plans/). Add more via ALLOWLIST below.
#
# Usage:  claude/scripts/check-doc-refs.sh
# Run from the repo root (CI checks out there); resolves its own repo root too.

set -euo pipefail

# --- Load shared helpers, then locate repo root via the real path -----
# This script is symlinked into ~/.claude/scripts, so $0/BASH_SOURCE may be a
# symlink. checker_repo_root (from checker-lib.sh) resolves it before walking up
# to the dotfiles checkout, or REPO_ROOT would point at ~/.claude and the guard
# would scan the wrong tree (false OK). The lib sits beside this script.
# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
REPO_ROOT="$(checker_repo_root "${BASH_SOURCE[0]}")"
cd "$REPO_ROOT"

HOOKS_DIR="claude/hooks"

# --- Allowlist: path globs whose docs may name removed files on purpose ---
# Matched against the doc path with bash [[ == glob ]].
ALLOWLIST=(
  "CHANGELOG.md"
  "SECURITY_FINDINGS_*.md"
  "Plans/*"
  "docs/adr/*"  # ADRs are append-only history; they name removed files on purpose
)

is_allowlisted() {
  local doc="$1" pat
  for pat in "${ALLOWLIST[@]}"; do
    # shellcheck disable=SC2053
    [[ "$doc" == $pat ]] && return 0
  done
  return 1
}

# --- Gather Markdown docs to scan ------------------------------
# Prefer git (only tracked files); fall back to find for non-git checkouts.
docs=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r f; do docs+=("$f"); done < <(git ls-files '*.md')
else
  while IFS= read -r f; do docs+=("${f#./}"); done \
    < <(find . -name '*.git' -prune -o -name '*.md' -print)
fi

broken=0

report() {
  # report <file> <line> <message>
  printf '%s:%s -> %s\n' "$1" "$2" "$3"
  broken=$((broken + 1))
}

# --- Scan each doc ---------------------------------------------
for doc in "${docs[@]}"; do
  is_allowlisted "$doc" && continue
  [[ -f "$doc" ]] || continue

  # Constant per doc — resolve once, not once per matched line.
  doc_dir="$(dirname "$doc")"

  while IFS=: read -r lineno content; do
    # 1) Hook references: <Word>.hook.ts / <Word>.hook.sh
    while read -r hook; do
      [[ -z "$hook" ]] && continue
      if [[ ! -f "$HOOKS_DIR/$hook" ]]; then
        report "$doc" "$lineno" "missing hook: $HOOKS_DIR/$hook"
      fi
    done < <(printf '%s\n' "$content" \
      | grep -oE '[A-Za-z0-9_-]+\.hook\.(ts|sh)' || true)

    # 2) Skill references: (claude|codex)/skills/<name>/
    while read -r ref; do
      [[ -z "$ref" ]] && continue
      # ref looks like "claude/skills/<name>/"; strip trailing slash for -d test.
      if [[ ! -d "${ref%/}" ]]; then
        report "$doc" "$lineno" "missing skill dir: ${ref%/}"
      fi
    done < <(printf '%s\n' "$content" \
      | grep -oE '(claude|codex)/skills/[A-Za-z0-9_-]+/' || true)

    # 3) Relative Markdown links: [text](path) pointing at a local file/dir.
    # Skip external URLs, in-page anchors, mailto/tel, and placeholder targets.
    while read -r link; do
      [[ -z "$link" ]] && continue
      target="$(printf '%s' "$link" | sed -E 's/.*\]\(([^)]+)\)/\1/')"
      target="${target%%#*}"                 # strip #anchor
      target="${target%% *}"                 # strip optional "title" after a space
      [[ -z "$target" ]] && continue          # pure in-page anchor
      case "$target" in
        *://*|mailto:*|tel:*|\#*) continue ;; # external / scheme / anchor
        *'<'*|*'$'*|*'{'*) continue ;;        # placeholder or template var
        /*) resolved="$REPO_ROOT$target" ;;   # repo-root-relative
        *)  resolved="$doc_dir/$target" ;;    # relative to the doc
      esac
      if [[ ! -e "$resolved" ]]; then
        report "$doc" "$lineno" "broken link: $target"
      fi
    done < <(printf '%s\n' "$content" \
      | grep -oE '\[[^]]*\]\([^)]+\)' || true)

  done < <(grep -nE '\.hook\.(ts|sh)|(claude|codex)/skills/[A-Za-z0-9_-]+/|\]\([^)]+\)' "$doc" || true)
done

# --- Verdict ---------------------------------------------------
if [[ "$broken" -gt 0 ]]; then
  echo "" >&2
  echo "doc-refs: $broken broken reference(s) found." >&2
  echo "Fix the doc, or add the path to the ALLOWLIST if the reference is intentionally historical." >&2
  exit 1
fi

echo "doc-refs: OK — all hook/skill references resolve."
