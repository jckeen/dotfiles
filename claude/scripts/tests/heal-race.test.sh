#!/usr/bin/env bash
# heal-race.test.sh — regression for issue #603: two launchers running
# check-claude.sh --heal at once. Both see a skill link MISSING; the loser's
# plain `ln -s` then followed the directory link the winner had just made and
# dropped a self-link INSIDE the source bundle (<bundle>/<name> -> <bundle>),
# which the checker could not see. Covers: the heal path never nests (ln -sn),
# the SELFLINK check and its --fix, and a migration that a concurrent run
# finished first is not reported as FAILED. Fixture-driven: the checker and its
# libs are copied into a throwaway repo so DOTFILES_DIR resolves there, and
# HOME points at a throwaway tree. Mirrors check-tests-wired.test.sh.
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
REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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

# new_fixture <name> — a repo copy at $R with one skill bundle, and an empty
# HOME at $H. Only the files check-claude.sh sources are copied, so the
# enumerator sees exactly: nolink.txt (filtered), skills/demo, and the two
# retired-skill-links helpers under scripts/.
new_fixture() {
  R="$FIX/$1/dotfiles"
  H="$FIX/$1/home"
  mkdir -p "$R/claude/scripts" "$R/claude/skills/demo" "$H/.claude"
  cp "$REPO/check-claude.sh" "$REPO/lib-symlinks.sh" "$REPO/lib-checks.sh" "$R/"
  cp "$REPO/claude/scripts/retired-skill-links.sh" \
     "$REPO/claude/scripts/retired-skill-links.py" "$R/claude/scripts/"
  printf 'nolink.txt\n' > "$R/claude/nolink.txt"
  printf '# demo\n' > "$R/claude/skills/demo/SKILL.md"
  SRC="$R/claude/skills/demo"
  DST="$H/.claude/skills/demo"
}
run_check() { HOME="$H" "$R/check-claude.sh" "$@" 2>&1; }

# ── 1. --heal on a fresh HOME links the bundle as one directory link ─────
new_fixture fresh
out="$(run_check --heal)"; rc=$?
check "fresh HOME: --heal exits 0" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
check "fresh HOME: skills/demo HEALED" "$(grep -q 'HEALED  skills/demo' <<<"$out" && echo 1 || echo 0)"
check "fresh HOME: destination is a link to the bundle" \
  "$([ -L "$DST" ] && [ "$(readlink "$DST")" = "$SRC" ] && echo 1 || echo 0)"
check "fresh HOME: nothing nested inside the bundle" \
  "$([ ! -e "$SRC/demo" ] && [ ! -L "$SRC/demo" ] && echo 1 || echo 0)"

# ── 2. the SELFLINK check sees a nested self-link; --fix removes it ──────
ln -s "$SRC" "$SRC/demo"
out="$(run_check)"; rc=$?
check "self-link: checker exits 1" "$([ "$rc" -eq 1 ] && echo 1 || echo 0)"
check "self-link: reported as SELFLINK" \
  "$(grep -q 'SELFLINK  skills/demo/demo -> ' <<<"$out" && echo 1 || echo 0)"
check "self-link: report-only run leaves it in place" "$([ -L "$SRC/demo" ] && echo 1 || echo 0)"
out="$(run_check --fix)"; rc=$?
check "self-link: --fix exits 0" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
check "self-link: --fix reports CLEANED" \
  "$(grep -q 'CLEANED  skills/demo/demo' <<<"$out" && echo 1 || echo 0)"
check "self-link: --fix removed it" "$([ ! -L "$SRC/demo" ] && echo 1 || echo 0)"
check "self-link: --fix kept the bundle and its link" \
  "$([ -f "$SRC/SKILL.md" ] && [ "$(readlink "$DST")" = "$SRC" ] && echo 1 || echo 0)"
out="$(run_check)"; rc=$?
check "self-link: clean after --fix" "$([ "$rc" -eq 0 ] && grep -q 'All good' <<<"$out" && echo 1 || echo 0)"

# --fix must not claim CLEANED when the removal fails (read-only bundle).
# Root ignores directory write bits, so the case is skipped there.
if [ "$(id -u)" -ne 0 ]; then
  ln -s "$SRC" "$SRC/demo"
  chmod a-w "$SRC"
  out="$(run_check --fix)"; rc=$?
  chmod u+w "$SRC"
  check "self-link: --fix on a read-only bundle exits 1" "$([ "$rc" -eq 1 ] && echo 1 || echo 0)"
  check "self-link: --fix on a read-only bundle reports FAILED, not CLEANED" \
    "$(grep -q 'FAILED  skills/demo/demo' <<<"$out" && ! grep -q CLEANED <<<"$out" && echo 1 || echo 0)"
  check "self-link: --fix on a read-only bundle left it in place" "$([ -L "$SRC/demo" ] && echo 1 || echo 0)"
  rm "$SRC/demo"
fi

# A link to somewhere else inside a bundle is not a self-link (e.g. a skill
# that links a shared reference); the check must leave it alone.
ln -s "$R/claude/nolink.txt" "$SRC/shared.txt"
out="$(run_check)"; rc=$?
check "foreign link inside a bundle is not SELFLINK" \
  "$([ "$rc" -eq 0 ] && ! grep -q SELFLINK <<<"$out" && echo 1 || echo 0)"
rm "$SRC/shared.txt"

# ── 3. the heal path itself cannot nest, even when it loses the race ─────
# Reproduce the window: check_link_state said MISSING, but by the time ln
# runs the other launcher has linked the directory. First prove the platform
# behavior the fix guards against, then drive check_link through it.
ln -s "$SRC" "$FIX/plain" && ln -s "$SRC" "$FIX/plain" 2>/dev/null
check "platform: plain ln -s into an existing dir link nests" \
  "$([ -L "$SRC/demo" ] && echo 1 || echo 0)"
rm -f "$SRC/demo" "$FIX/plain"
(
  # shellcheck source=../../../lib-checks.sh
  . "$R/lib-checks.sh"
  # shellcheck disable=SC2329  # called by check_link, which is sourced above
  check_link_state() { echo MISSING; }
  # shellcheck disable=SC2034  # read by the sourced check_link
  HEAL=1 ERRORS=0 WARNINGS=0 HEALED=0
  check_link "$SRC" "$DST" "skills/demo" >/dev/null
  [ ! -e "$SRC/demo" ] && [ ! -L "$SRC/demo" ] || exit 1
  [ "$(readlink "$DST")" = "$SRC" ] || exit 2
  [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ] || exit 3
)
rc=$?
check "heal into an existing correct link: nothing nested" "$([ "$rc" -ne 1 ] && echo 1 || echo 0)"
check "heal into an existing correct link: link still correct" "$([ "$rc" -ne 2 ] && echo 1 || echo 0)"
check "heal into an existing correct link: no error or warning" "$([ "$rc" -ne 3 ] && echo 1 || echo 0)"

# ── 4. a legacy conversion the other launcher finished first is not FAILED ─
new_fixture legacy
mkdir -p "$DST"
ln -s "$SRC/SKILL.md" "$DST/SKILL.md"
# Interpose on the fixture's copy only: the winner converts and links the
# directory right before this run's migration, which then finds nothing left
# to remove and returns 1.
cat >> "$R/lib-symlinks.sh" <<'SHIM'
eval "orig_$(declare -f symlink_migrate_legacy_skill_dir)"
symlink_migrate_legacy_skill_dir() {
  rm "$2"/* && rmdir "$2" && ln -sn "$1" "$2"
  orig_symlink_migrate_legacy_skill_dir "$@"
}
SHIM
out="$(run_check --heal)"; rc=$?
check "lost migration race: --heal exits 0" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
check "lost migration race: not reported FAILED" "$(! grep -q 'FAILED' <<<"$out" && echo 1 || echo 0)"
check "lost migration race: directory link in place" \
  "$([ "$(readlink "$DST")" = "$SRC" ] && [ -f "$DST/SKILL.md" ] && echo 1 || echo 0)"
check "lost migration race: nothing nested" "$([ ! -L "$SRC/demo" ] && echo 1 || echo 0)"

# A conversion that fails while the directory is still legacy stays FAILED.
new_fixture stuck
mkdir -p "$DST"
ln -s "$SRC/SKILL.md" "$DST/SKILL.md"
cat >> "$R/lib-symlinks.sh" <<'SHIM'
symlink_migrate_legacy_skill_dir() { return 1; }
SHIM
out="$(run_check --heal)"; rc=$?
check "stuck migration: --heal exits 1" "$([ "$rc" -eq 1 ] && echo 1 || echo 0)"
check "stuck migration: reported FAILED" "$(grep -q 'FAILED  skills/demo' <<<"$out" && echo 1 || echo 0)"

echo "heal-race: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
