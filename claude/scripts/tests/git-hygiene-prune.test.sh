#!/usr/bin/env bash
# git-hygiene-prune.test.sh — fixture tests for `git-hygiene.sh prune` and the
# hygiene-cron.sh wrapper around it. Builds a throwaway origin + clone under
# mktemp with one branch per classification (merged, squash-merged with and
# without a confirming merged PR, gone upstream, unique work, worktree,
# checked-out, recently touched) and asserts exactly which branches survive.
# `gh` and `curl` are PATH shims, so no network and no plan quota. Run
# directly; exit 1 on any failure. Mirrors antigravity-review-gate.test.sh.
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
HYGIENE="$SCRIPT_DIR/../../../git-hygiene.sh"
CRON="$SCRIPT_DIR/../hygiene-cron.sh"

pass=0
failed=0

# ── PATH shims ─────────────────────────────────────────────────────────
# gh: `auth status` exits GH_FAKE_AUTH_EXIT; `pr list --head X [--base B]`
# records "X B" and replays the "<number> <sha> <base>" rows of
# $GH_FAKE_DIR/pr.X whose base matches B (all rows when no --base was passed —
# which is exactly the bug a base-less query has), printing "<number> <sha>"
# as git-hygiene's --jq does; exits 1 when $GH_FAKE_DIR/fail.X exists.
# curl: records headers + body so the ntfy summary can be asserted.
SHIM_DIR="$(mktemp -d)"
cat > "$SHIM_DIR/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  exit "${GH_FAKE_AUTH_EXIT:-0}"
fi
head="" base="" prev=""
for a in "$@"; do
  [ "$prev" = "--head" ] && head="$a"
  [ "$prev" = "--base" ] && base="$a"
  prev="$a"
done
echo "$head ${base:-<none>}" >> "$GH_FAKE_DIR/calls"
[ -e "$GH_FAKE_DIR/fail.$head" ] && { echo "gh: boom" >&2; exit 1; }
if [ -e "$GH_FAKE_DIR/pr.$head" ]; then
  while read -r num sha prbase; do
    if [ -z "$base" ] || [ "$base" = "$prbase" ]; then echo "$num $sha"; fi
  done < "$GH_FAKE_DIR/pr.$head"
fi
exit 0
EOF
cat > "$SHIM_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_FAKE_DIR/argv"
cat > "$CURL_FAKE_DIR/body"
echo "$(date +%s)" >> "$CURL_FAKE_DIR/calls"
exit 0
EOF
chmod +x "$SHIM_DIR/gh" "$SHIM_DIR/curl"
export PATH="$SHIM_DIR:$PATH"
export GH_FAKE_DIR="" CURL_FAKE_DIR="" GH_FAKE_AUTH_EXIT=0
unset HYGIENE_MIN_AGE_HOURS HYGIENE_REPORT HYGIENE_DELETE HYGIENE_GH_CHECK NTFY_TOPIC NTFY_SERVER

# outgrep / outgrepE — fixed-string / regex match against the last captured $out.
outgrep()  { grep -qF -- "$1" <<<"$out"; }
outgrepE() { grep -qE -- "$1" <<<"$out"; }

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name (condition: $cond)"
  fi
}

# ── fixture ────────────────────────────────────────────────────────────
# build_fixture DIR — DIR/origin.git (bare), DIR/dev/repo (the clone prune
# scans), DIR/gh (GitHub-side clone used to squash-merge and delete remote
# branches), DIR/wt (a worktree). Everything is dated 2026-01-01 so the 24h
# "recently touched" gate is not tripped, except the `recent` branch.
OLD="2026-01-01T00:00:00Z"
g() { GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" git -c user.email=t@t.test -c user.name=test "$@"; }
gh_side() { g -C "$FIX/gh" "$@"; }

commit_file() {  # commit_file REPO NAME MSG
  echo "$3" > "$1/$2"
  g -C "$1" add "$2"
  g -C "$1" commit -qm "$3"
}

# squash_merge NAME — GitHub-side squash of branch NAME into main + delete of
# the remote branch (delete-on-merge), leaving the clone's upstream [gone]
# after its next fetch --prune.
squash_merge() {
  gh_side fetch -q origin
  gh_side checkout -q main
  gh_side pull -q --ff-only origin main
  gh_side merge -q --squash "origin/$1" >/dev/null
  gh_side commit -qm "$1 (#1)"
  gh_side push -q origin main
  gh_side push -q origin --delete "$1"
}

build_fixture() {
  FIX="$1"
  mkdir -p "$FIX/dev"
  git init -q --bare -b main "$FIX/origin.git"
  local seed="$FIX/seed"
  g init -q -b main "$seed"
  commit_file "$seed" seed.txt "seed"
  g -C "$seed" remote add origin "$FIX/origin.git"
  g -C "$seed" push -q -u origin main
  g clone -q "$FIX/origin.git" "$FIX/gh"
  g clone -q "$FIX/origin.git" "$FIX/dev/repo"
  local C="$FIX/dev/repo"

  # merged-ff: its commit IS origin/main's tip (fast-forward merge).
  g -C "$C" checkout -q -b merged-ff
  commit_file "$C" a.txt "A"
  g -C "$C" push -q origin merged-ff:main

  # squash-* : two commits each, squash-merged GitHub-side, remote deleted.
  local br
  for br in squash-nopr squash-pr squash-pr-wrongsha squash-pr-release gh-fail; do
    g -C "$C" checkout -q -b "$br" main
    commit_file "$C" "$br-1.txt" "$br one"
    commit_file "$C" "$br-2.txt" "$br two"
    g -C "$C" push -q -u origin "$br"
    squash_merge "$br"
  done

  # squash-pr-ancestor: the PR grew a commit GitHub-side after this checkout
  # pushed it; the merged head is a fetched descendant of the local tip.
  # squash-pr-unfetched: same shape, but the descendant was never fetched here.
  for br in squash-pr-ancestor squash-pr-unfetched; do
    g -C "$C" checkout -q -b "$br" main
    commit_file "$C" "$br-1.txt" "$br one"
    commit_file "$C" "$br-2.txt" "$br two"
    g -C "$C" push -q -u origin "$br"
    gh_side fetch -q origin
    gh_side checkout -q -b "$br" "origin/$br"
    commit_file "$FIX/gh" "$br-3.txt" "$br three"
    gh_side push -q origin "$br"
    [ "$br" = squash-pr-ancestor ] && g -C "$C" fetch -q origin
    squash_merge "$br"
  done

  # gone-empty: pushed at main's tip, then deleted remotely; nothing unique.
  g -C "$C" checkout -q main
  g -C "$C" branch -q gone-empty
  g -C "$C" push -q -u origin gone-empty
  gh_side push -q origin --delete gone-empty

  # unique-work: an unpushed commit.
  g -C "$C" checkout -q -b unique-work main
  commit_file "$C" u.txt "U"

  # wt-branch: nothing unique, but checked out in a worktree.
  g -C "$C" branch -q wt-branch main
  g -C "$C" worktree add -q "$FIX/wt" wt-branch

  # current-branch: nothing unique, but checked out in the clone.
  g -C "$C" checkout -q -b current-branch main

  # recent: nothing unique, created just now.
  git -C "$C" branch -q recent main

  # Fake GitHub: "<number> <sha> <base>" per merged PR. squash-pr-release's
  # PR merged with this exact tip — but into release/x, never into main.
  GH_FAKE_DIR="$(mktemp -d)"
  echo "7 $(git -C "$C" rev-parse squash-pr) main" > "$GH_FAKE_DIR/pr.squash-pr"
  echo "8 0000000000000000000000000000000000000000 main" > "$GH_FAKE_DIR/pr.squash-pr-wrongsha"
  echo "9 $(git -C "$C" rev-parse gh-fail) main" > "$GH_FAKE_DIR/pr.gh-fail"
  touch "$GH_FAKE_DIR/fail.gh-fail"
  echo "10 $(git -C "$FIX/gh" rev-parse squash-pr-ancestor) main" > "$GH_FAKE_DIR/pr.squash-pr-ancestor"
  echo "11 $(git -C "$FIX/gh" rev-parse squash-pr-unfetched) main" > "$GH_FAKE_DIR/pr.squash-pr-unfetched"
  echo "12 $(git -C "$C" rev-parse squash-pr-release) release/x" > "$GH_FAKE_DIR/pr.squash-pr-release"
}

has_remote_ref() { git -C "$FIX/dev/repo" rev-parse --verify -q "refs/remotes/origin/$1" >/dev/null 2>&1; }

branches() { LC_ALL=C git -C "$FIX/dev/repo" for-each-ref --format='%(refname:short)' refs/heads/ | LC_ALL=C sort | tr '\n' ' '; }
has_branch() { git -C "$FIX/dev/repo" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }

ALL="current-branch gh-fail gone-empty main merged-ff recent squash-nopr squash-pr squash-pr-ancestor squash-pr-release squash-pr-unfetched squash-pr-wrongsha unique-work wt-branch "

# ── prune: dry-run deletes nothing, writes nothing, names what it would ──
# The clone has never run fetch --prune, so origin/squash-pr is a stale
# remote-tracking ref (the remote branch is gone); origin/HEAD is removed so
# the default-branch lookup has to happen without `remote set-head`.
build_fixture "$(mktemp -d)"
git -C "$FIX/dev/repo" symbolic-ref -d refs/remotes/origin/HEAD
assert "dry-run precondition: stale origin/squash-pr present" "has_remote_ref squash-pr"
out="$("$HYGIENE" prune "$FIX/dev" --yes --dry-run --gh 2>&1)"
assert "dry-run: every branch survives" "[ \"\$(branches)\" = \"$ALL\" ]"
assert "dry-run: stale remote-tracking ref not pruned" "has_remote_ref squash-pr"
assert "dry-run: origin/HEAD not written" "! has_remote_ref HEAD"
assert "dry-run: reports the default it resolved read-only" "outgrep 'would set origin/HEAD -> main'"
assert "dry-run: reports refs the real run would prune" "outgrepE 'would prune [1-9][0-9]* stale remote-tracking ref'"
assert "dry-run: would delete merged-ff" "outgrep 'would delete merged-ff'"
assert "dry-run: would delete squash-pr (gh confirms; upstream would be pruned)" "outgrep 'would delete squash-pr '"
assert "dry-run: would delete gone-empty" "outgrep 'would delete gone-empty'"
assert "dry-run: keeps squash-nopr" "outgrep 'squash-nopr — kept'"
assert "dry-run: keeps squash-pr-release (PR base is not the default)" "outgrep 'squash-pr-release — kept'"
assert "dry-run: banner says dry-run" "outgrep 'prune (dry-run)'"

# ── prune without --gh: only zero-unique-commit branches go ────────────
: > "$GH_FAKE_DIR/calls"
report="$(mktemp)"
out="$(HYGIENE_REPORT="$report" "$HYGIENE" prune "$FIX/dev" --yes 2>&1)"
assert "no --gh: merged-ff deleted" "! has_branch merged-ff"
assert "no --gh: gone-empty deleted" "! has_branch gone-empty"
assert "no --gh: squash-pr kept (no GitHub check)" "has_branch squash-pr"
assert "no --gh: gh never called" "[ ! -s '$GH_FAKE_DIR/calls' ]"
assert "no --gh: unique-work kept" "has_branch unique-work"
assert "no --gh: worktree branch kept" "has_branch wt-branch"
assert "no --gh: checked-out branch kept" "has_branch current-branch"
assert "no --gh: recent branch kept" "has_branch recent"
assert "no --gh: recent branch reported as touched" "outgrep 'recent — kept: touched'"
assert "no --gh: deletion line carries full sha + recovery command" \
  "outgrepE 'deleted merged-ff \(was [0-9a-f]{40} — merged into origin/main; recover: git branch merged-ff [0-9a-f]{40}\)'"
assert "no --gh: report has repo, branch, sha, reason" \
  "grep -qE $'^repo\\tmerged-ff\\t[0-9a-f]{40}\\tmerged into origin/main$' '$report'"
assert "no --gh: report has exactly 2 rows" "[ \"\$(wc -l < '$report')\" -eq 2 ]"

# ── --gh without a login: warns, stays closed ───────────────────────────
out="$(GH_FAKE_AUTH_EXIT=1 "$HYGIENE" prune "$FIX/dev" --yes --gh 2>&1)"
assert "--gh unauthenticated: warning printed" "outgrep 'not authenticated'"
assert "--gh unauthenticated: squash-pr kept" "has_branch squash-pr"
assert "--gh unauthenticated: gh pr list never called" "[ ! -s '$GH_FAKE_DIR/calls' ]"

# ── --gh with a login: only an exact-tip merged PR unlocks a squash branch ─
out="$("$HYGIENE" prune "$FIX/dev" --yes --gh 2>&1)"
assert "--gh: squash-pr deleted" "! has_branch squash-pr"
assert "--gh: deletion reason names the PR" "outgrepE 'deleted squash-pr .*PR #7 merged into main on GitHub with this exact tip'"
assert "--gh: squash-nopr kept (no merged PR)" "has_branch squash-nopr"
assert "--gh: squash-pr-wrongsha kept (PR head is not this tip)" "has_branch squash-pr-wrongsha"
assert "--gh: gh-fail kept (gh error fails closed)" "has_branch gh-fail"
assert "--gh: squash-pr-ancestor deleted (local tip is an ancestor of the fetched PR head)" "! has_branch squash-pr-ancestor"
assert "--gh: ancestor reason names the PR" "outgrepE 'deleted squash-pr-ancestor .*PR #10 merged into main on GitHub; local tip is an ancestor of its head [0-9a-f]{7}'"
assert "--gh: squash-pr-unfetched kept (PR head object absent locally)" "has_branch squash-pr-unfetched"
assert "--gh: squash-pr-release kept (merged into release/x, never into main)" "has_branch squash-pr-release"
assert "--gh: gh asked about squash-pr with --base main" "grep -qx 'squash-pr main' '$GH_FAKE_DIR/calls'"
assert "--gh: every gh query carried the default base" "! grep -q '<none>' '$GH_FAKE_DIR/calls'"
assert "--gh: survivors are exactly the unsafe set" \
  "[ \"\$(branches)\" = 'current-branch gh-fail main recent squash-nopr squash-pr-release squash-pr-unfetched squash-pr-wrongsha unique-work wt-branch ' ]"

# ── age window is configurable ──────────────────────────────────────────
out="$(HYGIENE_MIN_AGE_HOURS=0 "$HYGIENE" prune "$FIX/dev" --yes 2>&1)"
assert "MIN_AGE=0: recent deleted" "! has_branch recent"
assert "MIN_AGE=0: unique-work still kept" "has_branch unique-work"
rm -rf "$FIX" "$GH_FAKE_DIR" "$report"

# ── flag hygiene ────────────────────────────────────────────────────────
out="$("$HYGIENE" clean "$HOME" --gh 2>&1)"; rc=$?
assert "--gh rejected outside prune" "[ $rc -ne 0 ] && outgrep 'only applies to prune'"
out="$("$HYGIENE" --help 2>&1)"
assert "--help documents prune" "outgrep prune && outgrep -- --dry-run"

# ── hygiene-cron: prune runs daily, logs, notifies only when it deleted ──
# HOME is a throwaway; gh-bootstrap.sh is stubbed; git-hygiene.sh is the real
# one; NTFY_TOPIC comes from the settings.json fallback (systemd has no env).
build_fixture "$(mktemp -d)"
H="$(mktemp -d)"
mkdir -p "$H/.claude" "$H/stub"
echo '{"env":{"NTFY_TOPIC":"test-topic"}}' > "$H/.claude/settings.json"
printf '#!/usr/bin/env bash\necho "  repo — clean"\n' > "$H/stub/gh-bootstrap.sh"
chmod +x "$H/stub/gh-bootstrap.sh"
ln -s "$(cd -P "$(dirname "$HYGIENE")" && pwd)/git-hygiene.sh" "$H/stub/git-hygiene.sh"
CURL_FAKE_DIR="$(mktemp -d)"
export CURL_FAKE_DIR
HOME="$H" HYGIENE_DEV_DIR="$FIX/dev" HYGIENE_SCRIPT_DIR="$H/stub" "$CRON"
log="$H/.local/state/hygiene/cron.log"
assert "cron: log written" "[ -s '$log' ]"
assert "cron: status.json written" "grep -q '\"drift_count\": 0' '$H/.local/state/hygiene/status.json'"
assert "cron: prune ran with --gh" "grep -q 'git-hygiene prune .* --yes --gh' '$log'"
assert "cron: merged-ff deleted" "! has_branch merged-ff"
assert "cron: squash-pr deleted via merged PR" "! has_branch squash-pr"
assert "cron: unique-work kept" "has_branch unique-work"
assert "cron: log carries the recovery sha" "grep -qE 'recover: git branch merged-ff [0-9a-f]{40}' '$log'"
assert "cron: deletions.tsv appended (4 rows)" "[ \"\$(wc -l < '$H/.local/state/hygiene/deletions.tsv')\" -eq 4 ]"
assert "cron: ntfy sent once" "[ \"\$(wc -l < '$CURL_FAKE_DIR/calls')\" -eq 1 ]"
assert "cron: ntfy URL uses settings.json topic" "grep -qx 'https://ntfy.sh/test-topic' '$CURL_FAKE_DIR/argv'"
assert "cron: ntfy title counts deletions" "grep -qx 'Title: git-hygiene: pruned 4 branch(es)' '$CURL_FAKE_DIR/argv'"
assert "cron: ntfy body is counts + log path" \
  "grep -qx 'git-hygiene pruned 4 branch(es) across 1 repo(s); details and recovery SHAs in ~/.local/state/hygiene/cron.log' '$CURL_FAKE_DIR/body'"
assert "cron: ntfy body carries no repo or branch names" \
  "! grep -qE 'repo:|merged-ff|squash-pr|gone-empty|[0-9a-f]{40}' '$CURL_FAKE_DIR/body' '$CURL_FAKE_DIR/argv'"
assert "cron: ntfy body does not leak \$HOME" "! grep -qF \"$H\" '$CURL_FAKE_DIR/body'"
assert "cron: log still names every deleted branch" "grep -q 'deleted squash-pr ' '$log'"

# Second run: nothing left to delete → no notification.
HOME="$H" HYGIENE_DEV_DIR="$FIX/dev" HYGIENE_SCRIPT_DIR="$H/stub" "$CRON"
assert "cron: zero deletions → no ntfy" "[ \"\$(wc -l < '$CURL_FAKE_DIR/calls')\" -eq 1 ]"
assert "cron: zero deletions logged" "grep -q 'pruned 0 branches — no notification' '$log'"
rm -rf "$FIX" "$GH_FAKE_DIR" "$H" "$CURL_FAKE_DIR"

# ── hygiene-cron: NTFY_SERVER overrides the ntfy host ───────────────────
build_fixture "$(mktemp -d)"
H="$(mktemp -d)"
mkdir -p "$H/stub"
printf '#!/usr/bin/env bash\necho "  repo — clean"\n' > "$H/stub/gh-bootstrap.sh"
chmod +x "$H/stub/gh-bootstrap.sh"
ln -s "$(cd -P "$(dirname "$HYGIENE")" && pwd)/git-hygiene.sh" "$H/stub/git-hygiene.sh"
CURL_FAKE_DIR="$(mktemp -d)"
HOME="$H" NTFY_TOPIC=t2 NTFY_SERVER=https://ntfy.example.com/sub HYGIENE_DEV_DIR="$FIX/dev" HYGIENE_SCRIPT_DIR="$H/stub" "$CRON"
assert "NTFY_SERVER: ntfy URL uses the override" "grep -qx 'https://ntfy.example.com/sub/t2' '$CURL_FAKE_DIR/argv'"
rm -rf "$FIX" "$GH_FAKE_DIR" "$H" "$CURL_FAKE_DIR"

# ── hygiene-cron: HYGIENE_DELETE=0 disables the prune entirely ──────────
build_fixture "$(mktemp -d)"
H="$(mktemp -d)"
mkdir -p "$H/stub"
printf '#!/usr/bin/env bash\necho "  repo — clean"\n' > "$H/stub/gh-bootstrap.sh"
chmod +x "$H/stub/gh-bootstrap.sh"
ln -s "$(cd -P "$(dirname "$HYGIENE")" && pwd)/git-hygiene.sh" "$H/stub/git-hygiene.sh"
CURL_FAKE_DIR="$(mktemp -d)"
HOME="$H" HYGIENE_DELETE=0 HYGIENE_DEV_DIR="$FIX/dev" HYGIENE_SCRIPT_DIR="$H/stub" "$CRON"
log="$H/.local/state/hygiene/cron.log"
assert "HYGIENE_DELETE=0: skip logged" "grep -q 'HYGIENE_DELETE=0 — skipping' '$log'"
assert "HYGIENE_DELETE=0: every branch survives" "[ \"\$(branches)\" = \"$ALL\" ]"
assert "HYGIENE_DELETE=0: no ntfy" "[ ! -e '$CURL_FAKE_DIR/calls' ]"
rm -rf "$FIX" "$GH_FAKE_DIR" "$H" "$CURL_FAKE_DIR" "$SHIM_DIR"

echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
