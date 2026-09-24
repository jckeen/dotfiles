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
  'HOME="$H" "$SETUP" --show-services --services codex 2>/dev/null | grep -qx "services=codex"'

# ── Migration default: no saved selection keeps all three services ──
H="$(new_home)"
check "no saved selection resolves to all services" \
  'HOME="$H" "$SETUP" --show-services | grep -qx "services=claude,codex,antigravity"'

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

H="$(new_home)"
PATH="$CLEAN_PATH" HOME="$H" "$SETUP" --yes --dry-run --services antigravity > "$OUT" 2>&1
check "antigravity-only: Codex links skipped, Antigravity planned" \
  '! grep -q "would link $H/.codex/" "$OUT" && grep -q "would link $H/.gemini/config/GEMINI.md" "$OUT"'

# ── Noninteractive env var, and flag precedence ─────────────────────
H="$(new_home)"
check "DOTFILES_SERVICES selects noninteractively" \
  'DOTFILES_SERVICES=claude HOME="$H" "$SETUP" --show-services | grep -qx "services=claude"'
check "--services wins over DOTFILES_SERVICES" \
  'DOTFILES_SERVICES=claude HOME="$H" "$SETUP" --show-services --services=codex | grep -qx "services=codex"'
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

echo ""
echo "setup-services: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
