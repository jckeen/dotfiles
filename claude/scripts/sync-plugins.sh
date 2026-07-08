#!/usr/bin/env bash
# sync-plugins.sh — Install any plugins listed in the dotfiles plugin manifest
# that are not currently installed. Idempotent.
#
# Source of truth: $DOTFILES_DIR/claude/plugins.txt (one
# `<plugin>@<marketplace>` per line). The manifest stays in the dotfiles repo
# (setup.sh excludes it from symlinking; see check-claude.sh NOLINK).
# Triggered manually, or by the warning emitted by PluginDriftCheck.hook.ts.

set -eo pipefail

# Resolve the dotfiles repo via the real (symlink-resolved) path of this script:
# $DOTFILES_DIR/claude/scripts/sync-plugins.sh. resolve_script_path (from
# checker-lib.sh, beside this script) uses a portable resolution loop because
# BSD readlink (macOS) does not support `-f`.
# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MANIFEST="$DOTFILES_DIR/claude/plugins.txt"

if [[ ! -f "$MANIFEST" ]]; then
  echo "✘ Manifest not found: $MANIFEST" >&2
  exit 1
fi

# Fast path: if every manifest plugin is already present in the installed
# manifest, there is nothing to do — exit silently without touching the network.
# Keys in installed_plugins.json are the same `<plugin>@<marketplace>` strings
# as the manifest lines (mirrors PluginDriftCheck.hook.ts). This keeps the
# every-fresh-launch sync in cc() near-instant and quiet when there's no drift.
INSTALLED_JSON="$HOME/.claude/plugins/installed_plugins.json"
if [[ -f "$INSTALLED_JSON" ]]; then
  missing=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    p="${line%%#*}"
    p="${p//[[:space:]]/}"
    [[ -z "$p" ]] && continue
    if ! grep -qF "\"$p\"" "$INSTALLED_JSON"; then
      missing=1
      break
    fi
  done < "$MANIFEST"
  if [[ "$missing" -eq 0 ]]; then
    exit 0
  fi
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "✘ claude CLI not on PATH" >&2
  exit 1
fi

installed=()
failed=()

while IFS= read -r line || [[ -n "$line" ]]; do
  p="${line%%#*}"
  # Strip all whitespace (spaces, tabs, and CR from CRLF line endings)
  p="${p//[[:space:]]/}"
  [[ -z "$p" ]] && continue
  echo "── $p"
  if claude plugin install "$p" 2>&1 | tail -1; then
    installed+=("$p")
  else
    failed+=("$p")
  fi
done < "$MANIFEST"

echo
echo "═══ DONE ═══"
echo "Processed: ${#installed[@]} ok, ${#failed[@]} failed"
if (( ${#failed[@]} > 0 )); then
  printf '  ✘ %s\n' "${failed[@]}"
  exit 1
fi
echo "Restart Claude Code to load any newly-installed plugins."
