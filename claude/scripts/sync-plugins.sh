#!/usr/bin/env bash
# sync-plugins.sh — Install any plugins listed in the dotfiles plugin manifest
# that are not currently installed. Idempotent.
#
# Source of truth: $DOTFILES_DIR/claude/plugins.txt (one
# `<plugin>@<marketplace>` per line). The manifest stays in the dotfiles repo
# (setup.sh excludes it from symlinking; see check-claude.sh NOLINK).
# Triggered manually, or by the warning emitted by PluginDriftCheck.hook.ts.

set -eo pipefail

# Resolve the dotfiles repo via the real (symlink-resolved) path of this
# script: $DOTFILES_DIR/claude/scripts/sync-plugins.sh. Uses a portable
# resolution loop because BSD readlink (macOS) does not support `-f`.
resolve_script_path() {
  local target="$1"
  local dir
  while [[ -L "$target" ]]; do
    dir="$(cd -P "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    [[ "$target" != /* ]] && target="$dir/$target"
  done
  cd -P "$(dirname "$target")" && pwd
}
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MANIFEST="$DOTFILES_DIR/claude/plugins.txt"

if [[ ! -f "$MANIFEST" ]]; then
  echo "✘ Manifest not found: $MANIFEST" >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "✘ claude CLI not on PATH" >&2
  exit 1
fi

installed=()
failed=()

while IFS= read -r line; do
  p="${line%%#*}"
  p="${p// /}"
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
