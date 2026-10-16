#!/usr/bin/env bash
# plugin-drift.test.sh — fixture tests for PluginDriftCheck.hook.ts.
#
# The manifest (claude/plugins.txt) is a USER-scope install list: setup.sh and
# sync-plugins.sh install without --scope, so a fresh clone reproduces only
# user-scope plugins. `claude plugin install` also offers --scope project and
# --scope local; neither belongs to the manifest, and neither may be counted
# in either drift direction. `user` is matched as an allowlist, so an
# unrecognised scope is not silently treated as a user install —
# render@claude-plugins-official is the live case the manifest deliberately
# excludes (PR #393). These tests run the SessionStart hook against throwaway
# HOMEs and DOTFILES_DIRs.
#
# sync-plugins.sh's fast path is covered here too, against the same fixtures:
# the hook's warning tells the operator to run that script, so the two must
# agree on what "installed" means or the warning never clears. The third
# consumer, setup.sh, reads `claude plugin list` instead of the JSON and shares
# the rule through user_scoped_plugins() in lib-checks.sh; its extraction is
# pinned at the end. The hook's mod scan (#594) — plugins whose
# hooks/hooks.json has a "modules" key, minus `# mods-ok:` lines — has its own
# fixtures. Run directly; exit 1 on any failure.
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
HOOK="$SCRIPT_DIR/../../hooks/PluginDriftCheck.hook.ts"
SYNC="$SCRIPT_DIR/../sync-plugins.sh"
LIB_CHECKS="$SCRIPT_DIR/../../../lib-checks.sh"

if ! command -v bun >/dev/null 2>&1; then
  echo "FAIL - bun is required to run the TypeScript SessionStart hook" >&2
  exit 1
fi

pass=0
failed=0
out=""
rc=0

# Fixture setup must fail LOUDLY, never silently. The suite runs without
# `set -e` so assertions keep going after a failed check, which means an
# unchecked mktemp/chmod would let run_sync fall through to the real `claude`
# on PATH and attempt actual plugin installs.
die() {
  echo "FAIL - fixture setup: $1" >&2
  exit 1
}

# run_hook <manifest-body> <installed-json> [settings-json]
# Builds a throwaway DOTFILES_DIR + HOME and captures the hook's stdout and rc.
run_hook() {
  local manifest="$1" installed="$2" settings="${3:-}"
  local D H
  D="$(mktemp -d)" || die "mktemp -d for DOTFILES_DIR"
  H="$(mktemp -d)" || die "mktemp -d for HOME"
  mkdir -p "$D/claude" "$H/.claude/plugins" || die "mkdir fixture dirs"
  printf '%s\n' "$manifest" > "$D/claude/plugins.txt" || die "write plugins.txt"
  printf '%s\n' "$installed" > "$H/.claude/plugins/installed_plugins.json" \
    || die "write installed_plugins.json"
  # No settings file at all => the scoping checks are skipped, which keeps
  # these assertions about install drift only.
  if [[ -n "$settings" ]]; then
    printf '%s\n' "$settings" > "$H/.claude/settings.json" || die "write settings.json"
  fi
  out="$(HOME="$H" DOTFILES_DIR="$D" bun "$HOOK" 2>&1)"
  rc=$?
  rm -rf "$D" "$H"
}

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (condition: $cond)"
    printf '%s\n' "$out" | sed 's/^/      | /'
  fi
}
outgrep() { grep -qF -- "$1" <<<"$out"; }

entry() { # entry <scope> — one installed_plugins.json install record
  printf '{"scope":"%s","installPath":"/tmp/x","version":"1.0.0"}' "$1"
}

MANIFEST_GLOBAL='# [global]
typescript-lsp@claude-plugins-official'

# ── reverse drift ignores project-scoped installs ───────────────────────
# The live regression: render is installed --scope project by the one repo
# that needs it, and is deliberately absent from the manifest. Reporting it
# as drift asks for a manifest edit that would make setup.sh install it at
# user scope on every machine.
run_hook "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)],
  \"render@claude-plugins-official\":[$(entry project)]
}}"
assert "project-scoped undeclared plugin is not reverse drift" \
  '! outgrep "Plugin drift (reverse)"'
assert "project-scoped plugin is not named at all" \
  '! outgrep "render@claude-plugins-official"'
assert "hook exits 0 (project-scoped)" "[ $rc -eq 0 ]"

# ── local scope is not user scope either ────────────────────────────────
# `claude plugin install --scope local` is a third scope the manifest does not
# own. Treating it as user-scope would both silence forward drift and raise a
# reverse-drift warning for a plugin nobody should add to the manifest.
run_hook "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)],
  \"render@claude-plugins-official\":[$(entry local)]
}}"
assert "local-scoped undeclared plugin is not reverse drift" \
  '! outgrep "Plugin drift (reverse)"'

run_hook "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry local)]
}}"
assert "manifest plugin installed only at local scope is missing" \
  'outgrep "are not installed"'

# ── an unrecognised scope does not satisfy the manifest ─────────────────
# `user` is an allowlist: a scope value added by a future CLI must not read as
# a user install. Worst case is a redundant idempotent install.
run_hook "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry sandbox)]
}}"
assert "unknown scope does not satisfy the manifest" 'outgrep "are not installed"'

# ── reverse drift still fires for user-scoped installs ──────────────────
run_hook "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)],
  \"sentry@claude-plugins-official\":[$(entry user)]
}}"
assert "user-scoped undeclared plugin is reverse drift" \
  'outgrep "Plugin drift (reverse)"'
assert "the undeclared user-scoped plugin is named" \
  'outgrep "sentry@claude-plugins-official"'

# ── a plugin installed at BOTH scopes counts as installed ───────────────
run_hook "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry project),$(entry user)]
}}"
assert "dual-scope declared plugin is neither missing nor undeclared" \
  '! outgrep "Plugin drift"'

# ── forward drift: manifest plugin present only at project scope ────────
# A fresh clone runs sync-plugins.sh at user scope, so a project-only install
# does not satisfy the manifest.
run_hook "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry project)]
}}"
assert "manifest plugin installed only at project scope is missing" \
  'outgrep "are not installed"'
assert "no reverse drift for the same project-scoped entry" \
  '! outgrep "Plugin drift (reverse)"'

# ── unrecognised record shapes stay installed (back-compat) ─────────────
# An older or future installed_plugins.json whose values are not arrays of
# scope records must parse as it did before scope filtering existed.
run_hook "$MANIFEST_GLOBAL" '{"version":1,"plugins":{
  "typescript-lsp@claude-plugins-official":{"version":"1.0.0"}
}}'
assert "non-array install record counts as installed" '! outgrep "Plugin drift"'

run_hook "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[{\"installPath\":\"/tmp/x\"}]
}}"
assert "install record without a scope counts as installed" '! outgrep "Plugin drift"'

# ── clean state is silent ───────────────────────────────────────────────
run_hook "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)]
}}"
assert "no output when manifest and user-scope installs agree" '[ -z "$out" ]'
assert "hook exits 0 (clean)" "[ $rc -eq 0 ]"

# ── scoping checks are unaffected by the scope filter ───────────────────
# A [per-project] plugin installed at user scope and enabled globally is the
# issue #214 warning; it must survive.
run_hook '# [global]
typescript-lsp@claude-plugins-official

# [per-project]
vercel@claude-plugins-official' \
  "{\"version\":2,\"plugins\":{
    \"typescript-lsp@claude-plugins-official\":[$(entry user)],
    \"vercel@claude-plugins-official\":[$(entry user)]
  }}" \
  '{"enabledPlugins":{"typescript-lsp@claude-plugins-official":true,
                      "vercel@claude-plugins-official":true}}'
assert "over-scoped [per-project] plugin still warns" 'outgrep "Plugin scoping"'
assert "over-scoped warning names the plugin" 'outgrep "vercel@claude-plugins-official"'

# ── mods: a plugin whose hooks/hooks.json has "modules" is named (#594) ──
# run_mods <manifest-body> — a throwaway HOME holding plugins of every origin:
#   cache/mkt/modded     hooks.json with "modules"     → warns
#   cache/mkt/vetted     with "modules", allowlisted?  → per manifest
#   cache/mkt/plain      settings hooks only           → silent
#   cache/mkt/broken     malformed hooks.json          → silent, no crash
#   synced/<bucket>/s    plugin.json name "syncmod", with "modules"
#   skills/sk            plugin.json name "skillmod", with "modules"
run_mods() {
  local manifest="$1"
  local D H C
  D="$(mktemp -d)" || die "mktemp -d for DOTFILES_DIR"
  H="$(mktemp -d)" || die "mktemp -d for HOME"
  C="$H/.claude/plugins/cache/mkt"
  mkdir -p "$D/claude" "$C"/{modded,vetted,plain,broken}/1.0.0/hooks \
    "$H/.claude/plugins/synced/bucket/s/hooks" "$H/.claude/plugins/synced/bucket/s/.claude-plugin" \
    "$H/.claude/skills/sk/hooks" "$H/.claude/skills/sk/.claude-plugin" \
    || die "mkdir mod fixture dirs"
  printf '%s\n' "$manifest" > "$D/claude/plugins.txt" || die "write plugins.txt"
  printf '{"version":2,"plugins":{"typescript-lsp@claude-plugins-official":[%s]}}\n' \
    "$(entry user)" > "$H/.claude/plugins/installed_plugins.json" \
    || die "write installed_plugins.json"
  local mod='{"modules":["./register.js"]}'
  printf '%s\n' "$mod" > "$C/modded/1.0.0/hooks/hooks.json" || die "write modded"
  printf '%s\n' "$mod" > "$C/vetted/1.0.0/hooks/hooks.json" || die "write vetted"
  printf '%s\n' '{"hooks":{"SessionStart":[]}}' > "$C/plain/1.0.0/hooks/hooks.json" \
    || die "write plain"
  printf '%s\n' '{"modules": [' > "$C/broken/1.0.0/hooks/hooks.json" || die "write broken"
  printf '%s\n' "$mod" > "$H/.claude/plugins/synced/bucket/s/hooks/hooks.json" || die "write synced"
  printf '%s\n' '{"name":"syncmod"}' > "$H/.claude/plugins/synced/bucket/s/.claude-plugin/plugin.json" \
    || die "write synced plugin.json"
  printf '%s\n' "$mod" > "$H/.claude/skills/sk/hooks/hooks.json" || die "write skills-dir"
  printf '%s\n' '{"name":"skillmod"}' > "$H/.claude/skills/sk/.claude-plugin/plugin.json" \
    || die "write skills-dir plugin.json"
  out="$(HOME="$H" DOTFILES_DIR="$D" bun "$HOOK" 2>&1)"
  rc=$?
  rm -rf "$D" "$H"
}

run_mods "$MANIFEST_GLOBAL"
assert "a cached mod is named" 'outgrep "• modded@mkt"'
assert "the mod warning has its own heading" 'outgrep "Plugin mods:"'
assert "a synced mod is named by its manifest name" 'outgrep "• syncmod@synced"'
assert "a skills-dir mod is named by its manifest name" 'outgrep "• skillmod@skills-dir"'
assert "a plugin without \"modules\" is not named" '! outgrep "plain@mkt"'
assert "a malformed hooks.json is not named" '! outgrep "broken@mkt"'
assert "hook exits 0 (mods, malformed hooks.json)" "[ $rc -eq 0 ]"
assert "no install-drift noise in the mods fixture" '! outgrep "Plugin drift"'

run_mods "$MANIFEST_GLOBAL
# mods-ok: vetted@mkt
#mods-ok: syncmod@synced"
assert "an allowlisted mod is silent" '! outgrep "vetted@mkt"'
assert "the allowlist accepts no space after #" '! outgrep "syncmod@synced"'
assert "allowlisting one mod does not silence another" 'outgrep "• modded@mkt"'

run_mods "$MANIFEST_GLOBAL
# mods-ok: modded@mkt
# mods-ok: vetted@mkt
# mods-ok: syncmod@synced
# mods-ok: skillmod@skills-dir"
assert "no output when every mod is allowlisted" '[ -z "$out" ]'

# ── sync-plugins.sh agrees with the hook on what "installed" means ──────
# The hook's remedy is "run sync-plugins.sh". If its fast path treated a
# project-scoped record as satisfying the manifest, it would exit 0 without
# installing and the warning would return every session.
#
# run_sync <manifest-body> <installed-json> [services-file-body] — stubs
# `claude` on PATH and records the plugins it was asked to install in
# $sync_installs and to uninstall in $sync_uninstalls. The saved service
# selection (lib-services.sh) lives under a throwaway XDG_CONFIG_HOME; with no
# third argument there is no saved selection, which means every service.
sync_out=""
sync_rc=0
sync_installs=""
sync_uninstalls=""
run_sync() {
  local manifest="$1" installed="$2" services="${3:-}"
  local D H B
  D="$(mktemp -d)" || die "mktemp -d for DOTFILES_DIR"
  H="$(mktemp -d)" || die "mktemp -d for HOME"
  B="$(mktemp -d)" || die "mktemp -d for the stub bin dir"
  mkdir -p "$D/claude" "$H/.claude/plugins" "$H/.config/dotfiles" \
    || die "mkdir fixture dirs"
  printf '%s\n' "$manifest" > "$D/claude/plugins.txt" || die "write plugins.txt"
  printf '%s\n' "$installed" > "$H/.claude/plugins/installed_plugins.json" \
    || die "write installed_plugins.json"
  if [[ -n "$services" ]]; then
    printf '%s\n' "$services" > "$H/.config/dotfiles/services" \
      || die "write the services file"
  fi
  cat > "$B/claude" <<STUB || die "write the claude stub"
#!/usr/bin/env bash
# Stub: record 'plugin install|uninstall <name>' calls, never touch the network.
if [ "\$1" = "plugin" ] && [ "\$2" = "install" ]; then
  echo "\$3" >> "$B/installs"
  echo "installed \$3"
elif [ "\$1" = "plugin" ] && [ "\$2" = "uninstall" ]; then
  echo "\$*" >> "$B/uninstalls"
  echo "uninstalled"
fi
exit 0
STUB
  chmod +x "$B/claude" || die "chmod the claude stub"
  : > "$B/installs" || die "create the stub's install log"
  : > "$B/uninstalls" || die "create the stub's uninstall log"
  # Isolation guard: if the stub is not what `claude` resolves to, the script
  # under test would reach the real CLI and install plugins for real.
  [[ -x "$B/claude" ]] || die "the claude stub is not executable"
  [[ "$(PATH="$B:$PATH" command -v claude)" == "$B/claude" ]] \
    || die "the claude stub does not shadow the real CLI on PATH"
  if [[ "$installed" == "<absent>" ]]; then
    rm -f "$H/.claude/plugins/installed_plugins.json" || die "rm installed json"
  fi
  # shellcheck disable=SC2034  # Read by assert's evaluated conditions.
  sync_out="$(HOME="$H" XDG_CONFIG_HOME="$H/.config" DOTFILES_DIR="$D" \
    PATH="$B:${SYNC_PATH:-$PATH}" env -u DOTFILES_SERVICES "$SYNC" 2>&1)"
  sync_rc=$?
  # shellcheck disable=SC2034  # Read by assert's evaluated conditions.
  sync_installs="$(cat "$B/installs")"
  # shellcheck disable=SC2034  # Read by assert's evaluated conditions.
  sync_uninstalls="$(cat "$B/uninstalls")"
  rm -rf "$D" "$H" "$B"
}

# Fast path must NOT fire when the only record is project-scoped.
run_sync "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry project)]
}}"
assert "sync installs a manifest plugin held only at project scope" \
  'grep -qxF "typescript-lsp@claude-plugins-official" <<<"$sync_installs"'
assert "sync exits 0 after installing" "[ $sync_rc -eq 0 ]"

# Fast path must fire (silently, no install) when user scope already has it.
run_sync "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)]
}}"
assert "sync fast-path installs nothing when user scope is satisfied" \
  '[ -z "$sync_installs" ]'
assert "sync fast-path is silent" '[ -z "$sync_out" ]'

# An undeclared project-scoped plugin is never installed at user scope.
run_sync "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)],
  \"render@claude-plugins-official\":[$(entry project)]
}}"
assert "sync never installs a plugin absent from the manifest" \
  '! grep -qF "render@" <<<"$sync_installs"'

# Local scope does not satisfy the fast path either.
run_sync "$MANIFEST_GLOBAL" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry local)]
}}"
assert "sync installs a manifest plugin held only at local scope" \
  'grep -qxF "typescript-lsp@claude-plugins-official" <<<"$sync_installs"'

# Unrecognised record shapes keep the old fast-path behavior.
run_sync "$MANIFEST_GLOBAL" '{"version":1,"plugins":{
  "typescript-lsp@claude-plugins-official":{"version":"1.0.0"}
}}'
assert "sync fast-path still trusts a non-array install record" \
  '[ -z "$sync_installs" ]'

# A `# mods-ok:` allowlist line (#594) is a comment to sync-plugins.sh: it is
# neither installed nor counted as missing by the fast path.
run_sync "$MANIFEST_GLOBAL
# mods-ok: modded@mkt" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)]
}}"
assert "sync never installs a mods-ok line" '[ -z "$sync_installs" ]'

# ── sync-plugins.sh honours the saved service selection ─────────────────
# The Codex plugin drives the Codex CLI. setup.sh skips it when Codex is not a
# selected service, and the every-launch sync must agree or it reinstalls the
# opted-out plugin (Codex review on PR #577).
MANIFEST_CODEX="$MANIFEST_GLOBAL
codex@openai-codex"
run_sync "$MANIFEST_CODEX" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)]
}}" "services=claude"
assert "sync skips the Codex plugin when Codex is deselected" \
  '! grep -qF "codex@openai-codex" <<<"$sync_installs"'
assert "sync fast path ignores a deselected service's plugin" \
  '[ -z "$sync_out" ] && [ $sync_rc -eq 0 ]'

run_sync "$MANIFEST_CODEX" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)]
}}" "services=claude,codex"
assert "sync installs the Codex plugin when Codex is selected" \
  'grep -qxF "codex@openai-codex" <<<"$sync_installs"'

# No saved selection manages every service (lib-services.sh migration rule).
run_sync "$MANIFEST_CODEX" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)]
}}"
assert "sync installs the Codex plugin with no saved selection" \
  'grep -qxF "codex@openai-codex" <<<"$sync_installs"'

# Plugins are Claude Code's: with Claude deselected there is nothing to sync.
run_sync "$MANIFEST_CODEX" '{"version":2,"plugins":{}}' "services=codex"
assert "sync installs nothing when Claude Code is deselected" \
  '[ -z "$sync_installs" ] && [ $sync_rc -eq 0 ]'

# A damaged selection file is refused, as setup.sh refuses it, not guessed at.
run_sync "$MANIFEST_CODEX" '{"version":2,"plugins":{}}' "services=bogus"
assert "sync refuses a damaged service selection" \
  '[ $sync_rc -ne 0 ] && [ -z "$sync_installs" ]'

# ── sync-plugins.sh reconciles explicit removals ────────────────────────
# Dropping a line from the manifest is not a removal signal: plugins absent
# from it may be the operator's own. Only a `# removed: <id>` line uninstalls,
# and only a user-scope install (Codex review on PR #574).
MANIFEST_REMOVED="$MANIFEST_GLOBAL
# removed: superpowers@claude-plugins-official"
run_sync "$MANIFEST_REMOVED" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)],
  \"superpowers@claude-plugins-official\":[$(entry user)],
  \"mine@claude-plugins-official\":[$(entry user)]
}}"
assert "sync uninstalls a user-scope plugin marked removed" \
  'grep -qxF "plugin uninstall --scope user superpowers@claude-plugins-official" <<<"$sync_uninstalls"'
assert "sync never uninstalls a plugin merely absent from the manifest" \
  '! grep -qF "mine@" <<<"$sync_uninstalls"'
assert "sync never installs a removed plugin" \
  '! grep -qF "superpowers@" <<<"$sync_installs"'
assert "sync exits 0 after uninstalling" "[ $sync_rc -eq 0 ]"

run_sync "$MANIFEST_REMOVED" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)],
  \"superpowers@claude-plugins-official\":[$(entry project)]
}}"
assert "sync leaves a project-scope install of a removed plugin alone" \
  '[ -z "$sync_uninstalls" ] && [ -z "$sync_out" ]'

run_sync "$MANIFEST_REMOVED
superpowers@claude-plugins-official" "{\"version\":2,\"plugins\":{
  \"typescript-lsp@claude-plugins-official\":[$(entry user)],
  \"superpowers@claude-plugins-official\":[$(entry user)]
}}"
assert "an active manifest line outranks a removed line" \
  '[ -z "$sync_uninstalls" ]'

# Removals that cannot be evaluated fail loudly instead of exiting 0.
run_sync "$MANIFEST_REMOVED" '{"version":2,"plugins":'
assert "malformed installed_plugins.json fails a pending removal" \
  '[ $sync_rc -ne 0 ] && grep -qF "superpowers@claude-plugins-official is marked removed but was not checked" <<<"$sync_out"'
assert "malformed installed_plugins.json still installs the manifest" \
  'grep -qxF "typescript-lsp@claude-plugins-official" <<<"$sync_installs"'
assert "malformed installed_plugins.json uninstalls nothing" \
  '[ -z "$sync_uninstalls" ]'

# python3 missing: a PATH holding only the tools sync-plugins.sh needs.
NOPY_BIN="$(mktemp -d)" || die "mktemp -d for the no-python PATH"
for tool in bash env dirname cat grep tail mktemp rm tr pwd readlink; do
  tool_path="$(command -v "$tool")" || die "missing tool $tool"
  ln -s "$tool_path" "$NOPY_BIN/$tool" || die "link $tool"
done
SYNC_PATH="$NOPY_BIN" run_sync "$MANIFEST_REMOVED" "{\"version\":2,\"plugins\":{
  \"superpowers@claude-plugins-official\":[$(entry user)]
}}"
assert "missing python3 fails a pending removal" \
  '[ $sync_rc -ne 0 ] && grep -qF "python3 is not on PATH" <<<"$sync_out"'
assert "missing python3 uninstalls nothing" '[ -z "$sync_uninstalls" ]'
rm -rf "$NOPY_BIN"

# No installed_plugins.json at all is a fresh machine, not a read failure.
run_sync "$MANIFEST_REMOVED" "<absent>"
assert "absent installed_plugins.json is not a removal failure" \
  '[ $sync_rc -eq 0 ] && [ -z "$sync_uninstalls" ]'

# ── setup.sh's listing-based match (lib-checks.sh) ──────────────────────
# setup.sh cannot read installed_plugins.json — it runs before the CLI state
# is guaranteed and uses `claude plugin list`. That listing reports project-
# and local-scoped installs from any directory, so the same scope rule has to
# apply to its text form or setup.sh skips the user-scope install.
# shellcheck source=lib-checks.sh
if ! . "$LIB_CHECKS"; then
  echo "FAIL - fixture setup: cannot source $LIB_CHECKS" >&2
  exit 1
fi

listing() { # listing <name> <scope> [<name> <scope> ...]
  while [ "$#" -ge 2 ]; do
    printf '  \xe2\x9d\xaf %s\n    Version: 1.0.0\n    Scope: %s\n    Status: enabled\n\n' "$1" "$2"
    shift 2
  done
}

out="$(listing \
  typescript-lsp@claude-plugins-official user \
  render@claude-plugins-official project \
  something@marketplace local | user_scoped_plugins)"
assert "user-scope entry is extracted" \
  'grep -qxF "typescript-lsp@claude-plugins-official" <<<"$out"'
assert "project-scope entry is not extracted" \
  '! grep -qF "render@" <<<"$out"'
assert "local-scope entry is not extracted" \
  '! grep -qF "something@" <<<"$out"'

# An entry with no Scope line, or one this parser does not know, is left out
# so the caller reinstalls it. `claude plugin install` is idempotent.
out="$(printf '  \xe2\x9d\xaf noscope@marketplace\n    Version: 1.0.0\n\n' | user_scoped_plugins)"
assert "entry without a Scope line is not extracted" '[ -z "$out" ]'
out="$(listing future@marketplace enterprise | user_scoped_plugins)"
assert "entry with an unknown scope is not extracted" '[ -z "$out" ]'

# Whole-line matching: a prefix must not satisfy a longer manifest entry.
out="$(listing code-review@claude-plugins-official user | user_scoped_plugins)"
assert "extracted ids match whole lines only" \
  '! grep -qxF "code-review-2@claude-plugins-official" <<<"$out"'

out="$(printf '' | user_scoped_plugins)"
assert "empty listing extracts nothing" '[ -z "$out" ]'

echo
echo "passed: $pass  failed: $failed"
[ "$failed" -eq 0 ] || exit 1
