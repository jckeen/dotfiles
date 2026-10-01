#!/usr/bin/env bash
# claude-profile.test.sh — a second-account profile shares the default config
# through links, never overwrites anything, and ccw launches cc on it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LINK="$SCRIPT_DIR/../link-claude-profile.sh"

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
REAL_PATH="$PATH"

new_home() {
  export HOME="$ROOT/$1"
  BASE="$HOME/.claude"
  PROFILE="$HOME/.claude-work"
  mkdir -p "$BASE/skills" "$BASE/projects/-p/memory" "$BASE/plugins"
  echo '{"hooks":{}}' > "$BASE/settings.json"
  echo '# rules' > "$BASE/CLAUDE.md"
  echo 'secret' > "$BASE/.credentials.json"
  echo '{"mcpServers":{"github":{"type":"http","url":"https://example.invalid/mcp"}},"oauthAccount":{"emailAddress":"base"}}' \
    > "$HOME/.claude.json"
}

# ── fresh profile ────────────────────────────────────────────────────────
new_home fresh
if "$LINK" "$PROFILE" >/dev/null 2>&1; then ok "fresh profile wires"; else fail "fresh profile wires"; fi
linked=1
for name in settings.json CLAUDE.md skills plugins projects; do
  [ "$(readlink "$PROFILE/$name" 2>/dev/null)" = "$BASE/$name" ] || linked=0
done
[ "$linked" -eq 1 ] && ok "shared entries link to ~/.claude" || fail "shared entries link to ~/.claude"
[ -d "$PROFILE/projects/-p/memory" ] && ok "memory is reachable through the profile" \
  || fail "memory is reachable through the profile"
[ ! -e "$PROFILE/.credentials.json" ] && [ ! -L "$PROFILE/.credentials.json" ] \
  && ok "credentials are not shared" || fail "credentials are not shared"
[ ! -e "$PROFILE/agents" ] && [ ! -L "$PROFILE/agents" ] \
  && ok "an entry the default profile lacks is not linked" \
  || fail "an entry the default profile lacks is not linked"
[ "$(jq -c '.mcpServers | keys' "$PROFILE/.claude.json")" = '["github"]' ] \
  && ok "MCP servers are copied" || fail "MCP servers are copied"
[ "$(jq -r '.oauthAccount // "none"' "$PROFILE/.claude.json")" = "none" ] \
  && ok "account state is not copied" || fail "account state is not copied"

before="$(ls -la "$PROFILE"; cat "$PROFILE/.claude.json")"
"$LINK" "$PROFILE" >/dev/null 2>&1; rerun=$?
after="$(ls -la "$PROFILE"; cat "$PROFILE/.claude.json")"
[ "$rerun" -eq 0 ] && [ "$before" = "$after" ] && ok "re-run is a no-op" || fail "re-run is a no-op"
"$LINK" --check "$PROFILE" >/dev/null 2>&1 && ok "--check passes a wired profile" \
  || fail "--check passes a wired profile"

# ── MCP sync preserves the profile's own account state ───────────────────
echo '{"oauthAccount":{"emailAddress":"work"},"mcpServers":{}}' > "$PROFILE/.claude.json"
"$LINK" "$PROFILE" >/dev/null 2>&1
[ "$(jq -r '.oauthAccount.emailAddress' "$PROFILE/.claude.json")" = "work" ] \
  && [ "$(jq -c '.mcpServers | keys' "$PROFILE/.claude.json")" = '["github"]' ] \
  && ok "MCP sync keeps the profile's account state" || fail "MCP sync keeps the profile's account state"

# ── nothing is overwritten ───────────────────────────────────────────────
new_home occupied
mkdir -p "$PROFILE/projects/-x" "$PROFILE/skills"
echo 'transcript' > "$PROFILE/projects/-x/a.jsonl"
echo '{"own":true}' > "$PROFILE/settings.json"
if "$LINK" "$PROFILE" >/dev/null 2>&1; then fail "real entries refuse"; else ok "real entries refuse"; fi
[ "$(cat "$PROFILE/projects/-x/a.jsonl")" = "transcript" ] && [ ! -L "$PROFILE/projects" ] \
  && ok "a populated directory is kept" || fail "a populated directory is kept"
[ "$(cat "$PROFILE/settings.json")" = '{"own":true}' ] && ok "a real file is kept" || fail "a real file is kept"
[ -L "$PROFILE/skills" ] && ok "an empty directory yields to the link" \
  || fail "an empty directory yields to the link"

new_home foreign
mkdir -p "$PROFILE" "$HOME/elsewhere"
ln -s "$HOME/elsewhere" "$PROFILE/skills"
if "$LINK" "$PROFILE" >/dev/null 2>&1; then fail "a foreign link refuses"; else ok "a foreign link refuses"; fi
[ "$(readlink "$PROFILE/skills")" = "$HOME/elsewhere" ] && ok "a foreign link is kept" \
  || fail "a foreign link is kept"

# ── --check never writes ─────────────────────────────────────────────────
new_home check
if "$LINK" --check "$PROFILE" >/dev/null 2>&1; then fail "--check reports a missing profile"; else ok "--check reports a missing profile"; fi
[ ! -e "$PROFILE" ] && ok "--check creates nothing" || fail "--check creates nothing"
mkdir -p "$PROFILE/skills"
if "$LINK" --check "$PROFILE" >/dev/null 2>&1; then fail "--check reports drift"; else ok "--check reports drift"; fi
[ -d "$PROFILE/skills" ] && [ ! -L "$PROFILE/skills" ] && [ ! -e "$PROFILE/.claude.json" ] \
  && [ ! -L "$PROFILE/settings.json" ] && ok "--check changes nothing" || fail "--check changes nothing"

# ── refused targets ──────────────────────────────────────────────────────
new_home guard
for target in "$BASE" "$BASE/sub" "relative/dir" ""; do
  "$LINK" "$target" >/dev/null 2>&1
  [ $? -eq 2 ] && ok "refuses target '${target:-<empty>}'" || fail "refuses target '${target:-<empty>}'"
done
mkdir -p "$HOME/real"
ln -s "$HOME/real" "$HOME/.claude-link"
"$LINK" "$HOME/.claude-link" >/dev/null 2>&1
[ $? -eq 2 ] && ok "refuses a symlinked profile dir" || fail "refuses a symlinked profile dir"

# ── ccw ──────────────────────────────────────────────────────────────────
new_home launcher
mkdir -p "$ROOT/dev"
ln -s "$REPO_ROOT" "$ROOT/dev/dotfiles"
echo "$ROOT/dev" > "$BASE/dev-dir"
unset CLAUDE_CONFIG_DIR CLAUDE_WORK_CONFIG_DIR _DEV_DIR_CACHE
# shellcheck source=../../../.bash_aliases
source "$REPO_ROOT/.bash_aliases"
export PATH="$REAL_PATH"
cc() { echo "dir=${CLAUDE_CONFIG_DIR:-unset} child=$(sh -c 'echo "${CLAUDE_CONFIG_DIR:-unset}"') args=$*"; }

out="$(ccw dotfiles -c 2>&1)"
[ "$out" = "dir=$PROFILE child=$PROFILE args=dotfiles -c" ] \
  && ok "ccw runs cc on the work profile with its args" || fail "ccw runs cc on the work profile with its args ($out)"
[ -L "$PROFILE/settings.json" ] && ok "ccw wires the profile first" || fail "ccw wires the profile first"
ccw >/dev/null 2>&1
[ -z "${CLAUDE_CONFIG_DIR:-}" ] && ok "ccw leaves the shell on the default account" \
  || fail "ccw leaves the shell on the default account"

out="$(CLAUDE_WORK_CONFIG_DIR="$HOME/.claude-other" ccw 2>&1)"
[ "$out" = "dir=$HOME/.claude-other child=$HOME/.claude-other args=" ] \
  && ok "CLAUDE_WORK_CONFIG_DIR overrides the directory" || fail "CLAUDE_WORK_CONFIG_DIR overrides the directory ($out)"

rm "$PROFILE/settings.json"
echo '{"own":true}' > "$PROFILE/settings.json"
out="$(ccw 2>&1)"; ccw_rc=$?
[ "$ccw_rc" -eq 1 ] && [[ "$out" != *"dir="* ]] && ok "ccw refuses an unwired profile" \
  || fail "ccw refuses an unwired profile ($out)"

# ── statusline badge ─────────────────────────────────────────────────────
json='{"model":{"display_name":"M"},"cwd":"/"}'
line="$(printf '%s' "$json" | CLAUDE_CONFIG_DIR="$HOME/.claude-work" bash "$REPO_ROOT/claude/statusline.sh" 2>/dev/null | head -1)"
[[ "$line" == *"◆ work"* ]] && ok "statusline names the profile" || fail "statusline names the profile"
for dir in "" "$HOME/.claude" "$HOME/.claude/"; do
  line="$(printf '%s' "$json" | CLAUDE_CONFIG_DIR="$dir" bash "$REPO_ROOT/claude/statusline.sh" 2>/dev/null | head -1)"
  [[ "$line" != *"◆"* ]] && ok "no badge on the default account ('$dir')" || fail "no badge on the default account ('$dir')"
done

echo ""
echo "claude-profile: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
