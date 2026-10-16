#!/usr/bin/env bash
# codex-findings-label.test.sh — fixture tests for the labelling script in
# .github/workflows/codex-findings.yml, extracted between its
# `# >>> codex-findings-label` / `# <<< codex-findings-label` markers and run
# against a fake `gh` (no framework). The invariants under test: the label
# tracks exactly the unresolved threads the Codex bot opened (a user account
# holding the bot's bare login does not count), a failed or truncated read
# changes nothing, and closed and fork PRs are left alone. Run directly; exit 1 on any
# failure.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${CODEX_FINDINGS_WORKFLOW:-$SCRIPT_DIR/../../../.github/workflows/codex-findings.yml}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk '/# >>> codex-findings-label/{on=1} on{print} /# <<< codex-findings-label/{on=0}' "$WF" |
  sed 's/^          //' >"$TMP/label.sh"
# CI's actionlint runs shellcheck on this script at every severity, so the
# self-test does too (a warning-only run let an info finding reach CI).
if command -v shellcheck >/dev/null && ! shellcheck -s bash "$TMP/label.sh" >&2; then
  echo "FAIL - shellcheck reported the extracted script" >&2
  exit 1
fi
grep -q '# <<< codex-findings-label' "$TMP/label.sh" || {
  echo "FAIL - could not extract the script from $WF" >&2
  exit 1
}

# Fake gh. Fixtures in $FIX: graphql (response; absent = read failure),
# label_exists (repo label present), label_error (the label lookup fails with
# HTTP 500), fail_write (fail every write). Set FORK=true before graphql to
# make the PR a fork PR. Every
# write is logged to $FIX/writes as "<METHOD> <path>".
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
all="$*"
if [ "$1 $2" = "api graphql" ]; then
  [ -e "$FIX/graphql" ] || { echo "fake gh: read failed" >&2; exit 1; }
  cat "$FIX/graphql"
  exit 0
fi
method=GET
[[ "$all" == *"-X POST"* ]] && method=POST
[[ "$all" == *"-X DELETE"* ]] && method=DELETE
path=""
for a in "$@"; do case "$a" in repos/*) path=${a#repos/o/r/} ;; esac; done
if [ "$method" = GET ]; then
  case "$path" in
    labels/codex-findings)
      [ -e "$FIX/label_error" ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
      [ -e "$FIX/label_exists" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      ;;
    *) echo "fake gh: unexpected GET $path" >&2; exit 1 ;;
  esac
  exit 0
fi
[ -e "$FIX/fail_write" ] && { echo "fake gh: write failed" >&2; exit 1; }
echo "$method $path" >>"$FIX/writes"
[ "$path" = labels ] && : >"$FIX/label_exists"
exit 0
FAKE
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" REPO=o/r PR=7

pass=0 fail=0
n=0
new_fix() {
  n=$((n + 1))
  export FIX="$TMP/fix$n"
  mkdir -p "$FIX"
  : >"$FIX/writes"
}
# graphql <state> <hasNext> <labelled:true|false> <thread spec>...
# A thread spec is resolved:type:login, e.g. false:Bot:chatgpt-codex-connector.
graphql() {
  local state=$1 next=$2 labelled=$3
  shift 3
  local t threads=()
  for t in "$@"; do
    IFS=: read -r r ty lo <<<"$t"
    threads+=("$(jq -nc --argjson r "$r" --arg t "$ty" --arg l "$lo" \
      '{isResolved:$r,comments:{nodes:[{author:{__typename:$t,login:$l}}]}}')")
  done
  printf '%s\n' "${threads[@]}" | jq -sc --arg s "$state" --argjson n "$next" --argjson lab "$labelled" \
    --argjson fork "${FORK:-false}" \
    '{data:{repository:{pullRequest:{state:$s,isCrossRepository:$fork,
       labels:{pageInfo:{hasNextPage:false},nodes:(if $lab then [{name:"codex-findings"}] else [] end)},
       reviewThreads:{pageInfo:{hasNextPage:$n},nodes:.}}}}}' >"$FIX/graphql"
}
run() { bash "$TMP/label.sh" >"$FIX/out" 2>&1 && rc=0 || rc=$?; }
check() { # check <name> <expected rc> <expected writes, ; separated>
  local got
  got=$(paste -sd';' "$FIX/writes")
  if [ "$rc" = "$2" ] && [ "$got" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL - $1: rc=$rc writes='$got' (want rc=$2 writes='$3')" >&2
    sed 's/^/    /' "$FIX/out" >&2
  fi
}
BOT=false:Bot:chatgpt-codex-connector

new_fix
graphql OPEN false false "$BOT" true:Bot:chatgpt-codex-connector
run
check "unresolved bot thread creates and adds the label" 0 "POST labels;POST issues/7/labels"

new_fix
: >"$FIX/label_exists"
graphql OPEN false false "$BOT"
run
check "existing label is reused" 0 "POST issues/7/labels"

new_fix
graphql OPEN false true "$BOT"
run
check "already labelled is unchanged" 0 ""

new_fix
graphql OPEN false true true:Bot:chatgpt-codex-connector
run
check "all resolved removes the label" 0 "DELETE issues/7/labels/codex-findings"

new_fix
graphql OPEN false false false:User:chatgpt-codex-connector false:User:someone false:Bot:other-bot
run
check "threads not opened by the Codex bot do not count" 0 ""

new_fix
graphql OPEN false true false:User:chatgpt-codex-connector
run
check "a user holding the bot's login does not keep the label" 0 "DELETE issues/7/labels/codex-findings"

new_fix
graphql OPEN true false "$BOT"
run
check "truncated thread page fails and writes nothing" 1 ""

new_fix
run
check "failed read fails and writes nothing" 1 ""

new_fix
graphql OPEN false true "$BOT"
jq -c '.data.repository.pullRequest.reviewThreads.nodes = [null]' "$FIX/graphql" >"$FIX/g2" && mv "$FIX/g2" "$FIX/graphql"
run
check "a null thread node never clears the label" 1 ""

new_fix
graphql OPEN false true "$BOT"
jq -c '.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes = [null]' "$FIX/graphql" >"$FIX/g2" && mv "$FIX/g2" "$FIX/graphql"
run
check "an unreadable first comment never clears the label" 1 ""

# mutate <jq assignment>: rewrite the current fixture's graphql response.
mutate() { jq -c "$1" "$FIX/graphql" >"$FIX/g2" && mv "$FIX/g2" "$FIX/graphql"; }
P=.data.repository.pullRequest

new_fix
graphql OPEN false true "$BOT"
mutate "$P.reviewThreads.nodes[0].comments.nodes[0].author = null"
run
check "an unresolved thread with an unreadable author never clears the label" 1 ""

new_fix
graphql OPEN false true "$BOT" true:Bot:chatgpt-codex-connector
mutate "$P.reviewThreads.nodes[1].comments.nodes[0].author = null"
mutate "$P.reviewThreads.nodes[0].isResolved = true"
run
check "a resolved thread's unreadable author does not block the count" 0 "DELETE issues/7/labels/codex-findings"

new_fix
graphql OPEN false false
mutate "$P.labels.nodes = [null]"
run
check "an unreadable label entry fails and writes nothing" 1 ""

new_fix
graphql OPEN false false "$BOT"
mutate "$P.labels.pageInfo.hasNextPage = true"
run
check "a truncated label page fails and writes nothing" 1 ""

new_fix
graphql OPEN false true "$BOT"
mutate "$P.reviewThreads.nodes[0].isResolved = null"
run
check "an unreadable resolved flag fails and writes nothing" 1 ""

new_fix
graphql OPEN false false "$BOT"
mutate "$P.isCrossRepository = null"
run
check "an unreadable fork flag fails and writes nothing" 1 ""

new_fix
graphql OPEN false false "$BOT"
mutate "$P.state = null"
run
check "an unreadable state fails and writes nothing" 1 ""

new_fix
graphql OPEN false true true:Bot:chatgpt-codex-connector
mutate "$P.labels.nodes = [{name: \"Codex-Findings\"}]"
run
check "a differently cased label counts as present and is removed by its own name" 0 "DELETE issues/7/labels/Codex-Findings"

new_fix
graphql OPEN false false "$BOT"
mutate "$P.labels.nodes = [{name: \"CODEX-FINDINGS\"}]"
run
check "a differently cased label is not added twice" 0 ""

new_fix
graphql MERGED false true "$BOT"
run
check "closed PR is left alone" 0 ""

new_fix
FORK=true graphql OPEN false false "$BOT"
run
check "fork PR is left alone, even on a manual dispatch" 0 ""

new_fix
: >"$FIX/label_error"
graphql OPEN false false "$BOT"
run
check "a failed label lookup (not a 404) fails and writes nothing" 1 ""

new_fix
: >"$FIX/label_exists"
: >"$FIX/fail_write"
graphql OPEN false false "$BOT"
run
check "failed label write fails the run" 1 ""

new_fix
graphql OPEN false false "$BOT"
PR='7;x' run
check "non-numeric PR is refused" 1 ""

new_fix
graphql OPEN false false "$BOT"
PR=007 run
check "a leading-zero PR number is refused" 1 ""

# The concurrency group's eligibility test must be the job's `if` verbatim,
# or an event the job skips could still share, and cancel, a recount.
norm() { tr -s ' \n' ' ' | sed 's/^ //; s/ $//'; }
job_if=$(awk '/^    if: >-/{on=1; next} on && /^    [a-z#]/{on=0} on' "$WF" | norm)
group_if=$(sed -n 's/.*group: "codex-findings-\${{ \(.*\) \&\& format(.pr-{0}.*/\1/p' "$WF" | norm)
if [ -n "$job_if" ] && [ "$group_if" = "($job_if)" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL - concurrency eligibility differs from the job's if:" >&2
  echo "    if:    $job_if" >&2
  echo "    group: $group_if" >&2
fi

echo "codex-findings-label: $pass passed, $fail failed"
[ "$fail" = 0 ]
