#!/usr/bin/env bash
# heal-race.test.sh — regression for issue #603: two launchers running
# check-claude.sh --heal at once. Both see a skill link MISSING; the loser's
# plain `ln -s` then followed the directory link the winner had just made and
# dropped a self-link INSIDE the source bundle (<bundle>/<name> -> <bundle>),
# which the checker could not see. Covers: the heal path never nests (ln -sn),
# the SELFLINK check and its --fix, and a migration that a concurrent run
# finished first is not reported as FAILED, nor one it is still finishing
# (PR #604 review), even when the first scan already raced it (#635 review). Also covers the CLI-stack advisory (issue #605): a missing
# rg/fd/bat/eza warns without failing the check. Fixture-driven: the checker and its
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

# The checker looks the CLI stack up on PATH, so every run gets a controlled
# one: SYSBIN mirrors the real PATH minus rg/fd/bat/eza (and their Debian
# names), and TOOLS holds stubs for the ones a case wants present. One cp -s
# per directory keeps the mirror cheap; Windows dirs (WSL) are skipped.
SYSBIN="$FIX/sysbin"
mkdir -p "$SYSBIN"
IFS=: read -ra _path_dirs <<<"$PATH"
for _d in "${_path_dirs[@]}"; do
  case "$_d" in /mnt/*|"") continue ;; esac
  [ -d "$_d" ] && cp -sn "$_d"/* "$SYSBIN"/ 2>/dev/null
done
rm -f "$SYSBIN"/{rg,fd,fdfind,bat,batcat,eza}
# fake_tools <dir> <name>... — a PATH dir holding a stub per name.
fake_tools() {
  local dir="$1" t
  shift
  rm -rf "$dir" && mkdir -p "$dir"
  for t in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$dir/$t" && chmod +x "$dir/$t"; done
}
TOOLS="$FIX/tools-all"
fake_tools "$TOOLS" rg fd bat eza

# A rival migration runs in the background of the checker, so it must not
# hold the checker's stdout: `out="$(run_check ...)"` would wait for it and
# hide a checker that exits early (#635 review). Rivals redirect away from
# the capture, and the test waits for one with wait_rival — a bare `wait`
# cannot, since the rival is the checker's child, not ours.
# wait_rival <marks dir> — up to ~10s for the rival's done mark.
wait_rival() {
  local i
  for i in $(seq 1 100); do
    [ -e "$1/done" ] && return 0
    sleep 0.1
  done
  return 1
}

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
run_check() { HOME="$H" PATH="$TOOLS:$SYSBIN" "$R/check-claude.sh" "$@" 2>&1; }

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

# A conversion still in flight elsewhere is waited out, not reported (PR #604
# review, r4185789022). The shim plays the losing run: on its first call it
# starts a rival that drains the directory slowly, waits until the rival has
# removed its first entry, and fails. Every later call fails too ("busy")
# while the rival runs, so the checker can only succeed by waiting for it; once
# the rival has linked the directory the real migrator runs (and finds a link).
# The rival removes entries by name from the real directory only, so it can
# never reach through a link into the source bundle.
new_fixture inflight
mkdir -p "$DST"
for i in 1 2 3 4 5; do printf 'x\n' > "$SRC/f$i"; ln -s "$SRC/f$i" "$DST/f$i"; done
ln -s "$SRC/SKILL.md" "$DST/SKILL.md"
M="$FIX/inflight/marks"
mkdir -p "$M"
cat >> "$R/lib-symlinks.sh" <<SHIM
eval "orig_\$(declare -f symlink_migrate_legacy_skill_dir)"
symlink_migrate_legacy_skill_dir() {
  if [ ! -e "$M/started" ]; then
    (
      first=1
      for n in f1 f2 f3 f4 f5 SKILL.md; do
        rm "\$2/\$n"
        [ "\$first" -eq 1 ] && : > "$M/started" && first=0
        sleep 0.2
      done
      rmdir "\$2" && ln -sn "\$1" "\$2" && : > "$M/done"
    ) >/dev/null 2>&1 &
    until [ -e "$M/started" ]; do sleep 0.05; done
  fi
  if [ ! -e "$M/done" ]; then
    echo busy >> "$M/calls"
    return 1
  fi
  orig_symlink_migrate_legacy_skill_dir "\$@"
}
SHIM
out="$(run_check --heal)"; rc=$?
done_before_exit="$([ -e "$M/done" ] && echo 1 || echo 0)"
wait_rival "$M"
check "in-flight migration: --heal exits 0" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
check "in-flight migration: not reported FAILED or NOT LINKED" \
  "$(! grep -qE 'FAILED|NOT LINKED' <<<"$out" && echo 1 || echo 0)"
check "in-flight migration: checker finished only after the rival" "$done_before_exit"
check "in-flight migration: retried while the rival was still running" \
  "$([ "$(wc -l < "$M/calls")" -ge 2 ] && echo 1 || echo 0)"
check "in-flight migration: directory link in place" \
  "$([ "$(readlink "$DST")" = "$SRC" ] && echo 1 || echo 0)"
check "in-flight migration: source files survive" \
  "$([ -f "$SRC/SKILL.md" ] && [ -f "$SRC/f1" ] && [ -f "$SRC/f5" ] && echo 1 || echo 0)"

# The rival can also win the very first scan: an entry vanishes between the
# predicate's -L and its readlink, so the directory looks foreign, not legacy
# (gate review on #635). A fake readlink makes that window deterministic: on
# its first call for an entry under $DST it removes that entry, starts the
# rival draining the rest, and lets the real readlink fail. The migrate shim
# stays busy until the rival has linked the directory, as above.
new_fixture vanish
mkdir -p "$DST"
for i in 1 2 3 4 5; do printf 'x\n' > "$SRC/f$i"; ln -s "$SRC/f$i" "$DST/f$i"; done
ln -s "$SRC/SKILL.md" "$DST/SKILL.md"
M="$FIX/vanish/marks"
mkdir -p "$M"
VTOOLS="$FIX/tools-vanish"
fake_tools "$VTOOLS" rg fd bat eza
REAL_READLINK="$(command -v readlink)"
cat > "$VTOOLS/readlink" <<FAKE
#!/bin/bash
if [ ! -e "$M/raced" ] && [ "\${1%/*}" = "$DST" ]; then
  : > "$M/raced"
  rm "\$1"
  (
    for e in "$DST"/* "$DST"/.[!.]*; do
      [ -L "\$e" ] || continue
      sleep 0.2
      rm "\$e"
    done
    rmdir "$DST" && ln -sn "$SRC" "$DST" && : > "$M/done"
  ) >/dev/null 2>&1 &
fi
exec "$REAL_READLINK" "\$@"
FAKE
chmod +x "$VTOOLS/readlink"
cat >> "$R/lib-symlinks.sh" <<SHIM
eval "orig_\$(declare -f symlink_migrate_legacy_skill_dir)"
symlink_migrate_legacy_skill_dir() {
  [ -e "$M/done" ] || return 1
  orig_symlink_migrate_legacy_skill_dir "\$@"
}
SHIM
TOOLS="$VTOOLS"
out="$(run_check --heal)"; rc=$?
done_before_exit="$([ -e "$M/done" ] && echo 1 || echo 0)"
wait_rival "$M"
TOOLS="$FIX/tools-all"
check "vanished entry: the race fired" "$([ -e "$M/raced" ] && echo 1 || echo 0)"
check "vanished entry: --heal exits 0" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
check "vanished entry: not reported FAILED or NOT LINKED" \
  "$(! grep -qE 'FAILED|NOT LINKED' <<<"$out" && echo 1 || echo 0)"
check "vanished entry: checker finished only after the rival" "$done_before_exit"
check "vanished entry: directory link in place, sources intact" \
  "$([ "$(readlink "$DST")" = "$SRC" ] && [ -f "$SRC/SKILL.md" ] && [ -f "$SRC/f1" ] && echo 1 || echo 0)"

# Genuine foreign content is not waited out: a stable non-legacy directory is
# reported NOT LINKED promptly, never FAILED, and left untouched.
new_fixture foreign
mkdir -p "$DST"
printf 'mine\n' > "$DST/notes.md"
t0=$SECONDS
out="$(run_check --heal)"; rc=$?
check "foreign dir: --heal exits 1 with NOT LINKED" \
  "$([ "$rc" -eq 1 ] && grep -q 'NOT LINKED  skills/demo' <<<"$out" && ! grep -q FAILED <<<"$out" && echo 1 || echo 0)"
check "foreign dir: not held for the full wait" "$([ $((SECONDS - t0)) -lt 3 ] && echo 1 || echo 0)"
check "foreign dir: content untouched" "$([ -f "$DST/notes.md" ] && [ ! -L "$DST" ] && echo 1 || echo 0)"

# ── 4b. migration never deletes (issue #638) ─────────────────────────────
# The legacy dir is renamed whole into <claude>/.migrated-skill-dirs/ rather
# than drained link by link, so no race can make an rm resolve into $SRC.
# race_bin <dir> <mode> — a PATH dir whose `rm` and `perl` play a race around
# the first call of either: mode `rival` first finishes a rival migration
# (drain $DST if still a real dir, link it to $SRC); `rival-file` also drops a
# regular file at $DST if the call left it absent; `swap` replaces the archived
# SKILL.md link with a regular file after the call. Then the real tool's exit
# status is returned.
ARCH_REL=".claude/.migrated-skill-dirs"
REAL_RM="$(command -v rm)"
REAL_PERL="$(command -v perl)"
race_bin() {
  local dir="$1" mode="$2"
  mkdir -p "$dir"
  cat > "$dir/rm" <<FAKE
#!/bin/bash
case "\${0##*/}" in rm) real="$REAL_RM" ;; *) real="$REAL_PERL" ;; esac
first=0
if [ ! -e "$M/raced" ]; then : > "$M/raced"; first=1; fi
if [ "\$first" -eq 1 ] && [ "$mode" != swap ]; then
  if [ -d "$DST" ] && [ ! -L "$DST" ]; then "$REAL_RM" -f "$DST"/* && rmdir "$DST"; fi
  [ -e "$DST" ] || [ -L "$DST" ] || ln -sn "$SRC" "$DST"
fi
"\$real" "\$@"; rc=\$?
if [ "\$first" -eq 1 ] && [ "$mode" = rival-file ] && [ ! -e "$DST" ] && [ ! -L "$DST" ]; then
  printf 'user\\n' > "$DST"
fi
if [ "\$first" -eq 1 ] && [ "$mode" = swap ]; then
  for d in "$H/$ARCH_REL"/demo.*; do
    [ -L "\$d/SKILL.md" ] && "$REAL_RM" "\$d/SKILL.md" && printf 'swapped\\n' > "\$d/SKILL.md"
  done
fi
exit \$rc
FAKE
  chmod +x "$dir/rm"
  cp "$dir/rm" "$dir/perl"
}
legacy_fixture() {
  new_fixture "$1"
  mkdir -p "$DST"
  for i in 1 2 3; do printf 'x\n' > "$SRC/f$i"; ln -s "$SRC/f$i" "$DST/f$i"; done
  ln -s "$SRC/SKILL.md" "$DST/SKILL.md"
  M="$FIX/$1/marks"
  mkdir -p "$M"
}
# migrate_with <bin dir> — run the fixture's migration with <bin dir> first on
# PATH; sets rc.
migrate_with() {
  (
    PATH="$1:$PATH"
    # shellcheck source=../../../lib-symlinks.sh
    . "$R/lib-symlinks.sh"
    symlink_migrate_legacy_skill_dir "$SRC" "$DST"
  ) >/dev/null 2>&1
  rc=$?
}
sources_intact() {
  [ -f "$SRC/f1" ] && [ -f "$SRC/f2" ] && [ -f "$SRC/f3" ] && [ -f "$SRC/SKILL.md" ]
}

# A plain conversion: the old dir lands in the archive, links intact, and
# --heal links the bundle in its place.
legacy_fixture archive
out="$(run_check --heal)"; rc=$?
arch=""
for d in "$H/$ARCH_REL"/demo.*; do [ -d "$d" ] && arch="$d"; done
check "archive: --heal exits 0 and links the bundle" \
  "$([ "$rc" -eq 0 ] && [ "$(readlink "$DST")" = "$SRC" ] && echo 1 || echo 0)"
check "archive: the old dir is archived with its links" \
  "$([ -n "$arch" ] && [ "$(readlink "$arch/f1")" = "$SRC/f1" ] && [ -L "$arch/SKILL.md" ] && echo 1 || echo 0)"
check "archive: name is <skill>.<UTC timestamp>.<pid>" \
  "$([[ "${arch##*/}" =~ ^demo\.[0-9]{8}T[0-9]{6}Z\.[0-9]+$ ]] && echo 1 || echo 0)"
check "archive: nothing left in skills/ but the link" \
  "$([ "$(find "$H/.claude/skills" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] && echo 1 || echo 0)"

# A rival that finishes WHILE this run migrates must not cost a source file.
# The old in-place loop had already passed `[ -L "$DST/f1" ]`, so its rm
# "$DST/f1" resolved through the rival's link and deleted $SRC/f1.
legacy_fixture rmrace
race_bin "$FIX/rmrace/bin" rival
migrate_with "$FIX/rmrace/bin"
check "rm race: the rival fired" "$([ -e "$M/raced" ] && echo 1 || echo 0)"
check "rm race: every source file survives" "$(sources_intact && echo 1 || echo 0)"
out="$(run_check --heal)"; rc=$?
check "rm race: a later --heal settles on the directory link" \
  "$([ "$rc" -eq 0 ] && [ "$(readlink "$DST")" = "$SRC" ] && echo 1 || echo 0)"

# The rename can grab the rival's directory link; a regular file that then
# appears at $DST must survive (gate review round 3: renaming the link back
# overwrote it). The link stays in the archive instead.
legacy_fixture rivalfile
race_bin "$FIX/rivalfile/bin" rival-file
migrate_with "$FIX/rivalfile/bin"
check "file at dst: the race fired" "$([ -e "$M/raced" ] && echo 1 || echo 0)"
check "file at dst: the new file survives" \
  "$([ -f "$DST" ] && [ ! -L "$DST" ] && [ "$(cat "$DST")" = user ] && echo 1 || echo 0)"
check "file at dst: sources intact" "$(sources_intact && echo 1 || echo 0)"

# A writer that swaps a link in the moved dir for a real file loses nothing,
# because nothing is deleted (gate review round 3); the dir, no longer legacy,
# goes back to the still-absent $DST and migration reports failure.
legacy_fixture swap
race_bin "$FIX/swap/bin" swap
migrate_with "$FIX/swap/bin"
found=0
for f in "$DST/SKILL.md" "$H/$ARCH_REL"/demo.*/SKILL.md; do
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(cat "$f")" = swapped ] && found=1
done
check "swapped file: the race fired" "$([ -e "$M/raced" ] && echo 1 || echo 0)"
check "swapped file: survives" "$found"
check "swapped file: restored to dst, migration reports failure" \
  "$([ "$rc" -ne 0 ] && [ -d "$DST" ] && [ ! -L "$DST" ] && echo 1 || echo 0)"
check "swapped file: sources intact" "$(sources_intact && echo 1 || echo 0)"

# ── 5. CLI stack advisory (issue #605) ───────────────────────────────────
new_fixture tools
out="$(run_check --heal)"; rc=$?
check "tools present: no TOOL line" "$([ "$rc" -eq 0 ] && ! grep -q 'TOOL' <<<"$out" && echo 1 || echo 0)"
TOOLS="$FIX/tools-some"
fake_tools "$TOOLS" rg fdfind
out="$(run_check)"; rc=$?
check "tools missing: still exits 0 (advisory)" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
check "tools missing: WARN for bat and eza" \
  "$(grep -q '\[WARN\] TOOL  bat ' <<<"$out" && grep -q '\[WARN\] TOOL  eza ' <<<"$out" && echo 1 || echo 0)"
check "tools missing: rg present, no WARN" "$(! grep -q 'TOOL  rg ' <<<"$out" && echo 1 || echo 0)"
check "tools missing: fd only as fdfind names the shim" \
  "$(grep -q '\[WARN\] TOOL  fd .*fdfind' <<<"$out" && echo 1 || echo 0)"
TOOLS="$FIX/tools-all"

echo "heal-race: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
