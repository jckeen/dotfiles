#!/usr/bin/env bash
# agy-permissions.test.sh — the Antigravity permission baseline is valid and
# portable, and agy-apply-permissions.py merges it into a machine-local
# settings file without destroying local state: apply is additive and
# idempotent, check reports missing rules/keys (and only notes a deliberate
# mode override), prune resets to the baseline after a backup, and an
# unreadable settings file is never overwritten.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TOOL="$REPO_ROOT/claude/scripts/agy-apply-permissions.py"
RULES="$REPO_ROOT/antigravity/permissions.json"

pass=0
failed=0
ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
S="$ROOT/settings.json"
export HOME="$ROOT/home"
mkdir -p "$HOME"

if python3 - "$RULES" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
assert d['settings']['toolPermission'] == 'proceed-in-sandbox'
assert d['settings']['enableTerminalSandbox'] is True
rule = re.compile(r'^(command|unsandboxed|read_file|write_file|read_url|execute_url|mcp)\(.+\)$')
for bucket in ('allow', 'ask', 'deny'):
    for entry in d['permissions'][bucket]:
        assert rule.match(entry), entry
        assert '/home/' not in entry and '/Users/' not in entry, entry
assert 'command(sudo)' in d['permissions']['deny']
assert 'command(rg)' in d['permissions']['allow']
assert d['settings']['allowNonWorkspaceAccess'] is True
allow = d['permissions']['allow']
assert 'read_file(~/.claude/)' in allow and 'write_file(~/dev/)' in allow and 'unsandboxed(gh pr view)' in allow
assert not any(r.startswith('unsandboxed(') and not r.startswith('unsandboxed(gh ') for r in allow), 'only gh reads may leave the sandbox'
assert 'read_file(~/.config/gh/)' in d['permissions']['deny'] and 'read_file(~/.claude/.credentials.json)' in d['permissions']['deny']
assert 'command(git config)' not in d['permissions']['ask'], 'an ask prefix would shadow the read-only git config --get allow'
assert 'unsandboxed(python3)' not in allow and 'unsandboxed(bun run)' not in allow, 'code runners must stay sandbox-only'
assert 'unsandboxed(echo)' not in allow and 'unsandboxed(printf)' not in allow, 'text writers must stay sandbox-only'
for tool in ('awk', 'sed -n', 'fd', 'yq', 'jq'):
    assert f'unsandboxed({tool})' not in allow, f'{tool} can execute or write; sandbox-only'
assert not any('regex:' in r for b in d['permissions'].values() for r in b), 'no command regexes: the sandbox is the boundary'
assert 'command(git push --force)' in d['permissions']['deny'] and 'command(git clone)' in d['permissions']['ask']
assert 'read_file(~/.gemini/antigravity-cli/)' not in d['permissions']['deny'], 'agy keeps its own brain/ and scratch/ there'
assert 'command(rm -rf /)' not in d['permissions']['deny'], 'a bare / or ~ prefix risks over-matching every absolute path'
assert not any('gh auth' in r for r in allow), 'gh auth status --show-token prints the token; it must ask'
PY
then ok "baseline is valid, portable, and denies sudo while keeping gh api out of allow"
else fail "baseline file failed validation"; fi

printf '{"trustedWorkspaces":["/x/dev"],"permissions":{"allow":["command(local-junk)","command(rg)"]}}\n' > "$S"
out="$(python3 "$TOOL" apply --settings "$S" --rules "$RULES" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && python3 - "$S" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['trustedWorkspaces'] == ['/x/dev']
assert d['toolPermission'] == 'proceed-in-sandbox' and d['enableTerminalSandbox'] is True
assert d['permissions']['allow'][0] == 'command(local-junk)'
assert d['permissions']['allow'].count('command(rg)') == 1
import os
assert f"read_file({os.environ['HOME']}/.claude/)" in d['permissions']['allow'], 'tilde rules expand to this home'
assert not any(r.startswith(('read_file(~', 'write_file(~')) for b in d['permissions'].values() for r in b)
assert 'command(sudo)' in d['permissions']['deny']
PY
then ok "apply merges the baseline, seeds mode keys, keeps local rules and trustedWorkspaces"
else fail "apply did not merge correctly (rc=$rc): $out"; fi

before="$(sha256sum "$S")"
python3 "$TOOL" apply --settings "$S" --rules "$RULES" >/dev/null 2>&1
if [ "$(sha256sum "$S")" = "$before" ]; then ok "apply is idempotent"; else fail "second apply rewrote the file"; fi

if out="$(python3 "$TOOL" check --settings "$S" --rules "$RULES")" && grep -q '1 machine-local rule' <<< "$out"; then
  ok "check passes and counts the one local rule as drift information"
else fail "check failed on a merged file: $out"; fi

python3 - "$S" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d['toolPermission'] = 'request-review'; json.dump(d, open(p, 'w'))
PY
if out="$(python3 "$TOOL" check --settings "$S" --rules "$RULES")" && grep -q 'local override' <<< "$out"; then
  ok "a deliberate mode override is a note, not a failure"
else fail "mode override handling: $out"; fi
if out="$(python3 "$TOOL" apply --settings "$S" --rules "$RULES")" && grep -q 'local override' <<< "$out" \
  && [ "$(python3 -c "import json;print(json.load(open('$S'))['toolPermission'])")" = request-review ]; then
  ok "apply does not force the mode over a local override"
else fail "apply overrode the local mode: $out"; fi

python3 - "$S" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d['permissions']['deny'].remove('command(sudo)'); del d['enableTerminalSandbox']; json.dump(d, open(p, 'w'))
PY
if ! out="$(python3 "$TOOL" check --settings "$S" --rules "$RULES")" && grep -q '1 baseline rule(s) missing; unset: enableTerminalSandbox' <<< "$out"; then
  ok "check fails naming missing rules and unset keys"
else fail "check did not report drift: $out"; fi

out="$(python3 "$TOOL" prune --settings "$S" --rules "$RULES" 2>&1)"; rc=$?
backup="$(ls "$ROOT"/settings.json.bak-* 2>/dev/null | head -1)"
if [ "$rc" -eq 0 ] && [ -n "$backup" ] && grep -q 'local-junk' "$backup" && python3 - "$S" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert 'command(local-junk)' not in d['permissions']['allow']
assert d['toolPermission'] == 'proceed-in-sandbox' and d['enableTerminalSandbox'] is True
assert d['trustedWorkspaces'] == ['/x/dev']
PY
then ok "prune backs up, resets rules to the baseline, forces mode keys, keeps trustedWorkspaces"
else fail "prune misbehaved (rc=$rc): $out"; fi

printf '{not json' > "$S"; before="$(sha256sum "$S")"
python3 "$TOOL" apply --settings "$S" --rules "$RULES" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$(sha256sum "$S")" = "$before" ]; then ok "unreadable settings are refused and left untouched"; else fail "malformed settings were overwritten or accepted (rc=$rc)"; fi

rm -f "$S"
if python3 "$TOOL" apply --settings "$ROOT/new/settings.json" --rules "$RULES" >/dev/null 2>&1 && [ -f "$ROOT/new/settings.json" ]; then
  ok "apply creates the settings file on a fresh machine"
else fail "apply could not create a fresh settings file"; fi

S_EXP="$ROOT/expanded_settings.json"
python3 "$TOOL" apply --settings "$S_EXP" --rules "$RULES" --home "/custom/home/user" >/dev/null 2>&1
if python3 - "$S_EXP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
deny = d['permissions']['deny']
assert 'read_file(/custom/home/user/.ssh/)' in deny
assert 'read_file(/custom/home/user/.aws/)' in deny
assert 'read_file(/custom/home/user/.gnupg/)' in deny
assert not any('~' in r and r.startswith(('read_file(', 'write_file(')) for r in deny)
PY
then ok "apply expands tilde in file rules using target home"; else fail "tilde was not expanded in file rules"; fi

python3 - "$S_EXP" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['permissions']['deny'] = [
    r[:-2] + ')' if r.endswith('/)') else r
    for r in d['permissions']['deny']
]
json.dump(d, open(p, 'w'))
PY
if ! python3 "$TOOL" check --settings "$S_EXP" --rules "$RULES" --home "/custom/home/user" >/dev/null 2>&1; then
  ok "check strictly detects missing trailing slash on directory rules"
else fail "check failed to flag missing trailing slash as drift"; fi

python3 "$TOOL" apply --settings "$S_EXP" --rules "$RULES" --home "/custom/home/user" >/dev/null 2>&1
if python3 - "$S_EXP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
deny = d['permissions']['deny']
assert 'read_file(/custom/home/user/.ssh/)' in deny
assert 'read_file(/custom/home/user/.ssh)' in deny
PY
then ok "apply adds canonical trailing-slash rule when non-trailing rule exists"; else fail "apply failed to add canonical trailing-slash rule"; fi

# Root home expansion and validation
S_ROOT="$ROOT/root_settings.json"
python3 "$TOOL" apply --settings "$S_ROOT" --rules "$RULES" --home "/" >/dev/null 2>&1
if python3 - "$S_ROOT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
deny = d['permissions']['deny']
assert 'read_file(/.ssh/)' in deny
assert 'read_file(/.aws/)' in deny
assert not any(r == 'read_file()' or r == 'write_file()' for r in deny)
PY
then ok "apply handles root home (/) without empty path rules"; else fail "root home expansion failed"; fi

if python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("agy_perm", "claude/scripts/agy-apply-permissions.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.expand_rule("read_file(~root)", "/home/user") == "read_file(~root)"
assert mod.expand_rule("read_file(~root/foo)", "/home/user") == "read_file(~root/foo)"
assert mod.expand_rule("read_file(~)", "/home/user") == "read_file(/home/user)"
assert mod.expand_rule("read_file(~/) ", "/home/user") == "read_file(~/) "
assert mod.expand_rule("read_file(~/.ssh/)", "/home/user") == "read_file(/home/user/.ssh/)"
assert mod.expand_rule("write_file(~/.claude/foo)", "/home/user") == "write_file(/home/user/.claude/foo)"
assert mod.expand_rule("write_file(~)", "/home/user") == "write_file(/home/user)"
assert mod.expand_rule("write_file(~root/bar)", "/home/user") == "write_file(~root/bar)"
PY
then ok "expand_rule handles read_file and write_file while leaving ~username unexpanded"; else fail "expand_rule mishandled ~username or write_file"; fi

S_TRAILING="$ROOT/trailing_home_settings.json"
python3 "$TOOL" apply --settings "$S_TRAILING" --rules "$RULES" --home "/custom/home/user/" >/dev/null 2>&1
if python3 - "$S_TRAILING" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
deny = d['permissions']['deny']
assert 'read_file(/custom/home/user/.ssh/)' in deny
assert not any('//' in r for r in deny)
PY
then ok "apply handles --home with trailing slash without double slashes"; else fail "trailing slash home failed"; fi

if python3 "$TOOL" apply --settings "$ROOT/tmp.json" --rules "$RULES" --home "relative/path" >/dev/null 2>&1; then
  fail "relative --home was accepted"; else ok "relative --home is rejected"; fi

# Legacy unexpanded ~ rules repair and check
S_LEGACY="$ROOT/legacy_settings.json"
printf '{"permissions":{"allow":["read_file(~/allowed.txt)"],"ask":["write_file(~/prompt.txt)"],"deny":["read_file(~/.ssh/)","command(sudo)"]}}\n' > "$S_LEGACY"
if out="$(python3 "$TOOL" check --settings "$S_LEGACY" --rules "$RULES" --home "/custom/home/user" 2>&1)"; then
  fail "check passed on unexpanded ~ rules"; else ok "check detects unexpanded ~ rules in settings"; fi

python3 "$TOOL" apply --settings "$S_LEGACY" --rules "$RULES" --home "/custom/home/user" >/dev/null 2>&1
if python3 - "$S_LEGACY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
perms = d['permissions']
assert 'read_file(/custom/home/user/allowed.txt)' in perms['allow']
assert 'write_file(/custom/home/user/prompt.txt)' in perms['ask']
assert 'read_file(/custom/home/user/.ssh/)' in perms['deny']
assert 'read_file(~/.ssh/)' not in perms['deny']
assert perms['deny'].count('read_file(/custom/home/user/.ssh/)') == 1
assert not any('~' in r and r.startswith(('read_file(', 'write_file(')) for bucket in perms.values() for r in bucket)
PY
then ok "apply repairs legacy unexpanded ~ rules across allow, ask, and deny"; else fail "legacy repair failed"; fi

# ── Retired rules (#427) ───────────────────────────────────────────────────
# A grant withdrawn from the baseline must also leave settings that already
# carry it. apply is additive, so without this a machine that installed an
# earlier baseline keeps the withdrawn rule forever.
S_RETIRED="$ROOT/retired.json"
python3 - "$S_RETIRED" "$RULES" <<'PY'
import json, sys
retired = json.load(open(sys.argv[2]))['retired']
assert retired, 'baseline must declare retired rules'
json.dump({'trustedWorkspaces': ['/x/dev'],
           'permissions': {'allow': ['command(local-junk)'] + retired[:1],
                           'ask': [], 'deny': retired[1:2]}},
          open(sys.argv[1], 'w'))
PY

if out="$(python3 "$TOOL" check --settings "$S_RETIRED" --rules "$RULES" 2>&1)"; then
  fail "check passed while a retired rule was still live: $out"
else
  if grep -q 'retired' <<< "$out"; then ok "check fails naming retired rules still in settings"
  else fail "check failed without naming the retired rule: $out"; fi
fi

out="$(python3 "$TOOL" apply --settings "$S_RETIRED" --rules "$RULES" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && python3 - "$S_RETIRED" "$RULES" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
retired = set(json.load(open(sys.argv[2]))['retired'])
perms = d['permissions']
live = {r for bucket in perms.values() for r in bucket}
assert not (live & retired), f'retired rules survived apply: {live & retired}'
assert 'command(local-junk)' in perms['allow'], 'unrelated local grants must be kept'
assert d['trustedWorkspaces'] == ['/x/dev']
assert 'command(sudo)' in perms['deny'], 'baseline rules still applied'
PY
then ok "apply removes retired rules and keeps unrelated local grants"
else fail "apply did not retire the rules (rc=$rc): $out"; fi

if grep -q 'retired' <<< "$out"; then ok "apply reports each retired rule it removed"
else fail "apply removed retired rules silently: $out"; fi

if python3 "$TOOL" check --settings "$S_RETIRED" --rules "$RULES" >/dev/null 2>&1; then
  ok "check passes once the retired rules are gone"
else fail "check still failing after apply removed the retired rules"; fi

echo ""
echo "agy-permissions: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
