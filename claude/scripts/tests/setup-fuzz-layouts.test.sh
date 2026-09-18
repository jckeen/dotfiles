#!/usr/bin/env bash
# setup-fuzz-layouts.test.sh — seeded layout fuzzer for `setup.sh --dry-run`.
#
# setup-dry-run.test.sh pins the no-writes contract (#133) against ONE
# hand-built $HOME. That guard has to hold for every shape of pre-existing
# state, not just the one shape a human thought to build, so this suite draws
# pseudo-random layouts across the axes that actually drive setup.sh's mutation
# paths and asserts the same byte-identical before/after snapshot for each:
#
#   .bashrc          absent / plain / carrying the /mnt/c cd the sed path edits
#   .gitconfig       absent / a real file / a symlink
#   .claude          absent / a real dir / a symlink
#   ~/.agents/skills absent / empty / holding a foreign link to relink
#   dangling symlink none / under ~/.agents/skills / at the top of $HOME
#   ~/.codex         absent / present
#   CODEX_MEMORY_REPO unset / a fixture with a bootstrap.sh
#   bun              pruned from PATH / a stub on PATH
#
# Every symlink target lives inside the throwaway $HOME, so a write THROUGH a
# link is caught by the snapshot instead of escaping it.
#
# Deterministic: SEED fixes every draw and is printed on the header line and on
# every failure, so a red run reproduces exactly:
#   SEED=<n> bash claude/scripts/tests/setup-fuzz-layouts.test.sh
# LAYOUTS overrides how many layouts are drawn.
#
# Some layouts make setup.sh refuse (a symlinked runtime root, a backup
# collision). The contract asserted here is zero mutations, NOT exit 0, so the
# exit status is reported for diagnosis rather than asserted — a refusal that
# mutates $HOME is exactly the bug this looks for.
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

# shellcheck source=claude/scripts/tests/lib-snapshot.sh
. "$SCRIPT_DIR/lib-snapshot.sh"

# Preconditions are FATAL, not per-layout assertions: a run that cannot execute
# setup.sh, or that lost the snapshot helper, compares empty against empty and
# reports every layout as clean. That failure mode has to be loud.
[ -x "$SETUP" ] || { echo "FATAL - setup.sh is missing or not executable: $SETUP"; exit 1; }
command -v snapshot >/dev/null 2>&1 \
  || { echo "FATAL - lib-snapshot.sh did not define snapshot()"; exit 1; }

# setup.sh refuses to run from a linked git worktree (#412) and agents work in
# worktrees by default; without this the suite would fail on the refusal rather
# than on the contract it exists to check (#435). Safe here: every run targets a
# throwaway HOME and the assertion is a byte-identical snapshot, so nothing
# links to this checkout. The refusal stays covered by setup-worktree-guard.
export DOTFILES_ALLOW_LINKED_WORKTREE=1

SEED="${SEED:-$RANDOM}"
LAYOUTS="${LAYOUTS:-25}"
RANDOM="$SEED"

pass=0
failed=0
planned=0

ok()   { pass=$((pass + 1));     echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

OUT="$(mktemp)"
TESTHOME=""
trap 'rm -f "$OUT"; [ -z "$TESTHOME" ] || rm -rf "$TESTHOME"' EXIT

# path_without <command> — echo $PATH with every entry that provides
# <command> removed. The `checks` job installs Bun before this suite runs, so a
# bun=absent draw that merely left PATH alone would still let setup.sh find Bun
# and the missing-Bun installer branch would never be exercised.
path_without() {
  local want="$1"
  printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ -x "$entry/$want" ] && continue
    printf '%s\n' "$entry"
  done | paste -sd: -
}

BUN_ABSENT_PATH="$(path_without bun)"
if PATH="$BUN_ABSENT_PATH" command -v bun > /dev/null 2>&1; then
  echo "FATAL - could not build a bun-free PATH; the bun=absent draw would be a no-op"
  exit 1
fi
# Pruning must not take the tools setup.sh itself needs; if it did, every
# absent-draw layout would fail for the wrong reason.
for required in git curl; do
  PATH="$BUN_ABSENT_PATH" command -v "$required" > /dev/null 2>&1 \
    || { echo "FATAL - pruning bun from PATH also removed $required"; exit 1; }
done

# draw <axis> <option>... — pick one option and record it. Sets DRAWN and
# appends to MANIFEST. Deliberately not a command substitution: a subshell
# would discard the manifest and desynchronise the seeded RANDOM sequence.
draw() {
  local axis="$1"
  shift
  local -a options=("$@")
  DRAWN="${options[$((RANDOM % ${#options[@]}))]}"
  MANIFEST="$MANIFEST      $axis=$DRAWN"$'\n'
}

echo "setup-fuzz-layouts: SEED=$SEED LAYOUTS=$LAYOUTS"

for ((layout = 1; layout <= LAYOUTS; layout++)); do
  TESTHOME="$(mktemp -d)"
  MANIFEST=""
  CODEX_MEMORY=""
  mkdir -p "$TESTHOME/elsewhere"

  draw bashrc absent plain mntc
  case "$DRAWN" in
    plain) printf '# plain profile\n' > "$TESTHOME/.bashrc" ;;
    mntc)  printf 'cd /mnt/c/Users/test\n' > "$TESTHOME/.bashrc" ;;
  esac

  draw bash_profile absent present
  [ "$DRAWN" = present ] && printf '# real profile\n' > "$TESTHOME/.bash_profile"

  draw gitconfig absent file symlink
  case "$DRAWN" in
    file)
      git config --file "$TESTHOME/.gitconfig" user.name fuzz
      git config --file "$TESTHOME/.gitconfig" user.email fuzz@test.test
      ;;
    symlink)
      printf '[user]\n\tname = fuzz\n' > "$TESTHOME/elsewhere/gitconfig"
      ln -s "$TESTHOME/elsewhere/gitconfig" "$TESTHOME/.gitconfig"
      ;;
  esac

  draw claude absent dir symlink
  case "$DRAWN" in
    dir) mkdir -p "$TESTHOME/.claude" ;;
    symlink)
      mkdir -p "$TESTHOME/elsewhere/claude"
      ln -s "$TESTHOME/elsewhere/claude" "$TESTHOME/.claude"
      ;;
  esac

  draw agents_skills absent empty foreign
  case "$DRAWN" in
    empty) mkdir -p "$TESTHOME/.agents/skills" ;;
    foreign)
      # A pre-existing link to something that is NOT this checkout's bundle:
      # the relink/repair path has to replace it without writing through it.
      mkdir -p "$TESTHOME/.agents/skills" "$TESTHOME/elsewhere/orchestrate"
      printf 'stale external skill\n' > "$TESTHOME/elsewhere/orchestrate/SKILL.md"
      ln -s "$TESTHOME/elsewhere/orchestrate" "$TESTHOME/.agents/skills/orchestrate"
      ;;
  esac

  draw dangling none skills home
  case "$DRAWN" in
    skills)
      mkdir -p "$TESTHOME/.agents/skills"
      ln -s "$TESTHOME/no-such-target" "$TESTHOME/.agents/skills/ghost-skill"
      ;;
    home) ln -s "$TESTHOME/no-such-target" "$TESTHOME/.dangling-fixture" ;;
  esac

  draw codex absent dir
  [ "$DRAWN" = dir ] && mkdir -p "$TESTHOME/.codex"

  draw codex_memory unset fixture
  if [ "$DRAWN" = fixture ]; then
    mkdir -p "$TESTHOME/codex-memory"
    cat > "$TESTHOME/codex-memory/bootstrap.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
printf 'invoked\n' > "$HOME/codex-bootstrap-invoked"
BOOTSTRAP
    chmod +x "$TESTHOME/codex-memory/bootstrap.sh"
    CODEX_MEMORY="$TESTHOME/codex-memory"
  fi

  draw bun absent stub
  if [ "$DRAWN" = stub ]; then
    mkdir -p "$TESTHOME/bunbin"
    printf '#!/bin/sh\nexit 0\n' > "$TESTHOME/bunbin/bun"
    chmod +x "$TESTHOME/bunbin/bun"
    RUN_PATH="$TESTHOME/bunbin:$PATH"
  else
    RUN_PATH="$BUN_ABSENT_PATH"
  fi

  before="$(snapshot "$TESTHOME")"
  if [ -z "$before" ]; then
    fail "layout $layout snapshotted an empty tree; the comparison would be vacuous (SEED=$SEED)"
    rm -rf "$TESTHOME"
    TESTHOME=""
    continue
  fi

  runenv=(HOME="$TESTHOME" PATH="$RUN_PATH")
  if [ -n "$CODEX_MEMORY" ]; then
    runenv+=(CODEX_MEMORY_REPO="$CODEX_MEMORY")
  fi

  # The draw only means something if the environment matches it.
  if PATH="$RUN_PATH" command -v bun > /dev/null 2>&1; then
    bun_state=present
  else
    bun_state=absent
  fi
  case "$MANIFEST" in
    *"bun=stub"*) [ "$bun_state" = present ] \
      || fail "layout $layout drew bun=stub but bun is not on PATH (SEED=$SEED)" ;;
    *"bun=absent"*) [ "$bun_state" = absent ] \
      || fail "layout $layout drew bun=absent but bun is still on PATH (SEED=$SEED)" ;;
  esac

  env "${runenv[@]}" "$SETUP" --yes --dry-run > "$OUT" 2>&1
  rc=$?

  after="$(snapshot "$TESTHOME")"

  # 126/127 mean setup.sh never ran, so "no mutations" would be meaningless.
  if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    fail "layout $layout could not execute setup.sh (rc=$rc, SEED=$SEED)"
    tail -20 "$OUT" | sed 's/^/      | /'
  fi
  if [ ! -s "$OUT" ]; then
    fail "layout $layout produced no setup.sh output at all (rc=$rc, SEED=$SEED)"
  fi
  # Refusing layouts exit before the banner; the aggregate check below proves the
  # run as a whole exercised the planning path rather than only refusals.
  if grep -q 'Mode: DRY-RUN' "$OUT"; then
    planned=$((planned + 1))
  fi

  if [ "$before" = "$after" ]; then
    ok "layout $layout made zero mutations in \$HOME (rc=$rc)"
  else
    fail "layout $layout mutated \$HOME (SEED=$SEED, layout=$layout, rc=$rc)"
    echo "      layout manifest:"
    printf '%s' "$MANIFEST"
    echo "      snapshot diff:"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/      | /'
    echo "      last setup.sh output:"
    tail -40 "$OUT" | sed 's/^/      | /'
  fi

  # The bootstrap fixture writes this marker if the dry-run ever executes it.
  if [ -e "$TESTHOME/codex-bootstrap-invoked" ]; then
    fail "layout $layout executed the Codex private bootstrap (SEED=$SEED)"
  fi

  rm -rf "$TESTHOME"
  TESTHOME=""
done

if [ "$planned" -gt 0 ]; then
  ok "$planned of $LAYOUTS layouts reached the dry-run planning path"
else
  fail "no layout reached setup.sh's dry-run planning path; this run proves nothing (SEED=$SEED)"
fi

echo ""
echo "setup-fuzz-layouts: $pass passed, $failed failed (SEED=$SEED)"
[ "$failed" -eq 0 ] || {
  echo "reproduce with: SEED=$SEED bash claude/scripts/tests/setup-fuzz-layouts.test.sh"
  exit 1
}
