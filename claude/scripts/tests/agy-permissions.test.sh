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
        assert not re.search(r'/(home|Users)/[A-Za-z0-9_.-]+/', entry), entry
assert 'command(sudo)' in d['permissions']['deny']
assert 'command(rg)' in d['permissions']['allow']
assert d['settings']['allowNonWorkspaceAccess'] is True
allow = d['permissions']['allow']
assert 'read_file(~/.claude)' in allow and 'unsandboxed(rg)' in allow
assert 'write_file(~/dev)' in allow, 'file edits inside the dev tree must not prompt in default mode'
assert 'unsandboxed(python3)' not in allow and 'unsandboxed(bun run)' not in allow, 'code runners must stay sandbox-only'
assert 'unsandboxed(echo)' not in allow and 'unsandboxed(printf)' not in allow, 'text writers must stay sandbox-only'
for tool in ('awk', 'sed -n', 'fd', 'yq', 'jq'):
    assert f'unsandboxed({tool})' not in allow, f'{tool} can execute or write; sandbox-only'
deny_regexes = [re.compile(r[len('command(regex:'):-1]) for r in d['permissions']['deny'] if r.startswith('command(regex:')]
def denied(cmd): return any(x.search(cmd) for x in deny_regexes)
for cmd in ('cat ~/.ssh/id_rsa', 'cat /home/u/.aws/credentials', 'rg X .env', 'echo x > ~/.bashrc', 'tee /etc/hosts', 'sed -n -i s/a/b/ f', 'sed --in-place x f', 'rm -rf /*', 'rm -rf ~/*', 'rg --pre x y', 'git push --force'):
    assert denied(cmd), cmd
for cmd in ('cat README.md', 'echo hi > out.txt', 'ls ~/.claude/scripts', 'sed -n 1,5p setup.sh', 'rm -rf build/', 'git push --force-with-lease'):
    assert not denied(cmd), cmd
assert not any(e.startswith('command(gh api') for e in d['permissions']['allow'])
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
assert f"read_file({os.environ['HOME']}/.claude)" in d['permissions']['allow'], 'tilde rules expand to this home'
assert not any(r.startswith(('read_file(~', 'write_file(~')) for r in d['permissions']['allow'] + d['permissions']['deny'])
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

echo ""
echo "agy-permissions: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
