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
CHECK_OUT="$(mktemp)"
INSTALL_OUT="$(mktemp)"
SKILLS_OUT="$(mktemp)"
SKILLS_EXTERNAL="$(mktemp -d)"
trap 'rm -rf "$TESTHOME" "$OUT" "$CHECK_OUT" "$INSTALL_OUT" "$SKILLS_OUT" "$SKILLS_EXTERNAL"' EXIT

# Seed the mutation-tempting fixtures.
git config --file "$TESTHOME/.gitconfig" user.name test
git config --file "$TESTHOME/.gitconfig" user.email test@test.test
printf 'cd /mnt/c/Users/test\n' > "$TESTHOME/.bashrc"
printf '# real profile\n' > "$TESTHOME/.bash_profile"
mkdir -p "$TESTHOME/.codex" "$TESTHOME/external-codex-skills"
mkdir -p "$TESTHOME/codex-memory"
cat > "$TESTHOME/codex-memory/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
printf 'invoked\n' > "$HOME/codex-bootstrap-invoked"
EOF
chmod +x "$TESTHOME/codex-memory/bootstrap.sh"
mkdir -p "$TESTHOME/external-codex-skills/orchestrate/agents" \
  "$TESTHOME/external-codex-skills/orchestrate/references"
printf 'stale external skill\n' > "$TESTHOME/external-codex-skills/orchestrate/SKILL.md"
printf 'stale external backup\n' > "$TESTHOME/external-codex-skills/orchestrate/SKILL.md.backup"
ln -s "$REPO_ROOT/agents/skills/orchestrate/agents/openai.yaml" \
  "$TESTHOME/external-codex-skills/orchestrate/agents/openai.yaml"
ln -s "$REPO_ROOT/agents/skills/orchestrate/references/runtime-contracts.md" \
  "$TESTHOME/external-codex-skills/orchestrate/references/runtime-contracts.md"
ln -s "$TESTHOME/external-codex-skills" "$TESTHOME/.codex/skills"

before="$(snapshot "$TESTHOME")"

# --yes so prompts take safe defaults (no stdin); dry-run must exit 0.
if HOME="$TESTHOME" CODEX_MEMORY_REPO="$TESTHOME/codex-memory" \
  "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
  ok "setup.sh --yes --dry-run exits 0"
else
  fail "setup.sh --yes --dry-run exited $? (output follows)"
  sed 's/^/      | /' "$OUT"
fi

if grep -Fq "[DRY] bash $TESTHOME/codex-memory/bootstrap.sh" "$OUT" \
  && ! grep -Fq "Codex portable private defaults applied" "$OUT" \
  && [ ! -e "$TESTHOME/codex-bootstrap-invoked" ]; then
  ok "Codex private bootstrap is previewed without running in dry-run mode"
else
  fail "Codex private bootstrap dry-run claimed or performed a live apply"
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

if grep -q 'Checking Antigravity public-safe config' "$OUT"; then
  ok "post-setup audit covers the Antigravity installation"
else
  fail "post-setup audit skipped the Antigravity installation"
fi

HOME="$TESTHOME" CODEX_MEMORY_REPO="$TESTHOME/codex-memory" \
  "$SETUP" --check > "$CHECK_OUT" 2>&1 || true
if grep -q 'Checking Codex public-safe config' "$CHECK_OUT" \
  && grep -q 'Checking Antigravity public-safe config' "$CHECK_OUT"; then
  ok "setup.sh --check audits Codex and Antigravity as well as Claude"
else
  fail "setup.sh --check is not a three-runtime audit"
fi

PATH="/usr/bin:/bin" HOME="$TESTHOME" CODEX_MEMORY_REPO="$TESTHOME/codex-memory" \
  "$SETUP" --yes --dry-run > "$INSTALL_OUT" 2>&1 || true
if grep -q 'would download https://antigravity.google/cli/install.sh' "$INSTALL_OUT"; then
  ok "clean-machine dry-run includes the pinned Antigravity installer"
else
  fail "clean-machine setup omits the Antigravity CLI"
fi

mkdir -p "$TESTHOME/.gemini/config"
ln -s "$SKILLS_EXTERNAL" "$TESTHOME/.gemini/config/skills"
skills_before="$(snapshot "$SKILLS_EXTERNAL")"
HOME="$TESTHOME" CODEX_MEMORY_REPO="$TESTHOME/codex-memory" \
  "$SETUP" --yes --dry-run > "$SKILLS_OUT" 2>&1 || true
skills_after="$(snapshot "$SKILLS_EXTERNAL")"
if grep -Fq "[DRY] would back up $TESTHOME/.gemini/config/skills" "$SKILLS_OUT" \
  && [ "$skills_before" = "$skills_after" ]; then
  ok "Antigravity setup safely prepares a symlinked skills ancestor"
else
  fail "Antigravity setup would traverse a symlinked skills ancestor"
fi
rm "$TESTHOME/.gemini/config/skills"
rmdir "$TESTHOME/.gemini/config" "$TESTHOME/.gemini"

if grep -q '\[DRY\] would link' "$OUT"; then
  ok "link_file dry-run guard engaged (would-link preview printed)"
else
  fail "no '[DRY] would link' lines — link_file guard not exercised"
fi

if grep -q "\[DRY\] would link $TESTHOME/.codex/skills/orchestrate/agents/openai.yaml ->" "$OUT" &&
  grep -q "\[DRY\] would link $TESTHOME/.codex/skills/orchestrate/references/runtime-contracts.md ->" "$OUT" &&
  grep -q "\[DRY\] would link $TESTHOME/.codex/skills/orchestrate/SKILL.md ->" "$OUT"; then
  ok "Codex skill bundles include nested metadata and references"
else
  fail "Codex skill bundle files were not included in the dry-run link plan"
fi

if grep -q "\[DRY\] would link $TESTHOME/.agents/skills/orchestrate ->" "$OUT"; then
  ok "Codex shared skills deploy to the documented user discovery path"
else
  fail "Codex shared skills were not deployed under ~/.agents/skills"
fi

if [ "$(grep -c "would back up $TESTHOME/.codex/skills to $TESTHOME/.codex/skills.backup" "$OUT")" -eq 1 ]; then
  ok "Codex setup refuses to write through a symlinked skill ancestor"
else
  fail "Codex setup did not isolate a symlinked skill ancestor"
fi

mkdir "$TESTHOME/.codex/skills.backup"
before="$(snapshot "$TESTHOME")"
if HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
  fail "dry-run accepted a conflicting ancestor backup"
elif grep -q "refusing to replace $TESTHOME/.codex/skills because $TESTHOME/.codex/skills.backup already exists" "$OUT"; then
  ok "dry-run refuses the same ancestor backup collision as a real run"
else
  fail "dry-run backup collision lacked a useful report"
fi
after="$(snapshot "$TESTHOME")"
if [ "$before" = "$after" ]; then
  ok "backup-collision dry-run made zero mutations in \$HOME"
else
  fail "backup-collision dry-run mutated \$HOME"
fi
rm -r "$TESTHOME/.codex/skills.backup"

printf 'conflicting agent rules\n' > "$TESTHOME/.codex/AGENTS.md"
printf 'existing backup\n' > "$TESTHOME/.codex/AGENTS.md.backup"
before="$(snapshot "$TESTHOME")"
if HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
  fail "dry-run accepted a conflicting leaf backup"
elif grep -q "refusing to replace $TESTHOME/.codex/AGENTS.md because $TESTHOME/.codex/AGENTS.md.backup already exists" "$OUT"; then
  ok "dry-run refuses the same leaf backup collision as a real run"
else
  fail "dry-run leaf backup collision lacked a useful report"
fi
after="$(snapshot "$TESTHOME")"
if [ "$before" = "$after" ]; then
  ok "leaf-collision dry-run made zero mutations in \$HOME"
else
  fail "leaf-collision dry-run mutated \$HOME"
fi
rm "$TESTHOME/.codex/AGENTS.md" "$TESTHOME/.codex/AGENTS.md.backup"

mkfifo "$TESTHOME/.codex/AGENTS.md"
before="$(snapshot "$TESTHOME")"
if HOME="$TESTHOME" "$SETUP" --yes --dry-run > "$OUT" 2>&1; then
  fail "dry-run accepted an unsupported leaf destination type"
elif grep -q "refusing to replace unsupported destination type: $TESTHOME/.codex/AGENTS.md" "$OUT"; then
  ok "dry-run rejects unsupported leaf destination types"
else
  fail "unsupported leaf destination lacked a useful report"
fi
after="$(snapshot "$TESTHOME")"
if [ "$before" = "$after" ]; then
  ok "special-file collision dry-run made zero mutations in \$HOME"
else
  fail "special-file collision dry-run mutated \$HOME"
fi
rm "$TESTHOME/.codex/AGENTS.md"

# --dry-run --repair must preview fixes without applying them (reviewer P3 on
# PR #187: audit_link's repair branches used to rm/mv/ln unconditionally).
# Non-zero exit is expected — the entries are still broken after a preview.
mkdir -p "$TESTHOME/.agents/skills"
ln -s "$REPO_ROOT/agents/skills/reviewer-ghost" \
  "$TESTHOME/.agents/skills/reviewer-ghost"
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

if [ -L "$TESTHOME/.agents/skills/reviewer-ghost" ]; then
  ok "dry-run repair preserves orphan links found by nested runtime checkers"
else
  fail "dry-run repair let a nested checker delete an orphan link"
fi

if grep -q '\[DRY\] would fix' "$OUT"; then
  ok "repair dry-run guard engaged (would-fix preview printed)"
else
  fail "no '[DRY] would fix' lines — repair guard not exercised"
  sed 's/^/      | /' "$OUT"
fi

if grep -q '"${checker_args\[@\]}"' "$SETUP"; then
  fail "health audit still expands an empty array under nounset (breaks macOS Bash 3.2)"
else
  ok "health audit avoids Bash 3.2 empty-array nounset expansion"
fi

echo ""
echo "setup-dry-run: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
