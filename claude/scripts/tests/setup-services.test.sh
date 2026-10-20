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

echo ""
echo "setup-services: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
