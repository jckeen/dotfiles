#!/usr/bin/env bash
# codex-threads.test.sh — fixture tests for codex-threads.sh against a fake
# `gh` (no framework). The invariants under test: `list` never prints a
# partial set (a failed or truncated read exits 1), and `resolve` never
# resolves without a reply, never touches a thread the bot did not open, and
# reports a write that did not take. Run directly; exit 1 on any failure.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT="$SCRIPT_DIR/../codex-threads.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake gh. Fixtures live in $FIX: threads_<pr> (GraphQL reviewThreads
# response; absent = read failure), merged (PR numbers), node (thread lookup),
# mutation (mutation response), fail_mutation (fail the write). Every
# mutation is logged to $FIX/writes.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo o/r; exit 0 ;;
  "pr list") cat "$FIX/merged"; exit 0 ;;
esac
all="$*"
case "$all" in
  *mutation*)
    [ -e "$FIX/fail_mutation" ] && { echo "fake gh: mutation failed" >&2; exit 1; }
    echo mutation >>"$FIX/writes"
    cat "$FIX/mutation"
    ;;
  *"node(id"*) cat "$FIX/node" ;;
  *reviewThreads*)
    pr=""
    for a in "$@"; do case "$a" in pr=*) pr=${a#pr=} ;; esac; done
    [ -e "$FIX/threads_$pr" ] || { echo "fake gh: read failed" >&2; exit 1; }
    cat "$FIX/threads_$pr"
    ;;
  *) echo "fake gh: unexpected $all" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL - $1" >&2; }

new_fix() {
  export FIX="$TMP/fix$((pass + fail))"
  rm -rf "$FIX"
  mkdir -p "$FIX"
  : >"$FIX/writes"
}

thread() { # thread <id> <resolved> <outdated> <login> <body>
  jq -nc --arg id "$1" --argjson r "$2" --argjson o "$3" --arg l "$4" --arg b "$5" \
    '{id:$id,isResolved:$r,isOutdated:$o,path:"a.sh",line:7,originalLine:5,
      comments:{nodes:[{author:{login:$l},body:$b,url:("https://x/"+$id)}]}}'
}
threads() { # threads <hasNext> <thread json>...
  local next=$1
  shift
  printf '%s\n' "$@" | jq -sc --argjson n "$next" \
    '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:$n},nodes:.}}}}}'
}
BADGE='**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>  Fix the thing**

details'

# 1. list --pr prints unresolved bot threads only, with priority and title.
new_fix
threads false \
  "$(thread T1 false false chatgpt-codex-connector "$BADGE")" \
  "$(thread T2 true false chatgpt-codex-connector "$BADGE")" \
  "$(thread T3 false true chatgpt-codex-connector '<!-- x -->
### Security note')" \
  "$(thread T4 false false someone "$BADGE")" >"$FIX/threads_9"
out=$("$CT" list --pr 9) && rc=0 || rc=$?
if [ "$rc" = 0 ] &&
  [ "$(wc -l <<<"$out")" = 2 ] &&
  grep -qP '^9\tT1\ta.sh:7\tP1\tcurrent\tFix the thing\thttps://x/T1$' <<<"$out" &&
  grep -qP '^9\tT3\ta.sh:7\t-\toutdated\tSecurity note\t' <<<"$out"; then ok; else bad "list --pr filters and formats (rc=$rc): $out"; fi

# 2. A truncated page fails instead of printing a partial set.
new_fix
threads true "$(thread T1 false false chatgpt-codex-connector "$BADGE")" >"$FIX/threads_9"
out=$("$CT" list --pr 9 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" = 1 ] && [ -z "$out" ]; then ok; else bad "truncated page must exit 1 with no output (rc=$rc)"; fi

# 3. A failed read exits 1.
new_fix
"$CT" list --pr 9 >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" = 1 ]; then ok; else bad "failed read must exit 1 (rc=$rc)"; fi

# 4. --merged-since walks every merged PR, and one failed read fails the run.
new_fix
printf '3\n4\n' >"$FIX/merged"
threads false "$(thread A false false chatgpt-codex-connector[bot] "$BADGE")" >"$FIX/threads_3"
threads false "$(thread B false false chatgpt-codex-connector "$BADGE")" >"$FIX/threads_4"
out=$("$CT" list --merged-since 2026-10-01) && rc=0 || rc=$?
if [ "$rc" = 0 ] && grep -qP '^3\tA\t' <<<"$out" && grep -qP '^4\tB\t' <<<"$out"; then ok; else bad "merged-since lists every PR (rc=$rc): $out"; fi
rm "$FIX/threads_4"
"$CT" list --merged-since 2026-10-01 >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" = 1 ]; then ok; else bad "merged-since with a failed read must exit 1 (rc=$rc)"; fi

# 5. Usage errors exit 2.
new_fix
for args in "list" "list --pr 1 --merged-since 2026-01-01" "resolve --thread T1" \
  "resolve --thread T1 --reply ' '" "bogus"; do
  eval "\"\$CT\" $args" >/dev/null 2>&1 && rc=0 || rc=$?
  if [ "$rc" = 2 ]; then ok; else bad "usage error '$args' must exit 2 (rc=$rc)"; fi
done
if [ ! -s "$FIX/writes" ]; then ok; else bad "usage errors must not write"; fi

node() { # node <login> <resolved>
  jq -nc --arg l "$1" --argjson r "$2" \
    '{data:{node:{isResolved:$r,comments:{nodes:[{author:{login:$l}}]}}}}' >"$FIX/node"
}
mutation() { # mutation <resolved>
  jq -nc --argjson r "$1" \
    '{data:{addPullRequestReviewThreadReply:{comment:{url:"https://x/reply"}},
      resolveReviewThread:{thread:{isResolved:$r}}}}' >"$FIX/mutation"
}

# 6. resolve replies and resolves a bot thread.
new_fix
node chatgpt-codex-connector false
mutation true
out=$("$CT" resolve --thread T1 --reply "Fixed in #9") && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$FIX/writes")" = mutation ] && grep -q '^resolved: T1 https://x/reply$' <<<"$out"; then ok; else bad "resolve bot thread (rc=$rc): $out"; fi

# 7. A thread someone else opened is refused without a write.
new_fix
node someone false
mutation true
"$CT" resolve --thread T1 --reply "x" >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" = 1 ] && [ ! -s "$FIX/writes" ]; then ok; else bad "non-bot thread must be refused (rc=$rc)"; fi

# 8. An already-resolved thread is left alone.
new_fix
node chatgpt-codex-connector true
mutation true
"$CT" resolve --thread T1 --reply "x" >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -s "$FIX/writes" ]; then ok; else bad "resolved thread must not be written (rc=$rc)"; fi

# 9. A failed write, or one that did not resolve, exits 1.
new_fix
node chatgpt-codex-connector false
mutation true
: >"$FIX/fail_mutation"
"$CT" resolve --thread T1 --reply "x" >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" = 1 ]; then ok; else bad "failed mutation must exit 1 (rc=$rc)"; fi
new_fix
node chatgpt-codex-connector false
mutation false
"$CT" resolve --thread T1 --reply "x" >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" = 1 ]; then ok; else bad "unresolved result must exit 1 (rc=$rc)"; fi

echo "codex-threads: $pass passed, $fail failed"
[ "$fail" = 0 ]
