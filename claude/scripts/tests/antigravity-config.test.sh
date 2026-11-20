#!/usr/bin/env bash
# antigravity-config.test.sh — Antigravity health checks fail closed on unsafe
# runtime roots and malformed local MCP configuration.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
failed=0

ok()   { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

canon_tmpdir() {
  local d
  d="$(mktemp -d)" && (cd -P -- "$d" && pwd -P)
}

R="$(canon_tmpdir)"
H="$(canon_tmpdir)"
EXTERNAL="$(canon_tmpdir)"
OUT="$(mktemp)"
trap 'rm -rf "$R" "$H" "$EXTERNAL"; rm -f "$OUT"' EXIT

mkdir -p "$R/antigravity"
cp "$REPO_ROOT/check-antigravity.sh" "$REPO_ROOT/lib-checks.sh" "$R/"
mkdir -p "$R/claude/scripts"
cp "$REPO_ROOT/claude/scripts/retired-skill-links.sh" "$R/claude/scripts/"
cp "$REPO_ROOT/antigravity/GEMINI.md" "$REPO_ROOT/antigravity/hooks.json" \
  "$R/antigravity/"

if grep -q '@latest' "$REPO_ROOT/antigravity/mcp_config.json.example" \
  || ! grep -Eq '@playwright/mcp@[0-9]' "$REPO_ROOT/antigravity/mcp_config.json.example" \
  || ! grep -Eq '@modelcontextprotocol/server-github@[0-9]' "$REPO_ROOT/antigravity/mcp_config.json.example"; then
  fail "Antigravity MCP template dependencies are not reproducibly pinned"
else
  ok "Antigravity MCP template dependencies are pinned"
fi

MISSING_HOME="$(mktemp -d)"
if HOME="$MISSING_HOME" "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker accepted missing Antigravity runtime configuration"
elif grep -q 'MISSING.*Antigravity has not been initialized' "$OUT"; then
  ok "checker fails health checks when Antigravity is uninitialized"
else
  fail "missing Antigravity state lacked a useful diagnostic"
fi
rm -rf "$MISSING_HOME"

mkdir -p "$H/.gemini"
ln -s "$EXTERNAL" "$H/.gemini/config"
printf 'preserve me\n' > "$EXTERNAL/sentinel"

if HOME="$H" "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker accepted a symlinked Antigravity config root"
elif grep -q 'UNSAFE.*config.*directory symlink' "$OUT" \
  && grep -q 'preserve me' "$EXTERNAL/sentinel"; then
  ok "checker refuses a symlinked Antigravity config root without traversal"
else
  fail "symlinked-root failure lacked a safe diagnostic"
fi

rm "$H/.gemini/config"
rmdir "$H/.gemini"
mkdir -p "$EXTERNAL/config"
ln -s "$R/antigravity/GEMINI.md" "$EXTERNAL/config/GEMINI.md"
ln -s "$R/antigravity/hooks.json" "$EXTERNAL/config/hooks.json"
printf '{"mcpServers":{}}\n' > "$EXTERNAL/config/mcp_config.json"
ln -s "$EXTERNAL" "$H/.gemini"
if HOME="$H" "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker accepted a symlinked Antigravity runtime parent"
elif grep -q 'UNSAFE.*\.gemini.*directory symlink' "$OUT"; then
  ok "checker refuses a symlinked Antigravity runtime parent"
else
  fail "symlinked-parent failure lacked a safe diagnostic"
fi

rm "$H/.gemini"
mkdir -p "$H/.gemini"
mkdir -p "$H/.gemini/config"
ln -s "$R/antigravity/GEMINI.md" "$H/.gemini/config/GEMINI.md"
ln -s "$R/antigravity/hooks.json" "$H/.gemini/config/hooks.json"
printf 'not json\n' > "$H/.gemini/config/mcp_config.json"

if HOME="$H" "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker accepted malformed MCP configuration"
elif grep -q 'INVALID.*mcp_config.json' "$OUT"; then
  ok "checker rejects malformed MCP configuration"
else
  fail "malformed MCP failure lacked a useful diagnostic"
fi

printf '{"mcpServers":{}}\n' > "$H/.gemini/config/mcp_config.json"
if HOME="$H" "$R/check-antigravity.sh" > "$OUT" 2>&1 \
  && grep -q 'All good' "$OUT"; then
  ok "checker accepts a valid local MCP object"
else
  fail "checker rejected a valid local MCP object"
fi

rm "$H/.gemini/config/hooks.json"
if HOME="$H" "$R/check-antigravity.sh" --strict > "$OUT" 2>&1; then
  fail "strict checker accepted missing managed Antigravity config"
else
  ok "strict checker turns actionable Antigravity drift into launcher failure"
fi
ln -s "$R/antigravity/hooks.json" "$H/.gemini/config/hooks.json"

SKILLS_EXTERNAL="$R/external-skills"
mkdir -p "$SKILLS_EXTERNAL"
ln -s "$SKILLS_EXTERNAL" "$H/.gemini/config/skills"
if HOME="$H" "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker accepted a symlinked Antigravity skills ancestor"
elif grep -q 'UNSAFE.*skills.*directory symlink' "$OUT"; then
  ok "checker refuses a symlinked Antigravity skills ancestor"
else
  fail "symlinked-skills failure lacked a safe diagnostic"
fi
rm "$H/.gemini/config/skills"

CUSTOM_MEMORY="$R/custom-agy-memory"
mkdir -p "$CUSTOM_MEMORY"
printf '# private rules\n' > "$CUSTOM_MEMORY/GEMINI.local.md"
printf '# private memory\n' > "$CUSTOM_MEMORY/MEMORY.md"
HOME="$H" AGY_MEMORY_REPO="$CUSTOM_MEMORY" \
  "$R/check-antigravity.sh" > "$OUT" 2>&1 || true
if grep -q 'MISSING.*GEMINI.local.md' "$OUT"; then
  ok "checker honors the Antigravity memory repository override"
else
  fail "checker ignored a custom Antigravity memory repository"
fi

SANDBOX_BASE="$(canon_tmpdir)"
SANDBOX_HOME="$SANDBOX_BASE/back\\slash/space home"
SANDBOX_HOME_ESCAPED="${SANDBOX_HOME//\\/\\134}"
SANDBOX_HOME_ESCAPED="${SANDBOX_HOME_ESCAPED// /\\040}"
MOUNTINFO="$R/mountinfo"
mkdir -p "$SANDBOX_HOME/.gemini/config" "$SANDBOX_HOME/.gemini/antigravity-cli"
cp "$R/antigravity/GEMINI.md" "$SANDBOX_HOME/.gemini/config/GEMINI.md"
cat > "$MOUNTINFO" <<EOF
797 794 0:111 /setup/deny5 $SANDBOX_HOME_ESCAPED/.gemini/antigravity-cli ro,nosuid,nodev - tmpfs tmpfs rw
803 794 0:111 /setup/deny6 $SANDBOX_HOME_ESCAPED/.gemini/config ro,nosuid,nodev - tmpfs tmpfs rw
EOF
if HOME="$SANDBOX_HOME" AGY_MOUNTINFO_FILE="$MOUNTINFO" AGY_MEMORY_REPO="$CUSTOM_MEMORY" \
  "$R/check-antigravity.sh" --strict > "$OUT" 2>&1 \
  && grep -q 'SANDBOX.*GEMINI.md matches' "$OUT" \
  && grep -q 'SANDBOX.*hooks.json masked' "$OUT" \
  && grep -q 'SANDBOX.*GEMINI.local.md masked' "$OUT"; then
  ok "strict checker accepts sandbox-masked Antigravity config (including \\134 and \\040 mountinfo escapes)"
else
  fail "strict checker failed under simulated Antigravity terminal sandbox mounts"
fi

printf 'drifted content\n' > "$SANDBOX_HOME/.gemini/config/GEMINI.md"
if HOME="$SANDBOX_HOME" AGY_MOUNTINFO_FILE="$MOUNTINFO" AGY_MEMORY_REPO="$CUSTOM_MEMORY" \
  "$R/check-antigravity.sh" --strict > "$OUT" 2>&1; then
  fail "strict checker accepted drifted bind-mounted GEMINI.md inside sandbox"
elif grep -q 'DRIFT.*GEMINI.md.*differs' "$OUT"; then
  ok "strict checker detects drifted bind-mounted GEMINI.md inside sandbox"
else
  fail "sandbox GEMINI.md drift lacked a useful diagnostic"
fi
rm -rf "$SANDBOX_BASE"

# ─── Stale agy.*.old auto-update binary detection (advisory, read-only) ──────
BIN_DIR="$(canon_tmpdir)"
PROC_DIR="$(canon_tmpdir)"
BIN_OUTSIDE="$(canon_tmpdir)"
BIN_LOCAL_HOME="$(canon_tmpdir)"
CLEAN_MOUNTINFO="$(mktemp)"
trap 'chmod 700 "$PROC_DIR"/[0-9]* 2>/dev/null || true; rm -rf "$R" "$H" "$EXTERNAL" "$BIN_DIR" "$PROC_DIR" "$BIN_OUTSIDE" "$BIN_LOCAL_HOME"; rm -f "$OUT" "$CLEAN_MOUNTINFO"' EXIT

cat > "$CLEAN_MOUNTINFO" <<'EOF'
551 550 0:90 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw
EOF

printf '#!/bin/sh\nexit 0\n' > "$BIN_DIR/agy"
chmod +x "$BIN_DIR/agy"
printf 'old binary bytes\n' > "$BIN_DIR/agy.1234.old"
chmod +x "$BIN_DIR/agy.1234.old"
mkdir -p "$PROC_DIR/100"
ln -s /bin/sh "$PROC_DIR/100/exe"

# 1. Idle agy.*.old with complete readable proc view reports STALE without failing --strict, and --fix never deletes it.
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --strict > "$OUT" 2>&1 \
  && grep -q 'STALE.*agy\.1234\.old.*no visible process matched' "$OUT" \
  && grep -q 'All good' "$OUT"; then
  ok "idle agy.*.old reports STALE without failing --strict"
else
  fail "idle agy.*.old failed --strict or lacked STALE output: $(cat "$OUT")"
fi
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix --strict > "$OUT" 2>&1 \
  && [ -f "$BIN_DIR/agy.1234.old" ]; then
  ok "--fix leaves unmanaged agy.*.old backup on disk (detection-only)"
else
  fail "--fix unexpectedly deleted agy.*.old or failed --strict: $(cat "$OUT")"
fi

# 2. In-use agy.*.old is identified when /proc/<pid>/exe matches and preserved under --fix.
mkdir -p "$PROC_DIR/9999"
ln -s "$BIN_DIR/agy.1234.old" "$PROC_DIR/9999/exe"
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix --strict > "$OUT" 2>&1 \
  && grep -q 'STALE.*agy\.1234\.old.*in use' "$OUT" \
  && [ -f "$BIN_DIR/agy.1234.old" ]; then
  ok "in-use agy.*.old is identified and preserved under --fix --strict"
else
  fail "in-use agy.*.old lacked diagnostic or was deleted: $(cat "$OUT")"
fi
rm -rf "$PROC_DIR/9999"

# 3. Unreadable process executable inspection fails closed (restricted visibility, never 'no visible process matched').
mkdir -p "$PROC_DIR/2222"
printf 'not a symlink\n' > "$PROC_DIR/2222/exe"
mkdir -p "$PROC_DIR/2223"
chmod 000 "$PROC_DIR/2223"
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1 \
  && grep -q 'STALE.*agy\.1234\.old.*visibility unavailable or restricted' "$OUT" \
  && ! grep -q 'no visible process matched' "$OUT" \
  && [ -f "$BIN_DIR/agy.1234.old" ]; then
  ok "unreadable PID exe fails closed with visibility warning and preserves agy.*.old"
else
  fail "unreadable PID exe claimed idle or failed: $(cat "$OUT")"
fi
chmod 700 "$PROC_DIR/2223"
rm -rf "$PROC_DIR/2222" "$PROC_DIR/2223"

# 4. Missing/unreadable mountinfo, hidepid=2 mountinfo, missing PROC_DIR, empty PROC_DIR, and sandbox-masked mountinfo fail closed.
if HOME="$H" AGY_MOUNTINFO_FILE="$R/no-such-mountinfo" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1 \
  && grep -q 'visibility unavailable or restricted' "$OUT" \
  && [ -f "$BIN_DIR/agy.1234.old" ]; then
  ok "missing mountinfo fails closed as restricted visibility"
else
  fail "missing mountinfo did not report restricted visibility: $(cat "$OUT")"
fi

HIDEPID_MOUNTINFO="$(mktemp)"
for restricted_case in \
  "551 550 0:90 / /proc rw,hidepid=1 - proc proc rw" \
  "551 550 0:90 / /proc rw,hidepid=2 - proc proc rw" \
  "551 550 0:90 / /proc rw,hidepid=4 - proc  rw" \
  "551 550 0:90 / /proc rw - proc proc rw,hidepid=invisible" \
  "551 550 0:90 / /proc rw - proc  rw,hidepid=ptraceable"; do
  printf '%s\n' "$restricted_case" > "$HIDEPID_MOUNTINFO"
  if HOME="$H" AGY_MOUNTINFO_FILE="$HIDEPID_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
    "$R/check-antigravity.sh" > "$OUT" 2>&1 \
    && grep -q 'visibility unavailable or restricted' "$OUT" \
    && ! grep -q 'no visible process matched' "$OUT"; then
    ok "restricted hidepid mountinfo reports restricted visibility: $restricted_case"
  else
    fail "restricted hidepid mountinfo was treated as complete ($restricted_case): $(cat "$OUT")"
  fi
done

for open_case in \
  "551 550 0:90 / /proc rw,hidepid=0 - proc  rw,hidepid=0" \
  "551 550 0:90 / /proc rw,hidepid=off - proc proc rw,hidepid=off"; do
  printf '%s\n' "$open_case" > "$HIDEPID_MOUNTINFO"
  if HOME="$H" AGY_MOUNTINFO_FILE="$HIDEPID_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
    "$R/check-antigravity.sh" > "$OUT" 2>&1 \
    && grep -q 'no visible process matched' "$OUT"; then
    ok "unrestricted hidepid mountinfo permits complete proc scan: $open_case"
  else
    fail "unrestricted hidepid mountinfo failed complete scan ($open_case): $(cat "$OUT")"
  fi
done
rm -f "$HIDEPID_MOUNTINFO"

if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$R/no-such-proc" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1 \
  && grep -q 'visibility unavailable or restricted' "$OUT" \
  && [ -f "$BIN_DIR/agy.1234.old" ]; then
  ok "missing proc dir fails closed and preserves agy.*.old"
else
  fail "missing proc dir lacked visibility diagnostic or deleted backup: $(cat "$OUT")"
fi

EMPTY_PROC="$(canon_tmpdir)"
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$EMPTY_PROC" \
  "$R/check-antigravity.sh" > "$OUT" 2>&1 \
  && grep -q 'visibility unavailable or restricted' "$OUT"; then
  ok "empty proc dir fails closed as restricted visibility"
else
  fail "empty proc dir falsely claimed no visible process matched: $(cat "$OUT")"
fi
rmdir "$EMPTY_PROC"

SANDBOX_BASE="$(canon_tmpdir)"
SANDBOX_HOME="$SANDBOX_BASE/sandbox-home"
MOUNTINFO="$R/mountinfo-bin"
mkdir -p "$SANDBOX_HOME/.gemini/config" "$SANDBOX_HOME/.gemini/antigravity-cli"
cp "$R/antigravity/GEMINI.md" "$SANDBOX_HOME/.gemini/config/GEMINI.md"
cat > "$MOUNTINFO" <<EOF
797 794 0:111 /setup/deny5 $SANDBOX_HOME/.gemini/antigravity-cli ro,nosuid,nodev - tmpfs tmpfs rw
803 794 0:111 /setup/deny6 $SANDBOX_HOME/.gemini/config ro,nosuid,nodev - tmpfs tmpfs rw
EOF
if HOME="$SANDBOX_HOME" AGY_MOUNTINFO_FILE="$MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1 \
  && grep -q 'visibility unavailable or restricted' "$OUT" \
  && [ -f "$BIN_DIR/agy.1234.old" ]; then
  ok "sandbox-masked environment fails closed and preserves agy.*.old"
else
  fail "sandbox-masked check failed: $(cat "$OUT")"
fi
rm -rf "$SANDBOX_BASE"

# 5. Symlink named agy.link.old is ignored and preserved.
ln -s "$BIN_OUTSIDE/target" "$BIN_DIR/agy.link.old"
printf 'keep link target\n' > "$BIN_OUTSIDE/target"
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1 \
  && ! grep -q 'agy\.link\.old' "$OUT" \
  && [ -L "$BIN_DIR/agy.link.old" ] \
  && [ -f "$BIN_OUTSIDE/target" ]; then
  ok "symlinked agy.*.old is ignored and untouched under --fix"
else
  fail "symlinked agy.*.old was touched or reported: $(cat "$OUT")"
fi
rm -f "$BIN_DIR/agy.link.old" "$BIN_DIR/agy.1234.old"

# 6. Missing, zero-byte, or directory replacement agy fails as BROKEN and preserves agy.*.old.
printf 'old binary bytes\n' > "$BIN_DIR/agy.broken.old"
rm -f "$BIN_DIR/agy"
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1; then
  fail "checker accepted missing agy replacement beside agy.*.old"
elif grep -q 'BROKEN.*agy is missing or not a non-empty executable' "$OUT" \
  && [ -f "$BIN_DIR/agy.broken.old" ]; then
  ok "missing agy replacement reports BROKEN and preserves agy.*.old"
else
  fail "missing agy replacement lacked BROKEN diagnostic: $(cat "$OUT")"
fi

: > "$BIN_DIR/agy"
chmod +x "$BIN_DIR/agy"
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1; then
  fail "checker accepted zero-byte agy replacement beside agy.*.old"
elif grep -q 'BROKEN.*agy is missing or not a non-empty executable' "$OUT" \
  && [ -f "$BIN_DIR/agy.broken.old" ]; then
  ok "zero-byte agy replacement reports BROKEN and preserves agy.*.old"
else
  fail "zero-byte agy replacement lacked BROKEN diagnostic: $(cat "$OUT")"
fi

rm -f "$BIN_DIR/agy"
mkdir -p "$BIN_DIR/agy"
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1; then
  fail "checker accepted directory agy alongside agy.*.old"
elif grep -q 'BROKEN.*agy is missing or not a non-empty executable' "$OUT" \
  && [ -f "$BIN_DIR/agy.broken.old" ]; then
  ok "directory agy alongside agy.*.old reports BROKEN and preserves agy.*.old"
else
  fail "directory agy lacked BROKEN diagnostic: $(cat "$OUT")"
fi
rmdir "$BIN_DIR/agy"

# 7. Active rollback symlink/hardlink to agy.*.old is clearly labeled and preserved.
chmod +x "$BIN_DIR/agy.broken.old"
ln -s "$BIN_DIR/agy.broken.old" "$BIN_DIR/agy"
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$BIN_DIR" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1 \
  && grep -q 'active rollback target of agy' "$OUT" \
  && [ -f "$BIN_DIR/agy.broken.old" ]; then
  ok "rollback target agy.*.old is identified and preserved"
else
  fail "rollback target check failed: $(cat "$OUT")"
fi
rm -f "$BIN_DIR/agy" "$BIN_DIR/agy.broken.old"

# 8. Every ancestor and component of AGY_BIN_DIR (default and explicit, trailing /, ./.., relative) is validated.
printf 'keep bin\n' > "$BIN_OUTSIDE/agy.9999.old"
ln -s "$BIN_OUTSIDE" "$BIN_DIR/link-bin"
for bad_bin in "$BIN_DIR/link-bin/" "$BIN_DIR/link-bin/." "$BIN_DIR/." "$BIN_DIR/.." "relative/bin"; do
  if HOME="$H" AGY_BIN_DIR="$bad_bin" AGY_PROC_DIR="$PROC_DIR" \
    "$R/check-antigravity.sh" --fix > "$OUT" 2>&1; then
    fail "checker accepted unsafe AGY_BIN_DIR: $bad_bin"
  elif grep -q 'UNSAFE' "$OUT" && [ -f "$BIN_OUTSIDE/agy.9999.old" ]; then
    ok "checker refuses unsafe AGY_BIN_DIR without traversal: $bad_bin"
  else
    fail "unsafe AGY_BIN_DIR ($bad_bin) lacked UNSAFE diagnostic: $(cat "$OUT")"
  fi
done

mkdir -p "$BIN_LOCAL_HOME/.gemini/config"
ln -s "$R/antigravity/GEMINI.md" "$BIN_LOCAL_HOME/.gemini/config/GEMINI.md"
ln -s "$R/antigravity/hooks.json" "$BIN_LOCAL_HOME/.gemini/config/hooks.json"
printf '{"mcpServers":{}}\n' > "$BIN_LOCAL_HOME/.gemini/config/mcp_config.json"
mkdir -p "$BIN_OUTSIDE/bin"
printf 'keep nested\n' > "$BIN_OUTSIDE/bin/agy.8888.old"
ln -s "$BIN_OUTSIDE" "$BIN_LOCAL_HOME/.local"
if HOME="$BIN_LOCAL_HOME" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1; then
  fail "checker traversed default symlinked ~/.local"
elif grep -q 'UNSAFE.*directory symlink' "$OUT" \
  && [ -f "$BIN_OUTSIDE/bin/agy.8888.old" ]; then
  ok "checker refuses default symlinked ~/.local without traversal"
else
  fail "symlinked ~/.local lacked UNSAFE diagnostic: $(cat "$OUT")"
fi

if HOME="$BIN_LOCAL_HOME" AGY_BIN_DIR="$BIN_LOCAL_HOME/.local/bin" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" --fix > "$OUT" 2>&1; then
  fail "checker traversed explicit AGY_BIN_DIR through symlinked ~/.local ancestor"
elif grep -q 'UNSAFE.*directory symlink' "$OUT" \
  && [ -f "$BIN_OUTSIDE/bin/agy.8888.old" ]; then
  ok "checker refuses explicit AGY_BIN_DIR with symlinked ancestor without traversal"
else
  fail "explicit AGY_BIN_DIR with symlinked ancestor lacked UNSAFE diagnostic: $(cat "$OUT")"
fi

# 9. Suggested manual rm cleanup command shell-quotes special characters verbatim in both branches.
QUOTE_BIN_BASE="$(canon_tmpdir)"
QUOTE_BIN="$QUOTE_BIN_BASE/space's \$var \`x\` \\dir"
mkdir -p "$QUOTE_BIN"
printf '#!/bin/sh\nexit 0\n' > "$QUOTE_BIN/agy"
chmod +x "$QUOTE_BIN/agy"
QUOTE_OLD="$QUOTE_BIN/agy.5678.old"
printf 'old binary bytes\n' > "$QUOTE_OLD"

if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$QUOTE_BIN" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" > "$OUT" 2>&1 \
  && python3 - "$OUT" "$QUOTE_OLD" <<'PY'
import shlex, sys
text = open(sys.argv[1]).read()
needle = "no visible process matched"
line = next((ln for ln in text.splitlines() if needle in ln), "")
assert line, text
cmd = line.split("remove manually: ", 1)[1].rstrip(")")
assert shlex.split(cmd) == ["rm", "--", sys.argv[2]], (cmd, sys.argv[2])
PY
then
  ok "no-match cleanup command shell-quotes spaces, quotes, and metacharacters verbatim"
else
  fail "no-match cleanup command failed shell-quoting check: $(cat "$OUT")"
fi

if HOME="$H" AGY_MOUNTINFO_FILE="$R/no-such-mountinfo" AGY_BIN_DIR="$QUOTE_BIN" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" > "$OUT" 2>&1 \
  && python3 - "$OUT" "$QUOTE_OLD" <<'PY'
import shlex, sys
text = open(sys.argv[1]).read()
needle = "visibility unavailable or restricted"
line = next((ln for ln in text.splitlines() if needle in ln), "")
assert line, text
cmd = line.split("remove manually: ", 1)[1].rstrip(")")
assert shlex.split(cmd) == ["rm", "--", sys.argv[2]], (cmd, sys.argv[2])
PY
then
  ok "restricted-visibility cleanup command shell-quotes spaces, quotes, and metacharacters verbatim"
else
  fail "restricted-visibility cleanup command failed shell-quoting check: $(cat "$OUT")"
fi
rm -rf "$QUOTE_BIN_BASE"

# 10. Unreadable/unsearchable AGY_BIN_DIR and inaccessible ancestors fail with UNREADABLE (never silently pass).
UNREAD_PARENT="$(canon_tmpdir)"
UNREAD_BIN="$UNREAD_PARENT/nested/bin"
mkdir -p "$UNREAD_BIN"
printf 'hidden old binary\n' > "$UNREAD_BIN/agy.hidden.old"
trap 'chmod -R u+rwX "$UNREAD_PARENT" 2>/dev/null || true; chmod 700 "$PROC_DIR"/[0-9]* 2>/dev/null || true; rm -rf "$R" "$H" "$EXTERNAL" "$BIN_DIR" "$PROC_DIR" "$BIN_OUTSIDE" "$BIN_LOCAL_HOME" "$UNREAD_PARENT"; rm -f "$OUT" "$CLEAN_MOUNTINFO"' EXIT

for mode in 111 444 000; do
  chmod "$mode" "$UNREAD_BIN"
  if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$UNREAD_BIN" AGY_PROC_DIR="$PROC_DIR" \
    "$R/check-antigravity.sh" > "$OUT" 2>&1; then
    fail "checker silently passed on chmod $mode AGY_BIN_DIR"
  elif grep -q 'UNREADABLE' "$OUT" && ! grep -q 'All good' "$OUT"; then
    ok "checker flags chmod $mode AGY_BIN_DIR as UNREADABLE"
  else
    fail "chmod $mode AGY_BIN_DIR lacked UNREADABLE error: $(cat "$OUT")"
  fi
  chmod 700 "$UNREAD_BIN"
done

chmod 000 "$UNREAD_PARENT/nested"
if HOME="$H" AGY_MOUNTINFO_FILE="$CLEAN_MOUNTINFO" AGY_BIN_DIR="$UNREAD_BIN" AGY_PROC_DIR="$PROC_DIR" \
  "$R/check-antigravity.sh" > "$OUT" 2>&1; then
  fail "checker silently passed when AGY_BIN_DIR ancestor was inaccessible"
elif grep -q 'UNREADABLE.*not searchable' "$OUT" && ! grep -q 'All good' "$OUT"; then
  ok "checker flags inaccessible AGY_BIN_DIR ancestor as UNREADABLE"
else
  fail "inaccessible AGY_BIN_DIR ancestor lacked UNREADABLE error: $(cat "$OUT")"
fi
chmod 700 "$UNREAD_PARENT/nested"
rm -rf "$UNREAD_PARENT"

echo ""
echo "antigravity-config: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
