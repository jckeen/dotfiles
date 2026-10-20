#!/usr/bin/env bash
# statusline.test.sh — claude/statusline.sh renders under every bash the
# public settings template can hand it (#588). The template runs it as
# `bash "$HOME/.claude/statusline.sh"`, which on macOS is system bash 3.2, so
# the script must hold to the 3.2 floor (no readarray/mapfile, no printf
# %(…)T). Feeds a fixed status JSON from inside a throwaway git repo and
# asserts both lines and the ledger row, under:
#   - the default bash,
#   - `bash --posix`,
#   - $STATUSLINE_BASH3 when set (e.g. a bash 3.2.57 build; skipped cleanly
#     when unset, and the suite fails if that path is not bash 3.x).
# Plus a static scan for the bash 4+ builtins the script once used. Run
# directly; exit 1 on any failure.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STATUSLINE="$REPO_ROOT/claude/statusline.sh"

pass=0
failed=0
ok()   { pass=$((pass + 1));   echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

command -v jq >/dev/null 2>&1 || { echo "statusline: jq is required" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/hm" "$T/run" "$T/proj"
git -C "$T/proj" init -q -b sl-branch
git -C "$T/proj" -c user.name=t -c user.email=t@t.t commit -q --allow-empty -m init
INPUT="$(jq -nc --arg cwd "$T/proj" '{
  model: {display_name: "ModelX"},
  context_window: {used_percentage: 42, total_input_tokens: 1500, total_output_tokens: 20},
  cwd: $cwd, session_id: "sess-1",
  cost: {total_cost_usd: 0.5, total_duration_ms: 120000}
}')"

# render <label> <interpreter...> — run the status line and assert its output.
render() {
  local label="$1" out rc
  shift
  rm -rf "$T/hm/.claude" "$T/run"/*
  out="$(printf '%s' "$INPUT" | HOME="$T/hm" XDG_RUNTIME_DIR="$T/run" "$@" "$STATUSLINE" 2>"$T/err")"
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'ModelX' <<<"$out" && grep -q '42%' <<<"$out" \
    && grep -q 'sl-branch' <<<"$out" && ! [ -s "$T/err" ]; then
    ok "$label: renders model, context and branch with no stderr"
  else
    fail "$label: rc=$rc output/stderr wrong"
    sed 's/^/      | out: /' <<<"$out"
    sed 's/^/      | err: /' "$T/err"
  fi
  if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}	proj	0\.5	2$' "$T/hm/.claude/ledger/sess-1.tsv" 2>/dev/null; then
    ok "$label: writes the dated ledger row"
  else
    fail "$label: ledger row missing or malformed"
    sed 's/^/      | ledger: /' "$T/hm/.claude/ledger/sess-1.tsv" 2>/dev/null
  fi
}

render "default bash" bash
render "bash --posix" bash --posix

if [ -n "${STATUSLINE_BASH3:-}" ]; then
  if "$STATUSLINE_BASH3" -c '[[ "$BASH_VERSION" == 3.* ]]' 2>/dev/null; then
    render "bash $("$STATUSLINE_BASH3" -c 'echo "$BASH_VERSION"')" "$STATUSLINE_BASH3"
  else
    fail "STATUSLINE_BASH3=$STATUSLINE_BASH3 is not a bash 3.x interpreter"
  fi
else
  ok "bash 3.2 render skipped (STATUSLINE_BASH3 unset) # SKIP"
fi

# The git-info cache is keyed per directory. macOS has no md5sum, and a key
# that collapsed to one value would show one repo's status in every other, so
# with md5sum (and md5) hidden from PATH two repos must still get two keys.
FARM="$T/farm"
mkdir -p "$FARM"
IFS=: read -r -a _path_dirs <<<"$PATH"
for _d in "${_path_dirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    _b="${_f##*/}"
    case "$_b" in md5sum|md5) continue ;; esac
    [ -e "$FARM/$_b" ] || [ ! -x "$_f" ] || ln -s "$_f" "$FARM/$_b"
  done
done
mkdir -p "$T/proj2"
git -C "$T/proj2" init -q -b other
for _dir in "$T/proj" "$T/proj2"; do
  jq -nc --arg cwd "$_dir" '{model: {display_name: "M"}, cwd: $cwd}' \
    | HOME="$T/hm" XDG_RUNTIME_DIR="$T/run-nomd5" PATH="$FARM" bash "$STATUSLINE" >/dev/null 2>&1
done
_keys="$(find "$T/run-nomd5/claude-statusline" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ ! -e "$FARM/md5sum" ] && [ "$_keys" -eq 2 ]; then
  ok "without md5sum, two directories get two distinct status-line cache keys"
else
  fail "cache keys collided without md5sum ($_keys cache files for 2 dirs)"
fi

# Bash 4+ only: readarray/mapfile (4.0), printf %(fmt)T (4.2), associative
# arrays and namerefs (4.0/4.3), case-modifying expansions (4.0), |& and &>>.
if grep -nE '\b(readarray|mapfile)\b|%\([^)]*\)T|declare -[A-Za-z]*A|local -n|\$\{[A-Za-z_]+(,,|\^\^)|\|&|&>>' \
  "$STATUSLINE" | grep -v '^[0-9]*:[[:space:]]*#'; then
  fail "statusline.sh uses a bash 4+ feature (lines above)"
else
  ok "statusline.sh uses no bash 4+ builtins or expansions"
fi

echo ""
echo "statusline: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
