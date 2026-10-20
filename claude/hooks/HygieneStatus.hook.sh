#!/usr/bin/env bash
# SessionStart hook: surface branch-hygiene drift if the daily systemd timer
# detected any. Thin wrapper — the actual logic is in hygiene-status.sh so
# both Claude (this hook) and Codex (check-codex.sh) can share it.
#
# The checkout can live anywhere (#588), so hygiene-status.sh is found, in
# order, at setup's ~/.local/bin link (§1c), then beside the checkout this
# hook links back to (claude/hooks/ -> repo root). Symlinks are resolved with
# a portable `cd -P` + readlink loop (no GNU-only `readlink -f`). If neither
# resolves, exit 0 silently: a missing reminder must never fail a session.

helper="$HOME/.local/bin/hygiene-status.sh"
if [ ! -x "$helper" ]; then
  target="${BASH_SOURCE[0]}"
  while [ -L "$target" ]; do
    dir="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd)" || exit 0
    target="$(readlink "$target")" || exit 0
    case "$target" in /*) ;; *) target="$dir/$target" ;; esac
  done
  hooks_dir="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd)" || exit 0
  helper="$hooks_dir/../../hygiene-status.sh"
  [ -x "$helper" ] || exit 0
fi

exec "$helper" --reminder
