#!/usr/bin/env bash
# overnight.test.sh — fixture tests for overnight.sh (#740 hardening).
# Verifies Phase 2 dirty-tree auto-stash isolation before Phase 3 runs,
# clean-tree preflight preserving operator work, skipping Phase 3 on stash
# failure, and non-zero exit + summary report recording when any phase fails.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
REAL_OVERNIGHT="$SCRIPT_DIR/../overnight.sh"

pass=0
failed=0
ok()   { pass=$((pass + 1));   echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

command -v git >/dev/null 2>&1 || { echo "overnight.test: git is required" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Copy overnight.sh beside stub phase scripts in a temp bin directory.
mkdir -p "$T/bin" "$T/logs" "$T/repo"
cp "$REAL_OVERNIGHT" "$T/bin/overnight.sh"
chmod +x "$T/bin/overnight.sh"

git -C "$T/repo" init -q
git -C "$T/repo" config user.email "test@example.com"
git -C "$T/repo" config user.name "Test User"
git -C "$T/repo" config status.showUntrackedFiles no
printf 'base\n' > "$T/repo/file.txt"
git -C "$T/repo" add file.txt
git -C "$T/repo" commit -q -m "chore: init"

cat > "$T/bin/health-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$T/bin/test-coverage.sh" <<'SH'
#!/usr/bin/env bash
# Simulate Phase 2 leaving an uncommitted tracked edit and an untracked file.
printf 'phase2 edit\n' >> "$1/file.txt"
printf 'new\n' > "$1/phase2-new.txt"
exit 0
SH
cat > "$T/bin/fix-issues.sh" <<'SH'
#!/usr/bin/env bash
# Fail if Phase 3 sees a dirty working tree from Phase 2.
if [ -n "$(git -C "$1" status --porcelain)" ]; then
  echo "DIRTY_TREE_SEEN_IN_PHASE3" >&2
  exit 9
fi
exit 0
SH
chmod +x "$T/bin/health-check.sh" "$T/bin/test-coverage.sh" "$T/bin/fix-issues.sh"

# 1. Phase 2 dirty edits are stashed cleanly before Phase 3 runs, summary created.
out="$(CLAUDE_REPOS="$T/repo" LOG_DIR="$T/logs" "$T/bin/overnight.sh" --deep 2>&1)"; rc=$?
summary="$(find "$T/logs" -maxdepth 1 -name 'overnight-summary-*.md' | head -1)"
if [ "$rc" -eq 0 ] && [ -n "$summary" ] && grep -q 'phase2-stash | stashed' "$summary" \
  && [ -z "$(git -C "$T/repo" status --porcelain)" ] \
  && git -C "$T/repo" stash list | grep -q 'overnight-phase2-autostash-'; then
  ok "Phase 2 dirty edits are stashed before Phase 3 and recorded in summary"
else
  fail "Phase 2 isolation failed: rc=$rc summary=$summary out=$out"
fi

# 2. Pre-existing dirty working tree is NOT stashed and skips Phase 2 & Phase 3.
printf 'operator work\n' > "$T/repo/operator-wip.txt"
rm -f "$T/logs"/overnight-summary-*.md
out_dirty="$(CLAUDE_REPOS="$T/repo" LOG_DIR="$T/logs" "$T/bin/overnight.sh" --deep 2>&1)"; rc_dirty=$?
summary_dirty="$(find "$T/logs" -maxdepth 1 -name 'overnight-summary-*.md' | sort | tail -1)"
if [ "$rc_dirty" -ne 0 ] && [ -f "$T/repo/operator-wip.txt" ] \
  && grep -q 'test-coverage | skipped' "$summary_dirty" \
  && grep -q 'fix-issues | skipped' "$summary_dirty"; then
  ok "pre-existing dirty tree is preserved untouched and skips Phase 2 and Phase 3"
else
  fail "pre-existing dirty tree handling wrong: rc=$rc_dirty summary=$summary_dirty out=$out_dirty"
fi
rm -f "$T/repo/operator-wip.txt"

# 3. Phase 2 stash failure skips Phase 3 instead of running fix-issues on dirty tree.
cat > "$T/bin/test-coverage.sh" <<'SH'
#!/usr/bin/env bash
printf 'phase2 unmerged\n' >> "$1/file.txt"
: > "$1/.git/index.lock"
exit 0
SH
cat > "$T/bin/fix-issues.sh" <<'SH'
#!/usr/bin/env bash
echo "PHASE3_SHOULD_NOT_RUN" >&2
exit 88
SH
chmod +x "$T/bin/test-coverage.sh" "$T/bin/fix-issues.sh"
rm -f "$T/logs"/overnight-summary-*.md
out_stash_fail="$(CLAUDE_REPOS="$T/repo" LOG_DIR="$T/logs" "$T/bin/overnight.sh" --deep 2>&1)"; rc_stash_fail=$?
summary_sf="$(find "$T/logs" -maxdepth 1 -name 'overnight-summary-*.md' | sort | tail -1)"
rm -f "$T/repo/.git/index.lock"
git -C "$T/repo" checkout -q -- file.txt
if [ "$rc_stash_fail" -ne 0 ] && grep -q 'phase2-stash | failed' "$summary_sf" \
  && grep -q 'fix-issues | skipped' "$summary_sf" \
  && ! grep -q 'PHASE3_SHOULD_NOT_RUN' <<<"$out_stash_fail"; then
  ok "Phase 2 stash failure skips Phase 3 and exits non-zero"
else
  fail "Phase 2 stash failure leaked into Phase 3: rc=$rc_stash_fail summary=$summary_sf out=$out_stash_fail"
fi

# 4. Corrupt index causes git status failure -> fails closed and skips Phase 2 & Phase 3.
cp "$T/repo/.git/index" "$T/index.bak"
printf 'bad' > "$T/repo/.git/index"
cat > "$T/bin/test-coverage.sh" <<'SH'
#!/usr/bin/env bash
echo "PHASE2_SHOULD_NOT_RUN" >&2
exit 87
SH
cat > "$T/bin/fix-issues.sh" <<'SH'
#!/usr/bin/env bash
echo "PHASE3_SHOULD_NOT_RUN" >&2
exit 88
SH
chmod +x "$T/bin/test-coverage.sh" "$T/bin/fix-issues.sh"
rm -f "$T/logs"/overnight-summary-*.md
out_idx="$(CLAUDE_REPOS="$T/repo" LOG_DIR="$T/logs" "$T/bin/overnight.sh" --deep 2>&1)"; rc_idx=$?
summary_idx="$(find "$T/logs" -maxdepth 1 -name 'overnight-summary-*.md' | sort | tail -1)"
mv "$T/index.bak" "$T/repo/.git/index"
if [ "$rc_idx" -ne 0 ] && grep -q 'git status inspection failed' "$summary_idx" \
  && grep -q 'fix-issues | skipped' "$summary_idx" \
  && ! grep -q 'PHASE2_SHOULD_NOT_RUN' <<<"$out_idx" \
  && ! grep -q 'PHASE3_SHOULD_NOT_RUN' <<<"$out_idx"; then
  ok "corrupt index git status failure fails closed and skips Phase 2 and Phase 3"
else
  fail "corrupt index handling wrong: rc=$rc_idx summary=$summary_idx out=$out_idx"
fi

# 5. Failed task returns non-zero and records failure in summary instead of || true.
cat > "$T/bin/test-coverage.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$T/bin/fix-issues.sh" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$T/bin/test-coverage.sh" "$T/bin/fix-issues.sh"
rm -f "$T/logs"/overnight-summary-*.md
out2="$(CLAUDE_REPOS="$T/repo" LOG_DIR="$T/logs" "$T/bin/overnight.sh" --deep 2>&1)"; rc2=$?
summary2="$(find "$T/logs" -maxdepth 1 -name 'overnight-summary-*.md' | sort | tail -1)"
if [ "$rc2" -ne 0 ] && grep -q 'fix-issues | failed | 7' "$summary2"; then
  ok "failed Phase 3 exits non-zero and records failure in summary"
else
  fail "failure propagation wrong: rc=$rc2 summary=$summary2 out=$out2"
fi

# 6. Broken .git/HEAD (rev-parse failure) fails closed and skips Phase 2 and Phase 3.
cp "$T/repo/.git/HEAD" "$T/head.bak"
printf 'invalid-head\n' > "$T/repo/.git/HEAD"
cat > "$T/bin/test-coverage.sh" <<'SH'
#!/usr/bin/env bash
echo "PHASE2_SHOULD_NOT_RUN" >&2
exit 87
SH
cat > "$T/bin/fix-issues.sh" <<'SH'
#!/usr/bin/env bash
echo "PHASE3_SHOULD_NOT_RUN" >&2
exit 88
SH
chmod +x "$T/bin/test-coverage.sh" "$T/bin/fix-issues.sh"
rm -f "$T/logs"/overnight-summary-*.md
out_head="$(CLAUDE_REPOS="$T/repo" LOG_DIR="$T/logs" "$T/bin/overnight.sh" --deep 2>&1)"; rc_head=$?
summary_head="$(find "$T/logs" -maxdepth 1 -name 'overnight-summary-*.md' | sort | tail -1)"
mv "$T/head.bak" "$T/repo/.git/HEAD"
if [ "$rc_head" -ne 0 ] && grep -q 'git status inspection failed' "$summary_head" \
  && grep -q 'fix-issues | skipped' "$summary_head" \
  && ! grep -q 'PHASE2_SHOULD_NOT_RUN' <<<"$out_head" \
  && ! grep -q 'PHASE3_SHOULD_NOT_RUN' <<<"$out_head"; then
  ok "broken HEAD rev-parse failure fails closed and skips Phase 2 and Phase 3"
else
  fail "broken HEAD handling wrong: rc=$rc_head summary=$summary_head out=$out_head"
fi

echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
