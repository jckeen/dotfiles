#!/usr/bin/env bash
# sync-plugins.sh — Install any plugins listed in ~/.claude/plugins.txt
# that are not currently installed. Idempotent.
#
# Source of truth: ~/.claude/plugins.txt (one `<plugin>@<marketplace>` per line).
# Triggered manually, or by the warning emitted by PluginDriftCheck.hook.ts.

set -eo pipefail

MANIFEST="$HOME/.claude/plugins.txt"

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
