#!/usr/bin/env bash
# setup-dry-run.test.sh — regression test for issue #133: `setup.sh --dry-run`
# must not write ANYTHING under $HOME. Builds a throwaway HOME seeded with
# files that tempt every mutation path (a real .gitconfig for the backup path,
# a .bashrc with a /mnt/c cd for the sed path, a real .bash_profile), snapshots
# it, runs `setup.sh --yes --dry-run` against it, and asserts the snapshot is
# unchanged — paths, contents, and symlink targets. Also asserts the
# `--dry-run --repair` combo previews fixes without applying them. Run
# directly; exit 1 on any failure. Mirrors install-integrity.test.sh
# conventions.
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

pass=0
failed=0

ok()   { pass=$((pass + 1));   echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

# Full-fidelity snapshot of a directory tree: every path, every regular-file
# hash, every symlink target. Two identical snapshots ⇒ zero mutations.
snapshot() {
  local root="$1"
  (
    cd "$root" || exit 1
    find . -mindepth 1 | sort
    find . -type f -print0 | sort -z | xargs -0 -r sha256sum
    find . -type l -print0 | sort -z | while IFS= read -r -d '' l; do
      printf 'link %s -> %s\n' "$l" "$(readlink "$l")"
    done
  )
}

TESTHOME="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$TESTHOME" "$OUT"' EXIT

# Seed the mutation-tempting fixtures.
git config --file "$TESTHOME/.gitconfig" user.name test
git config --file "$TESTHOME/.gitconfig" user.email test@test.test
printf 'cd /mnt/c/Users/test\n' > "$TESTHOME/.bashrc"
printf '# real profile\n' > "$TESTHOME/.bash_profile"
mkdir -p "$TESTHOME/.codex" "$TESTHOME/external-codex-skills"
ln -s "$TESTHOME/external-codex-skills" "$TESTHOME/.codex/skills"

before="$(snapshot "$TESTHOME")"

# --yes so prompts take safe defaults (no stdin); dry-run must exit 0.
if HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
  ok "setup.sh --yes --dry-run exits 0"
else
  fail "setup.sh --yes --dry-run exited $? (output follows)"
  sed 's/^/      | /' "$OUT"
fi

after="$(snapshot "$TESTHOME")"

if [ "$before" = "$after" ]; then
  ok "dry-run made zero mutations in \$HOME (paths, contents, link targets)"
else
  fail "dry-run mutated \$HOME:"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/      | /'
fi

if grep -q 'Mode: DRY-RUN' "$OUT"; then
  ok "banner reports DRY-RUN mode"
else
  fail "missing 'Mode: DRY-RUN' banner"
fi

if grep -q '\[DRY\] would link' "$OUT"; then
  ok "link_file dry-run guard engaged (would-link preview printed)"
else
  fail "no '[DRY] would link' lines — link_file guard not exercised"
fi

if grep -q '/.codex/skills/orchestrate/agents/openai.yaml' "$OUT" &&
  grep -q '/.codex/skills/orchestrate/references/runtime-contracts.md' "$OUT"; then
  ok "Codex skill bundles include nested metadata and references"
else
  fail "Codex skill bundle files were not included in the dry-run link plan"
fi

if grep -q "would back up $TESTHOME/.codex/skills to $TESTHOME/.codex/skills.backup" "$OUT"; then
  ok "Codex setup refuses to write through a symlinked skill ancestor"
else
  fail "Codex setup did not isolate a symlinked skill ancestor"
fi

# --dry-run --repair must preview fixes without applying them (reviewer P3 on
# PR #187: audit_link's repair branches used to rm/mv/ln unconditionally).
# Non-zero exit is expected — the entries are still broken after a preview.
before="$(snapshot "$TESTHOME")"
HOME="$TESTHOME" "$SETUP" --dry-run --repair > "$OUT" 2>&1
repair_rc=$?
after="$(snapshot "$TESTHOME")"

if [ "$before" = "$after" ]; then
  ok "--dry-run --repair made zero mutations in \$HOME (rc=$repair_rc, non-zero expected)"
else
  fail "--dry-run --repair mutated \$HOME:"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/      | /'
fi

if grep -q '\[DRY\] would fix' "$OUT"; then
  ok "repair dry-run guard engaged (would-fix preview printed)"
else
  fail "no '[DRY] would fix' lines — repair guard not exercised"
  sed 's/^/      | /' "$OUT"
fi

echo ""
echo "setup-dry-run: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
