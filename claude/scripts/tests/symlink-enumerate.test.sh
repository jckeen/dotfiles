#!/usr/bin/env bash
# symlink-enumerate.test.sh — fixture tests for lib-symlinks.sh's
# symlink_enumerate, focused on the scripts/ category: *.sh must be linked
# executable, *.json data files (gate schemas) must be linked plain, and docs
# must not be linked. Regression for the codex-review-gate.sh fail-open: the
# gate resolves its schema via plain dirname beside the script SYMLINK, so an
# unenumerated scripts/*.json is invisible to it at runtime.
set -uo pipefail

resolve_script_path() {
  local target="$1" dir
  while [[ -L "$target" ]]; do
    dir="$(cd -P "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    [[ "$target" != /* ]] && target="$dir/$target"
  done
  cd -P "$(dirname "$target")" && pwd
}
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
# shellcheck source=../../../lib-symlinks.sh
. "$SCRIPT_DIR/../../../lib-symlinks.sh"

pass=0
failed=0

check() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
  else
    echo "FAIL: $name" >&2
    failed=$((failed + 1))
  fi
}

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/claude/scripts"
: >"$FIX/claude/nolink.txt"
printf '#!/usr/bin/env bash\n' >"$FIX/claude/scripts/gate.sh"
printf '{}\n' >"$FIX/claude/scripts/gate-schema.json"
printf '# docs\n' >"$FIX/claude/scripts/README.md"

out="$(symlink_enumerate "$FIX/claude" "$HOME/.claude")"

# gate.sh linked with the executable flag
awk -F'\t' '$3 == "scripts/gate.sh" && $4 == "executable" { found = 1 } END { exit !found }' <<<"$out"
check "scripts/*.sh enumerated executable" $((1 - $?))

# gate-schema.json linked, WITHOUT the executable flag
awk -F'\t' '$3 == "scripts/gate-schema.json" && $4 == "" { found = 1 } END { exit !found }' <<<"$out"
check "scripts/*.json enumerated plain (gate schema reachable at runtime)" $((1 - $?))

# README.md under scripts/ must not be linked
! grep -q "scripts/README\.md" <<<"$out"
check "scripts/README.md not enumerated" $((1 - $?))

echo "symlink-enumerate: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
