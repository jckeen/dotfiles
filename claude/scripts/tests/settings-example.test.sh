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

# Hooks deliberately NOT in the public template, with their reasons, live in
# claude/settings-optout.txt — the same list check-hooks-wired.sh reads. A
# hook listed there must also stay out of the template (asserted below), and
# every entry must carry a reason and name a real hook.
OPTOUT_FILE="$REPO_ROOT/claude/settings-optout.txt"
EXAMPLE_OPT_OUT=" $(sed 's/#.*//' "$OPTOUT_FILE" | awk 'NF {printf "%s ", $1}')"
bad_optout=""
while IFS= read -r line; do
  entry="$(sed 's/#.*//' <<<"$line" | awk 'NF {print $1}')"
  [ -n "$entry" ] || continue
  [ -e "$REPO_ROOT/claude/hooks/$entry" ] || bad_optout="$bad_optout $entry(no such hook)"
  grep -qE '#[[:space:]]*[^[:space:]]' <<<"$line" || bad_optout="$bad_optout $entry(no reason)"
done < "$OPTOUT_FILE"
if [ -z "$bad_optout" ]; then
  ok "every settings-optout.txt entry names a real hook and gives a reason"
else
  fail "settings-optout.txt entries wrong:$bad_optout"
fi

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

# The REAL HygieneStatus hook and hygiene-status.sh, run through the
# template's own command from a checkout outside ~/dev: the hook must find its
# helper via ~/.local/bin or its own symlink, never a fixed ~/dev/dotfiles
# path, and stay silent (exit 0) when neither resolves. A seeded expirable
# retired-worktree summary makes the real helper print a line.
HS_CMD="$(jq -r '.hooks | .. | .command? // empty' "$EXAMPLE" | grep -F 'HygieneStatus.hook.sh' | head -1)"
HS_T="$(mktemp -d)"
HS_REPO="$HS_T/code/dot files"
mkdir -p "$HS_REPO/claude/hooks"
cp "$REPO_ROOT/hygiene-status.sh" "$HS_REPO/hygiene-status.sh"
cp "$REPO_ROOT/claude/hooks/HygieneStatus.hook.sh" "$HS_REPO/claude/hooks/HygieneStatus.hook.sh"
chmod +x "$HS_REPO/hygiene-status.sh" "$HS_REPO/claude/hooks/HygieneStatus.hook.sh"
hs_home() {
  rm -rf "${HS_T:?}/hm"
  mkdir -p "$HS_T/hm/.claude/hooks" "$HS_T/hm/.local/state/hygiene"
  printf '{"retired":2,"oldest_days":30,"expirable":1}\n' \
    > "$HS_T/hm/.local/state/hygiene/retired-worktrees.json"
}
hs_run() { HOME="$HS_T/hm" sh -c "$HS_CMD" </dev/null 2>&1; }

hs_home
ln -s "$HS_REPO/claude/hooks/HygieneStatus.hook.sh" "$HS_T/hm/.claude/hooks/HygieneStatus.hook.sh"
if out="$(hs_run)" && grep -q 'retired worktrees: 2' <<<"$out"; then
  ok "HygieneStatus finds hygiene-status.sh through its own symlink (checkout outside ~/dev)"
else
  fail "HygieneStatus failed from a checkout outside ~/dev: $out"
fi

hs_home
cp "$HS_REPO/claude/hooks/HygieneStatus.hook.sh" "$HS_T/hm/.claude/hooks/HygieneStatus.hook.sh"
mkdir -p "$HS_T/hm/.local/bin"
ln -s "$HS_REPO/hygiene-status.sh" "$HS_T/hm/.local/bin/hygiene-status.sh"
if out="$(hs_run)" && grep -q 'retired worktrees: 2' <<<"$out"; then
  ok "HygieneStatus prefers setup's ~/.local/bin/hygiene-status.sh link"
else
  fail "HygieneStatus ignored ~/.local/bin/hygiene-status.sh: $out"
fi

rm "$HS_T/hm/.local/bin/hygiene-status.sh"
if out="$(hs_run)" && [ -z "$out" ]; then
  ok "HygieneStatus exits 0 silently when no hygiene-status.sh resolves"
else
  fail "HygieneStatus was not silent with no helper: rc/out=$out"
fi
rm -rf "$HS_T"

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
  | grep -qE '^/dst/settings(\.example\.json|\.json|-optout\.txt)$'; then
  fail "symlink pass would link the settings template into ~/.claude"
else
  ok "symlink pass never links settings.json, settings.example.json or settings-optout.txt"
fi

# check-hooks-wired.sh against live settings in a throwaway HOME: the template
# itself passes --strict (its opt-outs are not drift), but a hook missing that
# the opt-out list does NOT name is still flagged — real drift in the owner's
# settings must not hide behind the template's list.
CHECKER="$REPO_ROOT/claude/scripts/check-hooks-wired.sh"
HW_HOME="$(mktemp -d)"
mkdir -p "$HW_HOME/.claude"
cp "$EXAMPLE" "$HW_HOME/.claude/settings.json"
if HOME="$HW_HOME" "$CHECKER" --strict >"$HW_HOME/out" 2>&1; then
  ok "check-hooks-wired --strict passes on the unmodified template"
else
  fail "check-hooks-wired --strict flags the template's own opt-outs as drift"
  sed 's/^/      | /' "$HW_HOME/out"
fi
jq 'del(.hooks.PreToolUse[0].hooks[] | select(.command | contains("conventional-commit.sh")))' \
  "$EXAMPLE" > "$HW_HOME/.claude/settings.json"
if ! HOME="$HW_HOME" "$CHECKER" --strict >"$HW_HOME/out" 2>&1 \
  && grep -q 'conventional-commit.sh' "$HW_HOME/out"; then
  ok "check-hooks-wired --strict still flags a missing hook the opt-out list does not name"
else
  fail "check-hooks-wired hid real drift (conventional-commit.sh unwired)"
  sed 's/^/      | /' "$HW_HOME/out"
fi
rm -rf "$HW_HOME"

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
