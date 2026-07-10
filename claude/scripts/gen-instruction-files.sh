#!/usr/bin/env bash
# gen-instruction-files.sh — build the three global instruction files from the
# canonical shared-rules source (ADR-0007).
#
# Sources:
#   agents/canon/CANON.md            — shared rule blocks, delimited by
#                                      <!-- canon:ID --> … <!-- /canon:ID -->
#   agents/canon/fragments/<tool>.md — per-tool skeleton; a line of the exact
#                                      form <!-- include:ID --> is replaced by
#                                      that canon block's content
#
# Targets (committed build artifacts — setup.sh symlinks them unchanged):
#   claude/CLAUDE.md, codex/AGENTS.md, antigravity/GEMINI.md
#
# Native imports are not universal — Codex and Antigravity resolve no include
# syntax in their instruction files (evidence in ADR-0007) — so shared rules
# are compiled in at build time rather than imported at load time. A banner
# comment marks each output; check-agent-parity.sh runs this in --check mode
# in CI, so hand-edits to a generated file fail the build.
#
# Usage:
#   gen-instruction-files.sh          # regenerate the three files in place
#   gen-instruction-files.sh --check  # exit 1 if any target is stale
#
# Fails on: unknown include id, canon block included by no fragment, nested or
# unclosed canon blocks, duplicate block ids, missing sources.

set -euo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
REPO_ROOT="$(checker_repo_root "${BASH_SOURCE[0]}")"
cd "$REPO_ROOT"

CANON="agents/canon/CANON.md"
FRAG_DIR="agents/canon/fragments"
TOOLS=(claude codex antigravity)
declare -A TARGET=(
  [claude]="claude/CLAUDE.md"
  [codex]="codex/AGENTS.md"
  [antigravity]="antigravity/GEMINI.md"
)

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

[[ -f "$CANON" ]] || { echo "✖ gen: missing $CANON" >&2; exit 1; }
for tool in "${TOOLS[@]}"; do
  [[ -f "$FRAG_DIR/$tool.md" ]] \
    || { echo "✖ gen: missing $FRAG_DIR/$tool.md" >&2; exit 1; }
done

# --- Parse canon blocks ------------------------------------------------
declare -A BLOCK USED
open_re='^<!-- canon:([a-z0-9-]+) -->$'
close_re='^<!-- /canon:([a-z0-9-]+) -->$'
current=""
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  if [[ "$line" =~ $open_re ]]; then
    id="${BASH_REMATCH[1]}"
    [[ -z "$current" ]] \
      || { echo "✖ gen: $CANON:$lineno — block '$id' opened inside '$current'" >&2; exit 1; }
    [[ -z "${BLOCK[$id]+x}" ]] \
      || { echo "✖ gen: $CANON:$lineno — duplicate block '$id'" >&2; exit 1; }
    current="$id"
    BLOCK[$id]=""
    continue
  fi
  if [[ "$line" =~ $close_re ]]; then
    [[ "$current" == "${BASH_REMATCH[1]}" ]] \
      || { echo "✖ gen: $CANON:$lineno — close '${BASH_REMATCH[1]}' doesn't match open '$current'" >&2; exit 1; }
    current=""
    continue
  fi
  [[ -n "$current" ]] && BLOCK[$current]+="$line"$'\n'
done < "$CANON"
[[ -z "$current" ]] \
  || { echo "✖ gen: $CANON — block '$current' never closed" >&2; exit 1; }

# --- Render one fragment to stdout -------------------------------------
include_re='^<!-- include:([a-z0-9-]+) -->$'
render() { # tool
  local tool="$1" frag="$FRAG_DIR/$1.md" ln=0 line id
  printf '%s\n' \
    '<!-- GENERATED FILE (ADR-0007) — do not edit directly.' \
    "     Sources: agents/canon/CANON.md + agents/canon/fragments/$tool.md" \
    '     Regenerate: claude/scripts/gen-instruction-files.sh -->' \
    ''
  while IFS= read -r line || [[ -n "$line" ]]; do
    ln=$((ln + 1))
    if [[ "$line" =~ $include_re ]]; then
      id="${BASH_REMATCH[1]}"
      [[ -n "${BLOCK[$id]+x}" ]] \
        || { echo "✖ gen: $frag:$ln — unknown canon block '$id'" >&2; return 1; }
      USED[$id]=1
      printf '%s' "${BLOCK[$id]}"
    else
      printf '%s\n' "$line"
    fi
  done < "$frag"
}

# --- Generate (or check) each target -----------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stale=()
for tool in "${TOOLS[@]}"; do
  out="$tmp/$tool.md"
  render "$tool" > "$out"
  target="${TARGET[$tool]}"
  # A marker that didn't parse — trailing space, wrong case, or an include
  # line sitting inside a canon block — would otherwise ship LITERALLY in the
  # instruction file with rc=0: a shared rule silently reaching no agent,
  # ADR-0007's named worst failure mode. Fail loudly instead.
  if grep -nE '<!-- (include|canon):' "$out" > "$tmp/$tool.leak"; then
    echo "✖ gen: unexpanded canon/include marker would ship in $target:" >&2
    sed 's/^/    /' "$tmp/$tool.leak" >&2
    echo "  A marker must be a full line of exactly '<!-- include:ID -->' in a fragment." >&2
    exit 1
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    if ! diff -u "$target" "$out" > "$tmp/$tool.diff" 2>&1; then
      stale+=("$target")
      sed "s|^|  |" "$tmp/$tool.diff" | head -20 >&2
    fi
  else
    mkdir -p "$(dirname "$target")"
    cp "$out" "$target"
    echo "  -> generated $target"
  fi
done

# Every canon block must be included by at least one fragment — an orphaned
# block is a shared rule that silently reaches no agent.
for id in "${!BLOCK[@]}"; do
  [[ -n "${USED[$id]+x}" ]] \
    || { echo "✖ gen: canon block '$id' is not included by any fragment" >&2; exit 1; }
done

if [[ "$CHECK" -eq 1 ]]; then
  if [[ "${#stale[@]}" -gt 0 ]]; then
    echo "✖ gen: generated instruction files are stale or hand-edited: ${stale[*]}" >&2
    echo "  Edit agents/canon/ sources, then run claude/scripts/gen-instruction-files.sh" >&2
    exit 1
  fi
  echo "✓ gen: claude/CLAUDE.md, codex/AGENTS.md, antigravity/GEMINI.md are byte-current with agents/canon/"
fi
