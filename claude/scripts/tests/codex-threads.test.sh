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
# reply / resolve (mutation responses), fail_reply / fail_resolve (fail that
# write), wf (absent | missing = HTTP 404 | error = HTTP 500 for the
# codex-findings workflow lookup), fail_dispatch. Every write is logged to
# $FIX/writes.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo o/r; exit 0 ;;
  "pr list") cat "$FIX/merged"; exit 0 ;;
  "workflow run")
    [ -e "$FIX/fail_dispatch" ] && exit 1
    echo "dispatch $*" >>"$FIX/writes"
    exit 0
    ;;
esac
all="$*"
case "$all" in
  *addPullRequestReviewThreadReply*)
    [ -e "$FIX/fail_reply" ] && { echo "fake gh: reply failed" >&2; exit 1; }
    echo reply >>"$FIX/writes"
    cat "$FIX/reply"
    ;;
  *resolveReviewThread*)
    [ -e "$FIX/fail_resolve" ] && { echo "fake gh: resolve failed" >&2; exit 1; }
    echo resolve >>"$FIX/writes"
    cat "$FIX/resolve"
    ;;
  *actions/workflows/codex-findings.yml*)
    case "$(cat "$FIX/wf" 2>/dev/null)" in
      missing) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      error) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
    esac
    echo '{}'
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

thread() { # thread <id> <resolved> <outdated> <login> <body> [type]
  jq -nc --arg id "$1" --argjson r "$2" --argjson o "$3" --arg l "$4" --arg b "$5" \
    --arg t "${6:-Bot}" \
    '{id:$id,isResolved:$r,isOutdated:$o,path:"a.sh",line:7,originalLine:5,
      comments:{nodes:[{author:{__typename:$t,login:$l},body:$b,url:("https://x/"+$id)}]}}'
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
  "$(thread T4 false false someone "$BADGE" User)" \
  "$(thread T5 false false chatgpt-codex-connector "$BADGE" User)" >"$FIX/threads_9"
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

# 4b. A merged-PR list that reaches the limit may be truncated: refused.
new_fix
seq 1 1000 >"$FIX/merged"
out=$("$CT" list --merged-since 2026-01-01 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" = 1 ] && [ -z "$out" ]; then ok; else bad "a merged list at the limit must exit 1 (rc=$rc)"; fi

# 5. Usage errors exit 2.
new_fix
for args in "list" "list --pr 1 --merged-since 2026-01-01" "resolve --thread T1" \
  "resolve --thread T1 --reply ' '" "bogus"; do
  eval "\"\$CT\" $args" >/dev/null 2>&1 && rc=0 || rc=$?
  if [ "$rc" = 2 ]; then ok; else bad "usage error '$args' must exit 2 (rc=$rc)"; fi
done
if [ ! -s "$FIX/writes" ]; then ok; else bad "usage errors must not write"; fi

node() { # node <login> <resolved> [type] [repo]  (the thread is on PR 9)
  jq -nc --arg l "$1" --argjson r "$2" --arg t "${3:-Bot}" --arg repo "${4:-o/r}" \
    '{data:{node:{isResolved:$r,pullRequest:{number:9,repository:{nameWithOwner:$repo}},
      comments:{nodes:[{author:{__typename:$t,login:$l}}]}}}}' >"$FIX/node"
}
mutations() { # mutations <reply posted:true|false> <resolved:true|false>
  if [ "$1" = true ]; then
    echo '{"data":{"addPullRequestReviewThreadReply":{"comment":{"url":"https://x/reply"}}}}' >"$FIX/reply"
  else
    echo '{"data":{"addPullRequestReviewThreadReply":null},"errors":[{"message":"body too long"}]}' >"$FIX/reply"
  fi
  jq -nc --argjson r "$2" '{data:{resolveReviewThread:{thread:{isResolved:$r}}}}' >"$FIX/resolve"
}
# resolve_case <name> <expected rc> <expected writes, ; separated> [stderr pattern]
resolve_case() {
  local out got
  out=$("$CT" resolve --thread T1 --reply "Fixed in #9" 2>&1) && rc=0 || rc=$?
  got=$(paste -sd';' "$FIX/writes")
  if [ "$rc" = "$2" ] && [ "$got" = "$3" ] && { [ -z "${4:-}" ] || grep -q -- "$4" <<<"$out"; }; then
    ok
  else
    bad "$1: rc=$rc writes='$got' (want rc=$2 writes='$3'): $out"
  fi
}
OTHER=$(thread T2 false false chatgpt-codex-connector "$BADGE")

new_fix
node chatgpt-codex-connector false
mutations true true
threads false "$OTHER" >"$FIX/threads_9"
resolve_case "resolve replies, then resolves; other bot threads keep the label" 0 "reply;resolve" '^resolved: T1 https://x/reply$'

new_fix
node chatgpt-codex-connector false
mutations true true
threads false >"$FIX/threads_9"
resolve_case "the PR's last bot thread starts codex-findings" 0 \
  "reply;resolve;dispatch workflow run codex-findings.yml -R o/r -f pr=9"

new_fix
node chatgpt-codex-connector false
mutations true true
threads false >"$FIX/threads_9"
echo missing >"$FIX/wf"
resolve_case "a repo without codex-findings needs no dispatch" 0 "reply;resolve" "has no codex-findings workflow"

new_fix
node chatgpt-codex-connector false
mutations true true
threads false >"$FIX/threads_9"
echo error >"$FIX/wf"
resolve_case "a failed workflow lookup fails and names the recount" 1 "reply;resolve" "run: gh workflow run codex-findings.yml -R o/r -f pr=9"

new_fix
node chatgpt-codex-connector false
mutations true true
threads false >"$FIX/threads_9"
: >"$FIX/fail_dispatch"
resolve_case "a failed dispatch fails and names the recount" 1 "reply;resolve" "run: gh workflow run"

new_fix
node chatgpt-codex-connector false
mutations true true
resolve_case "a failed recount fails and names the recount" 1 "reply;resolve" "could not recount #9; run: gh workflow run"

new_fix
node chatgpt-codex-connector false
mutations false true
resolve_case "a reply that did not post never resolves" 1 "reply" "was not resolved"

new_fix
node chatgpt-codex-connector false
mutations true true
: >"$FIX/fail_reply"
resolve_case "a failed reply never resolves" 1 "" "was not resolved"

new_fix
node chatgpt-codex-connector false
mutations true true
: >"$FIX/fail_resolve"
resolve_case "a failed resolve after the reply fails" 1 "reply" "could not resolve it"

new_fix
node chatgpt-codex-connector false
mutations true false
resolve_case "a resolve that did not take fails" 1 "reply;resolve" "did not resolve"

new_fix
node someone false User
mutations true true
resolve_case "a thread someone else opened is refused" 1 "" "not the Codex bot"

new_fix
node chatgpt-codex-connector false User
mutations true true
resolve_case "a user holding the bot's bare login is refused" 1 "" "not the Codex bot"

new_fix
node chatgpt-codex-connector false Bot other/repo
mutations true true
resolve_case "a thread from another repository is refused" 1 "" "belongs to other/repo"

new_fix
node chatgpt-codex-connector true
mutations true true
resolve_case "an already-resolved thread is left alone" 0 "" "already resolved"

echo "codex-threads: $pass passed, $fail failed"
[ "$fail" = 0 ]
