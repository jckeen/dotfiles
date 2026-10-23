#!/usr/bin/env bash
# setup-services.test.sh — agent-service selection in setup.sh (issue #425).
#
# Covers lib-services.sh parsing/persistence directly, then drives setup.sh
# against throwaway HOMEs: Claude+Codex with Antigravity absent, single-service
# selection, the noninteractive flag and env var, interactive selection with
# piped answers, reruns that keep a saved choice, later opt-in, and --repair
# leaving a deselected service's state untouched. Every --dry-run case also
# asserts a byte-identical HOME snapshot (lib-snapshot.sh), so the selection
# file is never written by a preview. Run directly; exit 1 on any failure.
# Wired into CI through setup-dry-run.test.sh, which runs this suite.
# shellcheck disable=SC2034  # rc/before/... are read inside check()'s eval'd assertions
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"
# Same reason as setup-dry-run.test.sh (#435): agents run suites from linked
# worktrees; every run here targets a throwaway HOME.
export DOTFILES_ALLOW_LINKED_WORKTREE=1
# A developer's real selection must never leak in (or be written to).
unset XDG_CONFIG_HOME DOTFILES_SERVICES

pass=0
failed=0
ok()   { pass=$((pass + 1));   echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

# shellcheck source=claude/scripts/tests/lib-snapshot.sh
. "$SCRIPT_DIR/lib-snapshot.sh"
# shellcheck source=lib-services.sh
. "$REPO_ROOT/lib-services.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
OUT="$ROOT/out"
# setup.sh finds the private repo at $DEV_DIR/claude-memory, and DEV_DIR defaults
# to the checkout's parent, so a checkout directly under ~/dev would run the
# operator's REAL bootstrap against the throwaway HOME (#701). Point it at an
# empty directory under the test root.
mkdir -p "$ROOT/dev"
export DOTFILES_DEV_DIR="$ROOT/dev"

# /usr/bin:/bin carries the basics but not the agent CLIs (they install under
# ~/.local/bin), so the install sections plan their installers instead of
# reporting "already installed" (same trick as setup-dry-run.test.sh).
CLEAN_PATH="/usr/bin:/bin"

new_home() { mktemp -d "$ROOT/home.XXXXXX"; }
saved_file() { printf '%s/.config/dotfiles/services\n' "$1"; }
seed_saved() {
  mkdir -p "$1/.config/dotfiles"
  printf 'services=%s\n' "$2" > "$(saved_file "$1")"
}

# ── lib-services.sh unit checks ─────────────────────────────────────
check "normalize orders, dedupes, and maps aliases" \
  '[ "$(services_normalize "AGY, claude-code,codex,claude")" = "claude,codex,antigravity" ]'
check "normalize expands all" '[ "$(services_normalize all)" = "claude,codex,antigravity" ]'
check "normalize rejects an unknown service" '! services_normalize "claude,cursor" 2>/dev/null'
check "normalize rejects an empty selection" '! services_normalize " , " 2>/dev/null'

H="$(new_home)"
check "config path defaults to ~/.config/dotfiles/services" \
  '[ "$(HOME="$H" services_config_path)" = "$H/.config/dotfiles/services" ]'
check "absolute XDG_CONFIG_HOME is honored" \
  '[ "$(HOME="$H" XDG_CONFIG_HOME=/x/cfg services_config_path)" = "/x/cfg/dotfiles/services" ]'
check "relative XDG_CONFIG_HOME is ignored (XDG spec)" \
  '[ "$(HOME="$H" XDG_CONFIG_HOME=rel services_config_path)" = "$H/.config/dotfiles/services" ]'
rc=0; services_load_saved "$(saved_file "$H")" >/dev/null 2>&1 || rc=$?
check "absent selection file loads as rc 1 (migration default applies)" '[ "$rc" -eq 1 ]'
services_save "$(saved_file "$H")" "claude,codex"
check "save/load round-trips a selection" \
  '[ "$(services_load_saved "$(saved_file "$H")")" = "claude,codex" ]'
check "saved file is a plain assignment, not shell to source" \
  'grep -qx "services=claude,codex" "$(saved_file "$H")"'
printf 'services=claude,$(touch %s/pwned)\n' "$H" > "$(saved_file "$H")"
rc=0; services_load_saved "$(saved_file "$H")" >/dev/null 2>&1 || rc=$?
check "a malformed file is rejected (rc 2) and never executed" '[ "$rc" -eq 2 ] && [ ! -e "$H/pwned" ]'
check "setup.sh refuses to guess past a malformed selection file" \
  '! HOME="$H" "$SETUP" --show-services >/dev/null 2>&1'
check "--services replaces a malformed selection file" \
  'grep -qx "services=codex" <<< "$(HOME="$H" "$SETUP" --show-services --services codex 2>/dev/null)"'
check "DOTFILES_SERVICES also overrides a malformed selection file" \
  'grep -qx "services=claude" <<< "$(DOTFILES_SERVICES=claude HOME="$H" "$SETUP" --show-services 2>/dev/null)"'
check "--help still works past a malformed selection file" \
  'HOME="$H" "$SETUP" --help 2>/dev/null | grep -q "^Usage: ./setup.sh"'
rm -f "$(saved_file "$H")"
mkdir -p "$(saved_file "$H")"
rc=0; services_save "$(saved_file "$H")" "claude" 2>/dev/null || rc=$?
check "save refuses a directory at the selection path instead of moving into it" \
  '[ "$rc" -ne 0 ] && [ -z "$(ls -A "$(saved_file "$H")")" ]'
rmdir "$(saved_file "$H")"

# ── Migration default: no saved selection keeps all three services ──
H="$(new_home)"
check "no saved selection resolves to all services" \
  'grep -qx "services=claude,codex,antigravity" <<< "$(HOME="$H" "$SETUP" --show-services)"'

# ── Claude + Codex, Antigravity absent (the issue's concrete case) ──
H="$(new_home)"
before="$(snapshot "$H")"
PATH="$CLEAN_PATH" HOME="$H" "$SETUP" --yes --dry-run --services claude,codex > "$OUT" 2>&1
rc=$?
check "claude,codex dry-run exits 0" '[ "$rc" -eq 0 ]'
check "claude,codex dry-run makes zero writes (selection file included)" '[ "$(snapshot "$H")" = "$before" ]'
check "claude,codex: Antigravity installer is not planned" \
  '! grep -q "antigravity.google/cli/install.sh" "$OUT"'
check "claude,codex: no ~/.gemini links are planned" '! grep -q "would link $H/.gemini" "$OUT"'
check "claude,codex: Antigravity health check is skipped" \
  '! grep -q "Checking Antigravity public-safe config" "$OUT" && grep -q "Antigravity not selected" "$OUT"'
check "claude,codex: Codex and Claude links are still planned" \
  'grep -q "would link $H/.codex/AGENTS.md" "$OUT" && grep -q "would link $H/.claude/CLAUDE.md" "$OUT"'
check "claude,codex: the selection would be saved" \
  'grep -Fq "[DRY] would save service selection (claude,codex) to $(saved_file "$H")" "$OUT"'
check "claude,codex: deselection promises existing config is left in place" \
  'grep -q "left in place" "$OUT"'
check "claude,codex: completion does not suggest agy" \
  '! grep -q "run '"'"'agy'"'"'" "$OUT"'

# ── Single service ──────────────────────────────────────────────────
H="$(new_home)"
before="$(snapshot "$H")"
PATH="$CLEAN_PATH" HOME="$H" "$SETUP" --yes --dry-run --services codex > "$OUT" 2>&1
check "codex-only dry-run makes zero writes" '[ "$(snapshot "$H")" = "$before" ]'
check "codex-only: Claude installer and Claude config are skipped" \
  '! grep -q "claude.ai/install.sh" "$OUT" && ! grep -q "would link $H/.claude/CLAUDE.md" "$OUT" && ! grep -q "would link $H/.claude/hooks/" "$OUT"'
check "codex-only: shared ~/.claude/scripts tooling is still linked" \
  'grep -q "would link $H/.claude/scripts/" "$OUT"'
check "codex-only: Antigravity is skipped" '! grep -q "would link $H/.gemini" "$OUT"'
check "codex-only: completion points at cx" 'grep -q "Try next: cx" "$OUT"'
# §1b audio routing exists only for Claude /voice; it only runs on WSL, so
# the assertion is skipped elsewhere (CI's Linux runners).
if grep -qi microsoft /proc/version 2>/dev/null; then
  check "codex-only: WSL audio setup for Claude /voice is skipped" \
    '! grep -q "Set up audio routing for Claude /voice" "$OUT"'
  PATH="$CLEAN_PATH" HOME="$(new_home)" "$SETUP" --yes --dry-run --services claude > "$ROOT/out.claude" 2>&1
  check "claude-only: WSL audio setup for Claude /voice is still offered" \
    'grep -q "Set up audio routing for Claude /voice" "$ROOT/out.claude"'
else
  echo "skip - codex-only WSL audio check (not running on WSL)"
fi

H="$(new_home)"
PATH="$CLEAN_PATH" HOME="$H" "$SETUP" --yes --dry-run --services antigravity > "$OUT" 2>&1
check "antigravity-only: Codex links skipped, Antigravity planned" \
  '! grep -q "would link $H/.codex/" "$OUT" && grep -q "would link $H/.gemini/config/GEMINI.md" "$OUT"'

# ── Noninteractive env var, and flag precedence ─────────────────────
H="$(new_home)"
check "DOTFILES_SERVICES selects noninteractively" \
  'grep -qx "services=claude" <<< "$(DOTFILES_SERVICES=claude HOME="$H" "$SETUP" --show-services)"'
check "--services wins over DOTFILES_SERVICES" \
  'grep -qx "services=codex" <<< "$(DOTFILES_SERVICES=claude HOME="$H" "$SETUP" --show-services --services=codex)"'
check "an unknown service fails closed" '! HOME="$H" "$SETUP" --show-services --services bogus >/dev/null 2>&1'

# ── Interactive selection (piped answers) ───────────────────────────
H="$(new_home)"
before="$(snapshot "$H")"
printf 'y\ny\nn\ny\n' | PATH="$CLEAN_PATH" HOME="$H" "$SETUP" --dry-run > "$OUT" 2>&1
check "interactive answers select claude,codex" \
  'grep -q "Services: claude,codex (chosen interactively)" "$OUT"'
check "interactive dry-run makes zero writes" '[ "$(snapshot "$H")" = "$before" ]'
printf 'n\nn\nn\nn\nn\ny\ny\n' | PATH="$CLEAN_PATH" HOME="$H" "$SETUP" --dry-run > "$OUT" 2>&1
check "interactive re-asks when nothing is selected" \
  'grep -q "Select at least one service" "$OUT" && grep -q "Services: antigravity (chosen interactively)" "$OUT"'

# ── Rerun keeps a saved choice ──────────────────────────────────────
H="$(new_home)"
seed_saved "$H" "claude,codex"
before="$(snapshot "$H")"
PATH="$CLEAN_PATH" HOME="$H" "$SETUP" --dry-run < /dev/null > "$OUT" 2>&1
check "rerun reuses the saved selection without prompting" \
  'grep -q "Services: claude,codex (saved in" "$OUT" && ! grep -q "Set up Claude Code?" "$OUT"'
check "rerun with an unchanged selection plans no save" '! grep -q "would save service selection" "$OUT"'
check "rerun dry-run makes zero writes" '[ "$(snapshot "$H")" = "$before" ]'
HOME="$H" "$SETUP" --check > "$OUT" 2>&1
check "--check honors the saved selection" \
  'grep -q "Checking Codex public-safe config" "$OUT" && ! grep -q "Checking Antigravity public-safe config" "$OUT"'

# ── Later opt-in ────────────────────────────────────────────────────
PATH="$CLEAN_PATH" HOME="$H" "$SETUP" --yes --dry-run --services claude,codex,antigravity > "$OUT" 2>&1
check "opt-in via --services plans Antigravity and the new save" \
  'grep -q "would link $H/.gemini/config/GEMINI.md" "$OUT" && grep -Fq "would save service selection (claude,codex,antigravity)" "$OUT"'
printf '\n\ny\n\n' | PATH="$CLEAN_PATH" HOME="$H" "$SETUP" --dry-run --select-services > "$OUT" 2>&1
check "opt-in via --select-services keeps saved answers as defaults" \
  'grep -q "Services: claude,codex,antigravity (chosen interactively)" "$OUT"'
check "opt-in dry-run leaves the saved file unchanged" \
  'grep -qx "services=claude,codex" "$(saved_file "$H")"'

# ── Deselection never deletes: --repair leaves Antigravity state alone ──
H="$(new_home)"
seed_saved "$H" "codex"
mkdir -p "$H/.gemini/config" "$H/.gemini/antigravity-cli"
ln -s "$ROOT/gone/hooks.json" "$H/.gemini/config/hooks.json"
printf 'token\n' > "$H/.gemini/antigravity-cli/antigravity-oauth-token"
gem_before="$(snapshot "$H/.gemini")"
HOME="$H" "$SETUP" --repair > "$OUT" 2>&1
check "--repair does not touch a deselected service's config or credentials" \
  '[ "$(snapshot "$H/.gemini")" = "$gem_before" ]'
check "--repair skips Claude-only links when Claude is deselected" \
  '[ ! -e "$H/.claude/CLAUDE.md" ] && [ -L "$H/.claude/scripts/codex-review-gate.sh" ]'

# ── --repair counts a migration that archived changed content (#638) ──
# A legacy per-file skill dir whose content changes under the migration is
# moved to .migrated-skill-dirs/kept/ and the migration returns 1; alink then
# relinks the bundle, but the audit must still count the failure. A fake perl
# swaps the archived SKILL.md link for a real file right after the rename.
SKILL_NAME="$(cd "$REPO_ROOT/claude/skills" && for d in */; do [ -f "$d/SKILL.md" ] && { echo "${d%/}"; break; }; done)"
repair_legacy() {
  local h="$1" bin="$2"
  seed_saved "$h" "claude"
  mkdir -p "$h/.claude/skills/$SKILL_NAME"
  ln -s "$REPO_ROOT/claude/skills/$SKILL_NAME/SKILL.md" "$h/.claude/skills/$SKILL_NAME/SKILL.md"
  PATH="$bin:$PATH" HOME="$h" "$SETUP" --repair > "$OUT" 2>&1
  echo "rc=$?" >> "$OUT"
}
broken_count() { sed -n 's/^  Broken: *\([0-9]*\)$/\1/p' "$OUT" | tail -1; }
H="$(new_home)"
mkdir -p "$ROOT/nobin"
repair_legacy "$H" "$ROOT/nobin"
base_broken="$(broken_count)"
base_rc="$(tail -1 "$OUT")"
check "--repair converts a clean legacy skill dir" \
  "[ \"\$(readlink \"$H/.claude/skills/$SKILL_NAME\")\" = \"$REPO_ROOT/claude/skills/$SKILL_NAME\" ]"
H="$(new_home)"
SWAP="$ROOT/swapbin"
mkdir -p "$SWAP"
REAL_PERL="$(command -v perl)"
cat > "$SWAP/perl" <<FAKE
#!/bin/bash
"$REAL_PERL" "\$@"; rc=\$?
if [ "\$rc" -eq 0 ] && [ "\$3" = "$H/.claude/skills/$SKILL_NAME" ] && [ -L "\$4/SKILL.md" ]; then
  rm "\$4/SKILL.md" && printf 'mine\\n' > "\$4/SKILL.md"
fi
exit \$rc
FAKE
chmod +x "$SWAP/perl"
repair_legacy "$H" "$SWAP"
check "--repair reports the changed migration as FAILED and where it was kept" \
  "grep -q 'FAILED.*skills/$SKILL_NAME' \"$OUT\" && grep -q '.migrated-skill-dirs/kept/$SKILL_NAME\.' \"$OUT\""
check "--repair counts it: one more broken than the clean run, non-zero exit" \
  "[ \"\$(broken_count)\" -eq \$((base_broken + 1)) ] && grep -qx 'rc=[1-9][0-9]*' \"$OUT\""
check "--repair keeps the changed content" \
  "grep -qx mine \"$H\"/.claude/.migrated-skill-dirs/kept/$SKILL_NAME.*/SKILL.md"

# A rival that relinks the bundle between --repair's outer legacy check and
# the migration's own re-check has finished the repair: nothing was archived,
# so it is no error (PR #682 review). A fake readlink plays the rival on the
# second readlink of the legacy entry (the first is the outer check).
H="$(new_home)"
RIVAL="$ROOT/rivalbin"
mkdir -p "$RIVAL"
REAL_READLINK="$(command -v readlink)"
LEG="$H/.claude/skills/$SKILL_NAME"
cat > "$RIVAL/readlink" <<FAKE
#!/bin/bash
if [ "\$1" = "$LEG/SKILL.md" ]; then
  n=\$(( \$(cat "$ROOT/rival-calls" 2>/dev/null || echo 0) + 1 ))
  echo "\$n" > "$ROOT/rival-calls"
  if [ "\$n" -eq 2 ]; then
    rm "$LEG/SKILL.md" && rmdir "$LEG" && ln -sn "$REPO_ROOT/claude/skills/$SKILL_NAME" "$LEG"
  fi
fi
exec "$REAL_READLINK" "\$@"
FAKE
chmod +x "$RIVAL/readlink"
repair_legacy "$H" "$RIVAL"
check "--repair: the rival relinked between the checks" \
  "[ \"\$(cat \"$ROOT/rival-calls\")\" -ge 2 ] && [ \"\$(readlink \"$LEG\")\" = \"$REPO_ROOT/claude/skills/$SKILL_NAME\" ]"
check "--repair: a rival-completed migration is no error (same Broken as a clean run)" \
  "[ \"\$(broken_count)\" -eq \"$base_broken\" ] && ! grep -q 'FAILED.*skills/$SKILL_NAME' \"$OUT\" && [ ! -e \"$H/.claude/.migrated-skill-dirs\" ]"
check "--repair: a clean legacy run exits 0" "[ \"$base_rc\" = rc=0 ]"

# A foreign link swapped in just before the rename is someone's own config,
# not a rival's repair: it is archived under kept/ and counted (round 10).
H="$(new_home)"
FOREIGN="$ROOT/foreignbin"
mkdir -p "$FOREIGN" "$ROOT/my-own-skill"
LEG="$H/.claude/skills/$SKILL_NAME"
cat > "$FOREIGN/perl" <<FAKE
#!/bin/bash
if [ "\$3" = "$LEG" ] && [ -d "$LEG" ] && [ ! -L "$LEG" ]; then
  rm "$LEG"/* && rmdir "$LEG" && ln -sn "$ROOT/my-own-skill" "$LEG"
fi
exec "$REAL_PERL" "\$@"
FAKE
chmod +x "$FOREIGN/perl"
repair_legacy "$H" "$FOREIGN"
check "--repair: a grabbed foreign link is kept, intact" \
  "[ \"\$(readlink \"$H\"/.claude/.migrated-skill-dirs/kept/$SKILL_NAME.*)\" = \"$ROOT/my-own-skill\" ]"
check "--repair: and counted (FAILED, one more Broken, non-zero exit)" \
  "grep -q 'FAILED.*skills/$SKILL_NAME' \"$OUT\" && [ \"\$(broken_count)\" -eq \$((base_broken + 1)) ] && grep -qx 'rc=[1-9][0-9]*' \"$OUT\""

# ── Install path: changed content is kept, the skill still gets linked ──
# setup.sh's install path used to exit on a failed migration before
# link_file, leaving the skill absent (PR #682 review). Its claude-tree link
# block (from `_tree_links=0` to the summary line) runs here in isolation:
# a fixture repo, stubbed link_file and claude_link_managed, and a fake perl
# that changes the moved dir right after the rename.
BLOCK="$ROOT/tree-block.sh"
awk '/^_tree_links=0$/{on=1} /^if service_selected claude; then$/{if(on) exit} on' "$SETUP" > "$BLOCK"
check "install path: the tree-link block was extracted" "grep -q 'symlink_migrate_legacy_skill_dir' \"$BLOCK\""
TR="$ROOT/tree-repo"
H="$(new_home)"
mkdir -p "$TR/claude/skills/demo" "$H/.claude/skills/demo"
printf 'nolink.txt\n' > "$TR/claude/nolink.txt"
printf -- '---\nname: demo\n---\n' > "$TR/claude/skills/demo/SKILL.md"
ln -s "$TR/claude/skills/demo/SKILL.md" "$H/.claude/skills/demo/SKILL.md"
TSWAP="$ROOT/treeswap"
mkdir -p "$TSWAP"
cat > "$TSWAP/perl" <<FAKE
#!/bin/bash
"$REAL_PERL" "\$@"; rc=\$?
if [ "\$rc" -eq 0 ] && [ "\$3" = "$H/.claude/skills/demo" ] && [ -L "\$4/SKILL.md" ]; then
  rm "\$4/SKILL.md" && printf 'mine\\n' > "\$4/SKILL.md"
fi
exit \$rc
FAKE
chmod +x "$TSWAP/perl"
(
  PATH="$TSWAP:$PATH"
  DOTFILES_DIR="$TR" HOME_DIR="$H" DRY_RUN=0
  # shellcheck source=../../../lib-symlinks.sh
  . "$REPO_ROOT/lib-symlinks.sh"
  claude_link_managed() { return 0; }
  link_file() { [ -e "$2" ] || [ -L "$2" ] || ln -sn "$1" "$2"; }
  # shellcheck disable=SC1090
  . "$BLOCK"
) > "$OUT" 2>&1
tree_rc=$?
check "install path: the bundle is linked despite the changed content" \
  "[ \"\$(readlink \"$H/.claude/skills/demo\")\" = \"$TR/claude/skills/demo\" ]"
check "install path: the changed content is in kept/" \
  "grep -qx mine \"$H\"/.claude/.migrated-skill-dirs/kept/demo.*/SKILL.md"
check "install path: the error is reported and the exit is non-zero" \
  "[ \"$tree_rc\" -ne 0 ] && grep -q 'ERROR: .*changed during migration.*skills/demo' \"$OUT\""

# ── #701 guard: no suite may reach the operator's real claude-memory ─────────
# setup.sh looks for $DEV_DIR/claude-memory/bootstrap.sh, and DEV_DIR defaults
# to the checkout's parent, so a checkout directly under ~/dev ran the real
# private bootstrap against a throwaway HOME. The layout is faked here, never
# the real ~/dev: a symlink named dotfiles inside a throwaway dev directory
# points at this checkout (setup.sh derives DEV_DIR from its logical path), next
# to a planted claude-memory whose bootstrap drops a sentinel when executed.
ISO="$ROOT/iso701"
FAKE_DEV="$ISO/dev"
SENTINEL="$ISO/bootstrap-ran"
mkdir -p "$ISO/home" "$ISO/empty" "$FAKE_DEV/claude-memory" "$FAKE_DEV/codex-memory" "$FAKE_DEV/agy-memory"
ln -s "$REPO_ROOT" "$FAKE_DEV/dotfiles"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$SENTINEL" \
  > "$FAKE_DEV/claude-memory/bootstrap.sh"
chmod +x "$FAKE_DEV/claude-memory/bootstrap.sh"
CODEX_SENTINEL="$ISO/codex-bootstrap-ran"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$CODEX_SENTINEL" \
  > "$FAKE_DEV/codex-memory/bootstrap.sh"
chmod +x "$FAKE_DEV/codex-memory/bootstrap.sh"
AGY_SENTINEL="$ISO/agy-bootstrap-ran"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$AGY_SENTINEL" \
  > "$FAKE_DEV/agy-memory/bootstrap.sh"
chmod +x "$FAKE_DEV/agy-memory/bootstrap.sh"
run_iso() {
  env -i PATH="$CLEAN_PATH" HOME="$ISO/home" TERM=dumb LC_ALL=C \
    DOTFILES_ALLOW_LINKED_WORKTREE=1 CODEX_MEMORY_REPO="$ISO/codex-memory" \
    "$@" "$FAKE_DEV/dotfiles/setup.sh" --yes --dry-run 2>&1
}
# Same, without the explicit CODEX_MEMORY_REPO and with every service: the
# codex-memory and agy-memory siblings must follow the override too, not the
# checkout's parent (Codex bot on PR #729).
run_iso_codex() {
  env -i PATH="$CLEAN_PATH" HOME="$ISO/home" TERM=dumb LC_ALL=C \
    DOTFILES_ALLOW_LINKED_WORKTREE=1 DOTFILES_SERVICES=claude,codex,antigravity \
    "$@" "$FAKE_DEV/dotfiles/setup.sh" --yes --dry-run 2>&1
}
# Control: without an override the sibling bootstrap IS found, so the isolated
# case below cannot pass merely because the fixture never reached setup.sh.
iso_out="$(run_iso)"
check "#701 control: no override falls back to the checkout's parent" \
  '[ -e "$SENTINEL" ] && grep -Fq "$FAKE_DEV/claude-memory/bootstrap.sh" <<< "$iso_out"'
rm -f "$SENTINEL"
iso_out="$(run_iso DOTFILES_DEV_DIR="$ISO/empty")"
check "#701 DOTFILES_DEV_DIR keeps setup.sh off the checkout's sibling claude-memory" \
  '[ ! -e "$SENTINEL" ] && ! grep -Fq "$FAKE_DEV/claude-memory" <<< "$iso_out"'
check "#701 setup.sh reports the overridden location" \
  'grep -Fq "$ISO/empty/claude-memory/bootstrap.sh" <<< "$iso_out"'
check "#701 a relative DOTFILES_DEV_DIR is refused" \
  '! run_iso DOTFILES_DEV_DIR=relative/dir >/dev/null'
codex_out="$(run_iso_codex DOTFILES_DEV_DIR="$ISO/empty")"
check "#701 the codex-memory sibling follows DOTFILES_DEV_DIR too" \
  '[ ! -e "$CODEX_SENTINEL" ] && ! grep -Fq "$FAKE_DEV/codex-memory" <<< "$codex_out"'
check "#701 the agy-memory sibling follows DOTFILES_DEV_DIR too" \
  '[ ! -e "$AGY_SENTINEL" ] && ! grep -Fq "$FAKE_DEV/agy-memory" <<< "$codex_out"'
# The health checkers derive the same sibling paths (setup.sh --check runs
# them), so they must follow the override too. Planted files make the control
# run name the planted sibling; the override run must not.
printf 'planted\n' > "$FAKE_DEV/codex-memory/AGENTS.local.md"
printf 'planted\n' > "$FAKE_DEV/agy-memory/GEMINI.local.md"
# The checkers stop early on an uninitialised tool, so give the throwaway home
# the two directories they look for before reaching the memory-repo section.
mkdir -p "$ISO/home/.codex" "$ISO/home/.gemini/config"
run_checker() {
  local script="$1"; shift
  env -i PATH="$CLEAN_PATH" HOME="$ISO/home" TERM=dumb LC_ALL=C "$@" \
    "$FAKE_DEV/dotfiles/$script" 2>&1 || true
}
for c in check-codex.sh:AGENTS.local.md check-antigravity.sh:GEMINI.local.md check-claude.sh:claude-memory; do
  script="${c%%:*}"; planted="${c##*:}"
  ctrl_out="$(run_checker "$script")"
  over_out="$(run_checker "$script" DOTFILES_DEV_DIR="$ISO/empty")"
  case "$script" in
    check-claude.sh)
      check "#701 $script control: without the override the planted sibling is in play" \
        'grep -Fq "MISSING  memory" <<< "$ctrl_out"'
      check "#701 $script never reports the planted sibling under DOTFILES_DEV_DIR" \
        '! grep -Fq "MISSING  memory" <<< "$over_out"' ;;
    *)
      check "#701 $script control: without the override the planted sibling is in play" \
        'grep -Fq "$planted" <<< "$ctrl_out"'
      check "#701 $script never reports the planted sibling under DOTFILES_DEV_DIR" \
        '! grep -Fq "$planted" <<< "$over_out" && ! grep -Fq "$FAKE_DEV" <<< "$over_out"' ;;
  esac
done
check_out="$(env -i PATH="$CLEAN_PATH" HOME="$ISO/home" TERM=dumb LC_ALL=C \
  DOTFILES_ALLOW_LINKED_WORKTREE=1 DOTFILES_SERVICES=claude,codex,antigravity DOTFILES_DEV_DIR="$ISO/empty" \
  "$FAKE_DEV/dotfiles/setup.sh" --check 2>&1 || true)"
check "#701 setup.sh --check never reports a planted sibling under DOTFILES_DEV_DIR" \
  '! grep -Fq "$FAKE_DEV/codex-memory" <<< "$check_out" && ! grep -Fq "$FAKE_DEV/agy-memory" <<< "$check_out"'
# The override's edge cases are checked on the shared helper itself, never by
# running setup.sh with DOTFILES_DEV_DIR=/ (that would look for, and in a
# dry run still execute, a real /claude-memory/bootstrap.sh on the host).
# shellcheck source=lib-checks.sh
. "$REPO_ROOT/lib-checks.sh"
check "#701 helper: DOTFILES_DEV_DIR=/ keeps the root, not an empty dev dir" \
  '[ "$(DOTFILES_DEV_DIR=/ dotfiles_dev_dir "$REPO_ROOT")" = / ]'
check "#701 helper: one trailing slash is trimmed" \
  '[ "$(DOTFILES_DEV_DIR="$ISO/empty/" dotfiles_dev_dir "$REPO_ROOT")" = "$ISO/empty" ]'
check "#701 helper: a relative override is refused" \
  '! DOTFILES_DEV_DIR=relative/dir dotfiles_dev_dir "$REPO_ROOT" 2>/dev/null'
check "#701 helper: no override falls back to the checkout parent" \
  '[ "$(env -u DOTFILES_DEV_DIR bash -c ". \"$REPO_ROOT/lib-checks.sh\"; dotfiles_dev_dir /a/b/dotfiles")" = /a/b ]'
# Every suite that runs setup.sh sets the override before its first run.
for s in setup-services setup-dry-run setup-fuzz-layouts; do
  f="$SCRIPT_DIR/$s.test.sh"
  setline="$(grep -n 'DOTFILES_DEV_DIR=' "$f" | head -1 | cut -d: -f1)"
  runline="$(grep -n '"\$SETUP" --' "$f" | head -1 | cut -d: -f1)"
  check "#701 $s sets DOTFILES_DEV_DIR before running setup.sh" \
    '[ -n "$setline" ] && [ "$setline" -lt "$runline" ]'
done

echo ""
echo "setup-services: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
