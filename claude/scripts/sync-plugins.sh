#!/usr/bin/env bash
# sync-plugins.sh — Install any plugins listed in the dotfiles plugin manifest
# that are not currently installed. Idempotent.
#
# Source of truth: $DOTFILES_DIR/claude/plugins.txt (one
# `<plugin>@<marketplace>` per line). The manifest stays in the dotfiles repo
# (setup.sh excludes it from symlinking; see check-claude.sh NOLINK).
# Triggered manually, or by the warning emitted by PluginDriftCheck.hook.ts.
#
# The manifest's `# [global]` / `# [per-project]` section markers (issue #214)
# are comments, stripped like any other: this script installs BOTH sections —
# that scoping governs enablement (settings.json `enabledPlugins`), not
# installation, and is checked by PluginDriftCheck.hook.ts, not here.
#
# INSTALL scope is a separate axis and does matter here: everything installs at
# user scope. A plugin someone installed with `--scope project` for one repo is
# that repo's, is deliberately absent from the manifest, and does not count as
# installed by the fast path below.

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

# Fast path: if every manifest plugin already has a USER-scope install, there is
# nothing to do — exit silently without touching the network. Keys in
# installed_plugins.json are the same `<plugin>@<marketplace>` strings as the
# manifest lines. This keeps the every-fresh-launch sync in cc() near-instant
# and quiet when there's no drift.
#
# Scope matters, and the rule mirrors PluginDriftCheck.hook.ts exactly: only a
# `--scope user` record satisfies the manifest, because this script installs at
# user scope and a fresh clone reproduces user scope only. `project` and
# `local` records belong to a checkout. Matching on the bare key would let the
# fast path exit 0 on a plugin the hook reports as missing — a warning whose
# suggested remedy (run this script) does nothing, every session.
#
# `user` is an allowlist, so an unrecognised scope asks for a redundant
# idempotent install rather than silently satisfying the manifest. Records
# whose shape we don't recognise (non-array value, or no string `scope`) count
# as installed, so an older installed_plugins.json behaves as before.
# Without python3 the fast path is skipped entirely rather than guessed at: the
# install loop below is idempotent, so the cost is launch latency, not
# correctness. python3 is already required by the pre-push receipt checker.
INSTALLED_JSON="$HOME/.claude/plugins/installed_plugins.json"
user_scoped=""
if [[ -f "$INSTALLED_JSON" ]] && command -v python3 >/dev/null 2>&1; then
  user_scoped="$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
plugins = data.get("plugins")
if not isinstance(plugins, dict):
    sys.exit(1)
for name, records in plugins.items():
    if not isinstance(records, list) or any(
        (not isinstance(r, dict)) or not isinstance(r.get("scope"), str)
        or r.get("scope") == "user"
        for r in records
    ):
        print(name)
' "$INSTALLED_JSON" 2>/dev/null)" || user_scoped=""
fi

if [[ -n "$user_scoped" ]]; then
  missing=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    p="${line%%#*}"
    p="${p//[[:space:]]/}"
    [[ -z "$p" ]] && continue
    if ! grep -qxF "$p" <<<"$user_scoped"; then
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
