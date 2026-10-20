#!/usr/bin/env bash
# settings-example.test.sh — the public settings template (issue #588).
#
# Claude Code runs only the hooks registered in ~/.claude/settings.json, and a
# clone without the private claude-memory repo gets its settings.json from
# claude/settings.example.json. This is the public counterpart of
# check-hooks-wired.sh (which can only see the live, private settings): every
# claude/hooks/*.sh|*.ts must be registered in the example, the status line
# must point at statusline.sh, and the template must stay public-safe (no
# permissions, MCP servers or env). It also asserts the symlink pass never
# deploys the example into ~/.claude, and exercises setup.sh's
# seed_claude_settings against a throwaway HOME: creates once, never
# overwrites, previews under --dry-run. Run directly; exit 1 on any failure.
# shellcheck disable=SC2034  # HOME_DIR/DRY_RUN/etc. feed the eval'd seed function
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE="$REPO_ROOT/claude/settings.example.json"
SETUP="$REPO_ROOT/setup.sh"

pass=0
failed=0
ok()   { pass=$((pass + 1));   echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

command -v jq >/dev/null 2>&1 || { echo "settings-example: jq is required" >&2; exit 1; }

if jq -e . "$EXAMPLE" >/dev/null 2>&1; then
  ok "settings.example.json is valid JSON"
else
  fail "settings.example.json is not valid JSON"
fi

# Hooks deliberately NOT in the public template, each with its reason. A hook
# here must also stay out of the template (asserted below).
#   StripProjectPermissions.hook.ts — deletes the whole `permissions` key
#   (deny and ask rules included) from a project's settings.local.json. That
#   is only safe beside a global allowlist that replaces it, which the
#   template deliberately does not ship.
EXAMPLE_OPT_OUT=" StripProjectPermissions.hook.ts "

# Same extraction as check-hooks-wired.sh: every command string under .hooks.
commands="$(jq -r '.hooks // {} | .. | .command? // empty' "$EXAMPLE" 2>/dev/null)"
unwired=""
optout_wired=""
for f in "$REPO_ROOT"/claude/hooks/*.sh "$REPO_ROOT"/claude/hooks/*.ts; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  case "$EXAMPLE_OPT_OUT" in
    *" $name "*)
      grep -qF "/.claude/hooks/$name" <<<"$commands" && optout_wired="$optout_wired $name"
      continue ;;
  esac
  grep -qF "/.claude/hooks/$name" <<<"$commands" || unwired="$unwired $name"
done
if [ -z "$unwired" ]; then
  ok "every claude/hooks/* hook (minus the documented opt-outs) is registered in settings.example.json"
else
  fail "hooks missing from settings.example.json:$unwired"
fi
if [ -z "$optout_wired" ]; then
  ok "opted-out hooks stay out of the public template"
else
  fail "opted-out hooks registered in settings.example.json:$optout_wired"
fi

# Every command quotes its $HOME path, so a HOME with spaces still runs it:
# run each command under `sh -c` (how Claude Code runs them) with HOME set to
# a dir containing a space and stub hooks that record they ran.
SPACE_HOME="$(mktemp -d)/home with space"
mkdir -p "$SPACE_HOME/.claude/hooks"
for f in "$REPO_ROOT"/claude/hooks/*.sh "$REPO_ROOT"/claude/hooks/*.ts "$REPO_ROOT"/claude/statusline.sh; do
  [ -e "$f" ] || continue
  case "$f" in */statusline.sh) stub="$SPACE_HOME/.claude/statusline.sh" ;; *) stub="$SPACE_HOME/.claude/hooks/${f##*/}" ;; esac
  printf '#!/bin/sh\necho ran\n' > "$stub"
  chmod +x "$stub"
done
broken=""
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  [ "$(HOME="$SPACE_HOME" sh -c "$cmd" </dev/null 2>/dev/null)" = ran ] || broken="$broken [$cmd]"
done < <(jq -r '(.hooks // {} | .. | .command? // empty), (.statusLine.command // empty)' "$EXAMPLE")
rm -rf "${SPACE_HOME%/home with space}"
if [ -z "$broken" ]; then
  ok "every hook and status-line command runs when HOME contains a space"
else
  fail "commands that break on a HOME with a space:$broken"
fi

# The reverse: no registration names a hook file that does not exist.
dangling=""
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  hook="$(grep -oE '/\.claude/hooks/[^ "]+' <<<"$cmd" | head -1)"
  [ -n "$hook" ] || { dangling="$dangling [$cmd]"; continue; }
  [ -e "$REPO_ROOT/claude/hooks/${hook##*/}" ] || dangling="$dangling ${hook##*/}"
done <<<"$commands"
if [ -z "$dangling" ]; then
  ok "every registered hook command names a file in claude/hooks/"
else
  fail "settings.example.json registers missing hooks:$dangling"
fi

if [ "$(jq -r '.statusLine.type // empty' "$EXAMPLE")" = command ] \
  && jq -r '.statusLine.command // empty' "$EXAMPLE" | grep -qF '/.claude/statusline.sh' \
  && [ -f "$REPO_ROOT/claude/statusline.sh" ]; then
  ok "statusLine runs ~/.claude/statusline.sh"
else
  fail "statusLine does not point at statusline.sh"
fi

private="$(jq -r 'keys[] | select(. != "$schema" and . != "hooks" and . != "statusLine")' "$EXAMPLE")"
if [ -z "$private" ]; then
  ok "template holds only \$schema, hooks and statusLine (public-safe)"
else
  fail "template carries non-public keys: $(tr '\n' ' ' <<<"$private")"
fi

# The symlink pass must not deploy the template: a linked settings.json would
# send local edits into the public repo, and a linked example is clutter.
# shellcheck source=lib-symlinks.sh
. "$REPO_ROOT/lib-symlinks.sh"
if symlink_enumerate "$REPO_ROOT/claude" "/dst" | cut -f2 \
  | grep -qE '^/dst/settings(\.example)?\.json$'; then
  fail "symlink pass would link the settings template into ~/.claude"
else
  ok "symlink pass never links settings.json or settings.example.json"
fi

# A user-scope plugin install creates settings.json (enabledPlugins only), so
# the seed must run before setup's Claude CLI, auth and plugin steps, or it
# would find that file and skip, leaving every hook unregistered.
seed_line="$(grep -n '^  seed_claude_settings$' "$SETUP" | head -1 | cut -d: -f1)"
cli_line="$(grep -n '^# ─── 3\. Claude Code CLI' "$SETUP" | head -1 | cut -d: -f1)"
if [ -n "$seed_line" ] && [ -n "$cli_line" ] && [ "$seed_line" -lt "$cli_line" ]; then
  ok "setup.sh seeds settings.json before installing Claude Code and its plugins"
else
  fail "setup.sh seeds settings.json after the Claude CLI/plugin steps (seed=${seed_line:-?}, cli=${cli_line:-?})"
fi

# seed_claude_settings, extracted from setup.sh and run against a throwaway
# HOME with no claude-memory bootstrap.
eval "$(sed -n '/^seed_claude_settings()/,/^}/p' "$SETUP")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
HOME_DIR="$T"
BOOTSTRAP_SCRIPT="$T/dev/claude-memory/bootstrap.sh"
CLAUDE_SETTINGS="$T/.claude/settings.json"
SETTINGS_EXAMPLE="$EXAMPLE"

DRY_RUN=1 SETTINGS_SEEDED=""
seed_claude_settings > "$T.out" 2>&1
if [ ! -e "$T/.claude" ] && [ "$SETTINGS_SEEDED" = would ] && grep -q '\[DRY\] would create' "$T.out"; then
  ok "dry-run previews the settings.json seed and writes nothing"
else
  fail "dry-run seed wrote to HOME or printed no preview"
fi

DRY_RUN=0 SETTINGS_SEEDED=""
seed_claude_settings > "$T.out" 2>&1
if [ -f "$CLAUDE_SETTINGS" ] && [ ! -L "$CLAUDE_SETTINGS" ] && cmp -s "$CLAUDE_SETTINGS" "$EXAMPLE" \
  && [ "$SETTINGS_SEEDED" = yes ]; then
  ok "seed creates ~/.claude/settings.json as a real copy of the example"
else
  fail "seed did not create a real settings.json copy"
fi

printf '{"mine": true}\n' > "$CLAUDE_SETTINGS"
SETTINGS_SEEDED=""
seed_claude_settings > "$T.out" 2>&1
if [ "$(cat "$CLAUDE_SETTINGS")" = '{"mine": true}' ] && [ -z "$SETTINGS_SEEDED" ]; then
  ok "seed never overwrites an existing settings.json"
else
  fail "seed overwrote an existing settings.json"
fi

rm "$CLAUDE_SETTINGS"
ln -s "$T/nowhere.json" "$CLAUDE_SETTINGS"
seed_claude_settings > "$T.out" 2>&1
if [ -L "$CLAUDE_SETTINGS" ] && [ ! -e "$T/nowhere.json" ]; then
  ok "seed leaves a dangling settings.json symlink alone"
else
  fail "seed wrote through a dangling settings.json symlink"
fi

rm "$CLAUDE_SETTINGS"
mkdir -p "${BOOTSTRAP_SCRIPT%/*}"
: > "$BOOTSTRAP_SCRIPT"
seed_claude_settings > "$T.out" 2>&1
if [ ! -e "$CLAUDE_SETTINGS" ]; then
  ok "seed defers to the claude-memory bootstrap when it exists"
else
  fail "seed wrote settings.json although claude-memory's bootstrap exists"
fi
rm -f "$T.out"

echo ""
echo "settings-example: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
