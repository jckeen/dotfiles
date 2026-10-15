#!/usr/bin/env bash
# codex-review-status.test.sh — fixture tests for the status script embedded in
# .github/workflows/codex-review.yml (no framework). Extracts the script
# between its `>>> codex-review-status` / `<<< codex-review-status` markers,
# runs it against a fake `gh` that serves fixture JSON, and asserts the status
# it posts. Run directly; exit 1 on any failure.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$SCRIPT_DIR/../../../.github/workflows/codex-review.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The run block is indented ten spaces in the workflow; strip exactly that.
sed -n '/# >>> codex-review-status/,/# <<< codex-review-status/p' "$WORKFLOW" |
  sed -E 's/^ {10}//' >"$TMP/status.sh"
if ! grep -q 'post success "Codex review completed"' "$TMP/status.sh"; then
  echo "FAIL: could not extract the status script from $WORKFLOW"
  exit 1
fi

# Fake gh: maps the repos/... path to a fixture file, wraps it in an array for
# --slurp, records status POSTs as "state|description" in $FIX/posted and
# comment POSTs (their body) in $FIX/commented.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
path="" slurp=0 post=0 state="" desc="" body="" include=0
if [ "$*" = "api -i rate_limit" ]; then
  [ -e "$FIX/fail_clock" ] && exit 1
  printf 'HTTP/2.0 200 OK\r\nDate: %s\r\n\r\n{}\n' "$(date -u '+%a, %d %b %Y %H:%M:%S GMT')"
  exit 0
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --slurp) slurp=1 ;;
    -X) shift; [ "$1" = POST ] && post=1 ;;
    -f)
      shift
      case "$1" in
        state=*) state="${1#state=}" ;;
        description=*) desc="${1#description=}" ;;
        body=*) body="${1#body=}" ;;
      esac
      ;;
    repos/*) path="$1" ;;
  esac
  shift
done
if [ "$post" = 1 ]; then
  case "$path" in
    */statuses/*)
      [ -e "$FIX/fail_status" ] && exit 1
      # race: an invalidation lands between the writer's check and its POST.
      if [ "$state" = success ] && [ -e "$FIX/race" ]; then
        rm "$FIX/race"
        jq -nc --arg sha "${path##*/}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{id: 9000, sha: $sha, context: "codex-review", state: "pending", description: "Re-evaluating the Codex review state", created_at: $at}' >>"$FIX/status_store"
      fi
      id=$(( $(wc -l <"$FIX/status_store" 2>/dev/null || echo 0) + 1 ))
      # posted: statuses on the main fixture head; posted_sha: every status.
      [ "${path##*/}" = 69cff27a1b2c3d ] && printf '%s|%s\n' "$state" "$desc" >>"$FIX/posted"
      printf '%s|%s\n' "${path##*/}" "$state" >>"$FIX/posted_sha"
      jq -nc --argjson id "$id" --arg sha "${path##*/}" --arg s "$state" --arg d "$desc" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id: $id, sha: $sha, context: "codex-review", state: $s, description: $d, created_at: $at}' >>"$FIX/status_store"
      # gh's --jq .id, answered directly.
      echo "$id"
      ;;
    */comments) printf '%s\n' "$body" >>"$FIX/commented" ;;
    *) echo "fake gh: unexpected POST $path" >&2; exit 1 ;;
  esac
  exit 0
fi
case "$path" in
  */commits/*/statuses*)
    # fail_verify: every statuses read after a success POST fails.
    [ -e "$FIX/fail_verify" ] && [ -e "$FIX/status_store" ] && grep -q '"state":"success"' "$FIX/status_store" && exit 1
    # Newest first, as the API lists them.
    sha="${path#*/commits/}"
    sha="${sha%%/*}"
    if [ -e "$FIX/status_store" ]; then
      jq -s --arg sha "$sha" '[.[] | select(.sha == $sha)] | reverse' "$FIX/status_store"
    else
      echo '[]'
    fi
    exit 0
    ;;
  */collaborators/*/permission)
    # gh's --jq .role_name, answered directly.
    [ -e "$FIX/fail_role" ] && exit 1
    cat "$FIX/role"
    exit 0
    ;;
  */pulls\?*) f=open.json ;;
  */pulls/*/files) f=files.json ;;
  */pulls/*/commits) f=commits.json ;;
  */pulls/*)
    # PR 1 is pr.json, PR N is prN.json. changed_files is the files
    # fixture's length unless a case overrides it.
    num="${path##*/}"
    [ -e "$FIX/fail_pr" ] || [ -e "$FIX/fail_pr$num" ] && exit 1
    prf="$FIX/pr.json"
    if [ "$num" != 1 ]; then
      prf="$FIX/pr$num.json"
      # A sibling without its own fixture is pr.json with its open-list entry.
      [ -e "$prf" ] || jq --argjson e "$(jq --argjson n "$num" '.[] | select(.number == $n)' "$FIX/open.json")" \
        '.head = (.head + $e.head) | .draft = $e.draft' "$FIX/pr.json" >"$prf"
    fi
    jq --argjson n "$(cat "$FIX/changed_files" 2>/dev/null || jq length "$FIX/files.json")" \
      --argjson c "$(cat "$FIX/commit_count" 2>/dev/null || jq length "$FIX/commits.json")" \
      '. + {changed_files: $n, commits: $c}' "$prf"
    exit 0
    ;;
  */issues/*/comments) f=comments.json ;;
  */issues/*/events) f=events.json ;;
  *) echo "fake gh: unexpected path $path" >&2; exit 1 ;;
esac
# fail_<fixture> makes that read fail; fail_once_<fixture> only the first time.
[ -e "$FIX/fail_$f" ] && exit 1
if [ -e "$FIX/fail_once_$f" ]; then
  rm "$FIX/fail_once_$f"
  exit 1
fi
if [ "$slurp" = 1 ]; then
  printf '['; cat "$FIX/$f"; printf ']'
else
  cat "$FIX/$f"
fi
FAKE
chmod +x "$TMP/bin/gh"

pass=0
failed=0
n=0
# Fixture PRs opened an hour ago, well past the bot's pickup window.
OPENED="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"

# pr <draft> <author> <ref> [label]
pr() {
  local labels='[]'
  [ -n "${4:-}" ] && labels="[{\"name\":\"$4\"}]"
  printf '{"state":"open","draft":%s,"created_at":"%s","user":{"login":"%s"},"head":{"sha":"69cff27a1b2c3d","ref":"%s","repo":{"full_name":"o/r"}},"labels":%s}\n' \
    "$1" "$OPENED" "$2" "$3" "$labels" >"$FIX/pr.json"
}

# files <path | old=>new>...
files() {
  local out='[' sep='' f
  for f in "$@"; do
    case "$f" in
      *'=>'*) out="$out$sep{\"filename\":\"${f#*=>}\",\"previous_filename\":\"${f%%=>*}\"}" ;;
      *) out="$out$sep{\"filename\":\"$f\"}" ;;
    esac
    sep=','
  done
  printf '%s]\n' "$out" >"$FIX/files.json"
}

# labeled_by <login> <role> — codex-skip applied by <login>, who holds <role>
labeled_by() {
  printf '[{"event":"labeled","label":{"name":"codex-skip"},"actor":{"login":"%s"}}]\n' "$1" >"$FIX/events.json"
  echo "$2" >"$FIX/role"
}

# summary <[type::]status cell[@commit]>... — one review row per cell, a Code
# Review of the head commit unless type:: or @commit says otherwise; no args =
# no summary comment
summary() {
  if [ $# -eq 0 ]; then
    echo '[{"user":{"login":"someone"},"body":"lgtm"}]' >"$FIX/comments.json"
    return
  fi
  local body rows='' cell nl=$'\n'
  local commit type
  for cell in "$@"; do
    commit=69cff27 type='📝 **Code Review**'
    case "$cell" in *::*) type="${cell%%::*}" cell="${cell#*::}" ;; esac
    case "$cell" in *@*) commit="${cell##*@}" cell="${cell%@*}" ;; esac
    rows="$rows| $type | $cell | \`$commit\` | PR opened |$nl"
  done
  body="<!-- codex-pull-request-review-summary -->$nl## Codex Review Summary$nl$nl| Review | Status | Commit | Review trigger |$nl| --- | --- | --- | --- |$nl$rows${nl}Codex reacts with 👀 while any review is running"
  jq -n --arg body "$body" '[{user: {login: "chatgpt-codex-connector[bot]"}, body: $body}]' >"$FIX/comments.json"
}

# open_prs <number:headsha[:draft[:repo]]>... — the open-PR list the
# sole-owner rule reads
open_prs() {
  local out='[' sep='' e num sha draft repo
  for e in "$@"; do
    IFS=: read -r num sha draft repo <<<"$e"
    out="$out$sep{\"number\":$num,\"head\":{\"sha\":\"$sha\",\"repo\":{\"full_name\":\"${repo:-o/r}\"}},\"draft\":${draft:-false}}"
    sep=','
  done
  printf '%s]\n' "$out" >"$FIX/open.json"
}

# request_comment <created_at> [marker suffix] [login] — a re-review request
request_comment() {
  jq --arg m "<!-- codex-review-rerequest:69cff27a1b2c3d${2:-} -->" --arg at "$1" --arg who "${3:-github-actions[bot]}" \
    '. + [{user: {login: $who}, created_at: $at, body: ("@codex review\n\n" + $m)}]' \
    "$FIX/comments.json" >"$FIX/c2" && mv "$FIX/c2" "$FIX/comments.json"
}

run_status() {
  status_rc=0
  RETRY_SECONDS=0 SETTLE_SECONDS="${SETTLE_PAD:-0}" EVENT_PR="${CASE_EVENT_PR:-1}" EVENT_HEAD="${CASE_EVENT_HEAD:-}" EVENT_HEAD_REPO="${CASE_EVENT_HEAD_REPO:-}" \
    REPO=o/r RUN_URL=u POLL_SECONDS="${CASE_POLL:-180}" PATH="$TMP/bin:$PATH" \
    bash "$TMP/status.sh" >"$FIX/out" 2>&1 || status_rc=$?
}

# never_passes <name> — the run must exit non-zero and post no success
never_passes() {
  run_status
  if [ "$status_rc" != 0 ] && ! grep -q '^success|' "$FIX/posted" 2>/dev/null; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $1 — exit $status_rc, posted: $(cat "$FIX/posted" 2>/dev/null)"
    sed 's/^/    /' "$FIX/out"
  fi
}

setup() {
  n=$((n + 1))
  FIX="$TMP/case$n"
  mkdir -p "$FIX"
  export FIX
  pr false jckeen feat/x
  files src/app.ts
  summary
  echo '[]' >"$FIX/events.json"
  open_prs '1:69cff27a1b2c3d'
  SETTLE_PAD="" CASE_POLL="" CASE_EVENT_PR="" CASE_EVENT_HEAD="" CASE_EVENT_HEAD_REPO=""
  echo write >"$FIX/role"
  echo '[{"sha":"69cff27a1b2c3d","author":{"login":"dependabot[bot]"}}]' >"$FIX/commits.json"
}

# expect <name> <state> <description fragment> — exactly one distinct status
# posted on the fixture head (PRs sharing it post the same one).
expect() {
  local got
  run_status
  got="$(sort -u "$FIX/posted" 2>/dev/null || true)"
  if [ "$(wc -l <<<"$got")" = 1 ] && [[ "$got" == "$2|"*"$3"* ]]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $1 — expected $2 containing '$3', posted: '${got}'"
    sed 's/^/    /' "$FIX/out"
  fi
}

done_cell='✅ **Completed** <relative-time datetime="2026-10-05T15:33:42Z">2026-10-05T15:33:42Z</relative-time>'

setup; summary "$done_cell"
expect "every row completed" success "Codex review completed"

setup; summary "$done_cell" "$done_cell"
expect "code and security rows completed" success "Codex review completed"

setup; summary "$done_cell" "⏳ **In progress**"
expect "one row still running" pending "in progress"

setup; summary "⏳ **Queued**"
expect "unknown non-terminal wording holds" pending "in progress"

setup; summary "❌ **Failed**"
expect "a failed bot review holds" pending "ended without completing (❌ Failed)"

setup
expect "no summary comment after the poll fails open" success "did not pick up this PR"

setup; printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"body":"<!-- codex-pull-request-review-summary -->\\n## Codex Review Summary"}]\n' >"$FIX/comments.json"
expect "summary without rows yet" pending "started"

setup; pr false jckeen feat/x codex-skip; labeled_by jckeen admin
expect "codex-skip applied by an admin" success "codex-skip"

setup; pr false jckeen feat/x codex-skip; labeled_by jckeen maintain
expect "codex-skip applied by a maintainer" success "codex-skip"

setup; pr false someone feat/x codex-skip; labeled_by someone write; summary "⏳ **In progress**"
expect "codex-skip applied by a writer is ignored" pending "in progress"

setup; pr false someone feat/x codex-skip; summary "⏳ **In progress**"
expect "codex-skip with no labeled event is ignored" pending "in progress"

setup; pr false 'dependabot[bot]' dependabot/npm/x
expect "dependabot author" success "Dependabot"

setup; pr false 'dependabot[bot]' dependabot/npm/x; summary "⏳ **In progress**"
echo '[{"sha":"1","author":{"login":"dependabot[bot]"}},{"sha":"69cff27a1b2c3d","author":{"login":"someone"}}]' >"$FIX/commits.json"
expect "a human commit on a Dependabot branch is reviewed" pending "in progress"

setup; pr false 'dependabot[bot]' dependabot/npm/x; summary "⏳ **In progress**"
echo 251 >"$FIX/commit_count"
expect "a truncated Dependabot commit list is reviewed" pending "in progress"

setup; pr false app/claude claude/deps-20261014; summary "⏳ **In progress**"
expect "a deps-looking branch name skips nothing" pending "in progress"

setup; summary "$done_cell@0dd1e55"
expect "a completed review of an older commit holds the head" pending "re-review requested"
if [ "$(wc -l <"$FIX/posted")" = 1 ] &&
  grep -q '^@codex review' "$FIX/commented" && grep -q 'codex-review-rerequest:69cff27a1b2c3d' "$FIX/commented"; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: stale review — expected a held status and one @codex review request; posted: $(cat "$FIX/posted"); commented: $(cat "$FIX/commented" 2>/dev/null)"
fi

setup; summary "$done_cell@0dd1e55"; request_comment 2026-10-06T09:00:00Z
expect "an earlier request for this head is not repeated" pending "re-review requested"
if [ -e "$FIX/commented" ]; then
  failed=$((failed + 1))
  echo "FAIL: re-review requested twice for one head: $(cat "$FIX/commented")"
else
  pass=$((pass + 1))
fi

setup; summary "$done_cell@0dd1e55"; request_comment 2026-10-06T09:00:00Z "" someone
expect "a pasted marker does not suppress the re-review request" pending "re-review requested"
if grep -q 'codex-review-rerequest:69cff27a1b2c3d' "$FIX/commented" 2>/dev/null; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: a marker from a non-workflow account suppressed the re-review request"
fi

setup; summary "❌ **Failed**" "$done_cell"
expect "a completed retry supersedes a failed attempt" success "Codex review completed"

setup; summary "$done_cell" "❌ **Failed**"
expect "a completed run passes in either row order" success "Codex review completed"

setup; summary "$done_cell" "🔒 **Security Review**::❌ **Failed**"
expect "a failed security review holds a completed code review" pending "ended without completing (❌ Failed)"

setup; summary "$done_cell" "🔒 **Security Review**::$done_cell"
expect "both review types completed" success "Codex review completed"

setup; summary "$done_cell"
jq '.head.repo.full_name = "fork/r"' "$FIX/pr.json" >"$FIX/p2" && mv "$FIX/p2" "$FIX/pr.json"
expect "a fork PR holds even with a completed review" pending "Fork PR"

setup; summary
jq '.head.repo = null' "$FIX/pr.json" >"$FIX/p2" && mv "$FIX/p2" "$FIX/pr.json"
expect "a deleted fork holds instead of failing open" pending "Fork PR"

setup; pr false someone feat/x codex-skip; labeled_by jckeen admin
jq '.head.repo.full_name = "fork/r"' "$FIX/pr.json" >"$FIX/p2" && mv "$FIX/p2" "$FIX/pr.json"
expect "a maintainer's codex-skip passes a fork PR" success "codex-skip"

setup; files README.md; open_prs '1:69cff27a1b2c3d' '2:69cff27a1b2c3d'
expect "a docs-only PR sharing its head holds" pending "Head commit of open PRs #1, #2;"

setup; summary "$done_cell"; open_prs '1:69cff27a1b2c3d' '2:69cff27a1b2c3d'
expect "a reviewed PR sharing its head holds" pending "Head commit of open PRs #1, #2;"

setup; pr false jckeen feat/x codex-skip; labeled_by jckeen admin; open_prs '1:69cff27a1b2c3d' '2:69cff27a1b2c3d'
expect "codex-skip does not pass a shared head" pending "Head commit of open PRs #1, #2;"

setup; files README.md; open_prs '1:69cff27a1b2c3d' '2:69cff27a1b2c3d:true'
expect "a draft sibling does not count" success "Docs-only"

setup; files README.md; open_prs '1:69cff27a1b2c3d' '2:ffff0001'
expect "a PR that moved past this commit does not count" success "Docs-only"

setup; summary "$done_cell"; open_prs '1:69cff27a1b2c3d' '2:69cff27a1b2c3d:false:fork/r'
expect "a fork PR at the same head does not hold a same-repo PR" success "Codex review completed"

setup; summary "$done_cell"; open_prs '1:69cff27a1b2c3d:false:fork/r' '2:69cff27a1b2c3d'
jq '.head.repo.full_name = "fork/r"' "$FIX/pr.json" >"$FIX/p2" && mv "$FIX/p2" "$FIX/pr.json"
run_status
# Only PR 2 (same-repo, reviewed, sole same-repo owner) posts; the fork posts nothing.
if [ "$(cat "$FIX/posted" 2>/dev/null)" = "success|Codex review completed" ]; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: a fork PR sharing a same-repo PR's head must post nothing — posted: $(cat "$FIX/posted" 2>/dev/null)"
fi

setup; summary "$done_cell"; touch "$FIX/fail_events.json"
never_passes "a failed events read never passes"

setup; summary "$done_cell"; touch "$FIX/fail_open.json"
never_passes "a failed open-PR read never passes"

setup; summary "$done_cell"; touch "$FIX/fail_status"
run_status
if [ "$status_rc" != 0 ]; then pass=$((pass + 1)); else
  failed=$((failed + 1)); echo "FAIL: a failed status POST exited 0"; fi

setup; summary "$done_cell"
run_status; run_status
if [ "$(wc -l <"$FIX/posted")" = 1 ]; then pass=$((pass + 1)); else
  failed=$((failed + 1)); echo "FAIL: an unchanged status is written again: $(cat "$FIX/posted")"; fi

# Passed, then the PR is retargeted and the next evaluation fails: revoke.
setup; summary "$done_cell"
run_status
retarget_events='[{"event":"base_ref_changed","created_at":"2026-10-06T09:00:00Z","actor":{"login":"jckeen"}}]'
echo "$retarget_events" >"$FIX/events.json"; touch "$FIX/fail_events.json"
run_status
if [ "$status_rc" != 0 ] && [ "$(tail -n 1 "$FIX/posted")" = "pending|codex-review could not evaluate #1; re-run the workflow" ]; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: a failed evaluation must revoke an earlier success — exit $status_rc, posted: $(cat "$FIX/posted")"
fi

# A failure before the PR read still revokes, from the open-PR snapshot.
setup; summary "$done_cell"
run_status; touch "$FIX/fail_pr"
run_status
if [ "$(tail -n 1 "$FIX/posted")" = "pending|codex-review could not evaluate #1; re-run the workflow" ]; then
  pass=$((pass + 1))
else
  failed=$((failed + 1)); echo "FAIL: a failed PR read must revoke from the snapshot: $(cat "$FIX/posted")"
fi

# A fork PR at a reviewed same-repo PR's head fails to evaluate: no revoke.
setup; summary "$done_cell"; open_prs '1:69cff27a1b2c3d' '2:69cff27a1b2c3d:false:fork/r'
jq '.head.repo.full_name = "fork/r"' "$FIX/pr.json" >"$FIX/pr2.json"
run_status; touch "$FIX/fail_pr2"
run_status
if [ "$(tail -n 1 "$FIX/posted")" = "success|Codex review completed" ]; then pass=$((pass + 1)); else
  failed=$((failed + 1)); echo "FAIL: a failed fork evaluation revoked a shared head: $(cat "$FIX/posted")"; fi

# Passed, then the PR list cannot be read on its retarget event: revoke the
# triggering PR's head.
setup; summary "$done_cell"
run_status; touch "$FIX/fail_open.json"
CASE_EVENT_HEAD=69cff27a1b2c3d CASE_EVENT_HEAD_REPO=o/r
run_status
if [ "$status_rc" != 0 ] && [ "$(tail -n 1 "$FIX/posted")" = "pending|codex-review could not evaluate #1; re-run the workflow" ]; then
  pass=$((pass + 1))
else
  failed=$((failed + 1)); echo "FAIL: a failed PR-list read must revoke the event PR's head — exit $status_rc, posted: $(cat "$FIX/posted")"
fi

# A status newer than the pass (an invalidation it did not see) is never
# overwritten.
setup; summary "$done_cell"
jq -nc --arg at "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
  '{sha: "69cff27a1b2c3d", context: "codex-review", state: "pending", description: "Re-evaluating the Codex review state", created_at: $at}' >"$FIX/status_store"
run_status
if [ ! -e "$FIX/posted" ]; then pass=$((pass + 1)); else
  failed=$((failed + 1)); echo "FAIL: overwrote a status newer than the pass: $(cat "$FIX/posted")"; fi

# An invalidation lands between the writer's check and its success POST: the
# writer hands the head back to pending.
setup; summary "$done_cell"
run_status; rm -f "$FIX/posted" "$FIX/status_store"
# PASS_START is the next second, so the race entry must be from then on.
touch "$FIX/race"
SETTLE_PAD=1
run_status
if [ "$(tail -n 1 "$FIX/posted")" = "pending|Re-evaluating the Codex review state" ]; then pass=$((pass + 1)); else
  failed=$((failed + 1)); echo "FAIL: a newer status during the pass must revert success: $(cat "$FIX/posted")"; sed 's/^/    /' "$FIX/out"; fi

# The post-success re-read fails three times: fail closed, back to pending,
# and the run fails so it can be re-run.
setup; summary "$done_cell"; touch "$FIX/fail_verify"
run_status
if [ "$status_rc" != 0 ] && [ "$(tail -n 1 "$FIX/posted")" = "pending|codex-review could not evaluate #1; re-run the workflow" ]; then pass=$((pass + 1)); else
  failed=$((failed + 1)); echo "FAIL: a failed post-success re-read must revert to pending and fail the run — exit $status_rc, posted: $(cat "$FIX/posted")"; sed 's/^/    /' "$FIX/out"; fi

# Forks are evaluated after every same-repository PR, whatever their numbers.
setup; summary "$done_cell"; open_prs '1:ffff0001:false:fork/r' '2:69cff27a1b2c3d'
jq '.head.sha = "ffff0001" | .head.repo.full_name = "fork/r"' "$FIX/pr.json" >"$FIX/p1" && mv "$FIX/p1" "$FIX/pr.json"
jq '.head.sha = "69cff27a1b2c3d" | .head.repo.full_name = "o/r"' "$FIX/pr.json" >"$FIX/pr2.json"
run_status
if [ "$(cut -d'|' -f1 "$FIX/posted_sha" | paste -sd' ')" = "69cff27a1b2c3d ffff0001" ]; then pass=$((pass + 1)); else
  failed=$((failed + 1)); echo "FAIL: same-repo PRs must be evaluated before forks: $(cat "$FIX/posted_sha")"; fi

# An older status is replaced as usual.
setup; summary "$done_cell"
jq -nc --arg at "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
  '{sha: "69cff27a1b2c3d", context: "codex-review", state: "pending", description: "Re-evaluating the Codex review state", created_at: $at}' >"$FIX/status_store"
expect "a status older than the pass is replaced" success "Codex review completed"

# GitHub's clock cannot be read: revoke the event PR's head and fail.
setup; summary "$done_cell"
run_status; touch "$FIX/fail_clock"
CASE_EVENT_HEAD=69cff27a1b2c3d CASE_EVENT_HEAD_REPO=o/r
run_status
if [ "$status_rc" != 0 ] && [ "$(tail -n 1 "$FIX/posted")" = "pending|codex-review could not evaluate #1; re-run the workflow" ]; then
  pass=$((pass + 1))
else
  failed=$((failed + 1)); echo "FAIL: a failed clock read must revoke — exit $status_rc, posted: $(cat "$FIX/posted")"
fi

# One failed PR-list read is retried, not treated as a failure.
setup; summary "$done_cell"; touch "$FIX/fail_once_open.json"
expect "a transient PR-list failure is retried" success "Codex review completed"

# Same, on a comment event (no head in the payload): read the PR for it.
setup; summary "$done_cell"
run_status; touch "$FIX/fail_open.json"
run_status
if [ "$(tail -n 1 "$FIX/posted")" = "pending|codex-review could not evaluate #1; re-run the workflow" ]; then pass=$((pass + 1)); else
  failed=$((failed + 1)); echo "FAIL: a comment-event list failure must revoke via the PR read: $(cat "$FIX/posted")"; fi

# Opened just now with no summary yet: pending, then decided once the pickup
# window closes.
setup; jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.created_at = $at' "$FIX/pr.json" >"$FIX/p2" && mv "$FIX/p2" "$FIX/pr.json"
CASE_POLL=2
run_status
if [ "$(paste -sd' ' "$FIX/posted" 2>/dev/null)" = "pending|Waiting for Codex to pick up this PR success|Codex did not pick up this PR within 2s; not blocking" ]; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: pickup window — posted: $(cat "$FIX/posted" 2>/dev/null)"
  sed 's/^/    /' "$FIX/out"
fi

setup; summary "$done_cell" "$done_cell@0dd1e55"; open_prs '1:69cff27a1b2c3d' '2:0dd1e55aaaa'
run_status
if [ "$(sort "$FIX/posted_sha" | paste -sd' ')" = "0dd1e55aaaa|success 69cff27a1b2c3d|success" ]; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: every open PR is evaluated on every run — posted: $(cat "$FIX/posted_sha" 2>/dev/null)"
fi

# PR 1 converted to draft; PR 2 is left as the sole owner and is evaluated.
setup; summary "$done_cell"; open_prs '2:69cff27a1b2c3d'
cp "$FIX/pr.json" "$FIX/pr2.json"
expect "a draft conversion re-evaluates the survivor" success "Codex review completed"

# PR 1 closed; PR 2 is left as the sole owner of the head and is evaluated.
setup; summary "$done_cell"; open_prs '2:69cff27a1b2c3d'
cp "$FIX/pr.json" "$FIX/pr2.json"
expect "closing a sibling re-evaluates the survivor" success "Codex review completed"

# PR 1 pushed past 0dd1e55; PR 2 still has it as head and is re-evaluated too.
setup; summary "$done_cell" "$done_cell@0dd1e55"; open_prs '1:69cff27a1b2c3d' '2:0dd1e55aaaa'
jq '.head.sha = "0dd1e55aaaa"' "$FIX/pr.json" >"$FIX/pr2.json"
run_status
if [ "$(sort "$FIX/posted_sha" 2>/dev/null | paste -sd' ')" = "0dd1e55aaaa|success 69cff27a1b2c3d|success" ]; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: a push re-evaluates the PR left holding the old head — posted: $(cat "$FIX/posted_sha" 2>/dev/null)"
  sed 's/^/    /' "$FIX/out"
fi

setup; files claude/AgentPack.md; summary "⏳ **In progress**"
expect "AgentPack.md is an instruction source, not docs" pending "in progress"

setup; files docs/FABLE.md; summary "⏳ **In progress**"
expect "a FABLE.md instruction file is not docs-only" pending "in progress"

setup; summary "$done_cell@0dd1e55" "⏳ **In progress**"
expect "an old completed row does not pass a running head review" pending "in progress"

setup; files README.md docs/guide.md LICENSE
expect "docs-only diff" success "Docs-only"

setup; files README.md CLAUDE.md; summary "⏳ **In progress**"
expect "CLAUDE.md is not docs-only" pending "in progress"

setup; files docs/claude.md; summary "⏳ **In progress**"
expect "instruction names match case-insensitively" pending "in progress"

setup; files docs/x.md .gemini/commands/check.md; summary "⏳ **In progress**"
expect "a .gemini command is not docs-only" pending "in progress"

setup; files .agents/example/guide.md; summary "⏳ **In progress**"
expect "an .agents guide is not docs-only" pending "in progress"

setup; files requirements.txt; summary "⏳ **In progress**"
expect "a .txt manifest is not docs-only" pending "in progress"

setup; files docs/page.mdx; summary "⏳ **In progress**"
expect "an .mdx component is not docs-only" pending "in progress"

setup; files 'scripts/run.sh=>notes.md'; summary "⏳ **In progress**"
expect "renaming code to .md is judged on the old path too" pending "in progress"

setup; files README.md; echo 3001 >"$FIX/changed_files"; summary "⏳ **In progress**"
expect "a truncated file list is never docs-only" pending "in progress"

setup; files docs/x.md .claude/skills/foo/SKILL.md; summary "⏳ **In progress**"
expect "a skill file is not docs-only" pending "in progress"

setup; files README.md .github/workflows/ci.yml; summary "⏳ **In progress**"
expect "a workflow file is not docs-only" pending "in progress"

setup; pr true jckeen feat/x
run_status
if [ -e "$FIX/posted" ]; then
  failed=$((failed + 1))
  echo "FAIL: a draft posted a status (it would land on any PR sharing the head): $(cat "$FIX/posted")"
else
  pass=$((pass + 1))
fi

# done_cell finished at 2026-10-05T15:33:42Z; the base changed after it.
retarget() {
  echo '[{"event":"base_ref_changed","created_at":"2026-10-06T09:00:00Z","actor":{"login":"jckeen"}}]' >"$FIX/events.json"
}
late_cell='✅ **Completed** <relative-time datetime="2026-10-06T10:00:00.123456Z">2026-10-06T10:00:00Z</relative-time>'

setup; summary "$done_cell"; retarget
expect "a review from before a retarget does not count" pending "re-review requested"
if grep -q 'codex-review-rerequest:69cff27a1b2c3d:2026-10-06T09:00:00 -->' "$FIX/commented" 2>/dev/null; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: retarget — expected a re-review request keyed on the base change: $(cat "$FIX/commented" 2>/dev/null)"
fi

setup; summary "⏳ **In progress**"; retarget
expect "a review running across a retarget waits, then re-requests" pending "once it finishes"
if [ -e "$FIX/commented" ]; then
  failed=$((failed + 1))
  echo "FAIL: requested a re-review while a review was still running"
else
  pass=$((pass + 1))
fi

setup; summary "$late_cell"; retarget; request_comment 2026-10-06T09:30:00Z :2026-10-06T09:00:00
expect "a run completing after the request counts" success "Codex review completed"

# GitHub's own retarget (old base merged and deleted) counts as a base change.
setup; summary "$done_cell"
echo '[{"event":"automatic_base_change_succeeded","created_at":"2026-10-06T09:00:00Z","actor":{"login":"jckeen"}}]' >"$FIX/events.json"
expect "an automatic retarget invalidates the earlier review" pending "re-review requested"

# A failed Dependabot commit-list read fails the run; it never falls through.
setup; pr false 'dependabot[bot]' dependabot/npm/x; summary; touch "$FIX/fail_commits.json"
never_passes "a failed Dependabot commit-list read never passes"

# A failed permission lookup for codex-skip fails the run toward pending.
setup; pr false jckeen feat/x codex-skip; labeled_by jckeen admin; touch "$FIX/fail_role"
never_passes "a failed codex-skip permission lookup never passes"

# After a retarget, a completed row with no finish time is no evidence.
setup; summary "✅ **Completed**"; retarget; request_comment 2026-10-06T09:30:00Z :2026-10-06T09:00:00
expect "a completed row without a finish time does not count after a retarget" pending "re-review requested"

# Finished within the request's own second: it may have preceded it.
setup; summary "✅ **Completed** <relative-time datetime=\"2026-10-06T09:20:00.123456Z\">x</relative-time>"; retarget
request_comment 2026-10-06T09:20:00Z :2026-10-06T09:00:00
expect "a run finishing in the request's second does not count" pending "re-review requested"

# The run that straddled the retarget finished before the request was made.
setup; summary "✅ **Completed** <relative-time datetime=\"2026-10-06T09:10:00Z\">x</relative-time>"; retarget
request_comment 2026-10-06T09:20:00Z :2026-10-06T09:00:00
expect "a run finishing before the request does not count" pending "re-review requested"
if [ -e "$FIX/commented" ]; then
  failed=$((failed + 1))
  echo "FAIL: re-requested although a request for this base change exists"
else
  pass=$((pass + 1))
fi

setup; printf '{"state":"closed","draft":false,"user":{"login":"jckeen"},"head":{"sha":"abc123","ref":"x","repo":{"full_name":"o/r"}},"labels":[]}\n' >"$FIX/pr.json"
run_status
if [ -e "$FIX/posted" ]; then
  failed=$((failed + 1))
  echo "FAIL: closed PR — posted a status: $(cat "$FIX/posted")"
else
  pass=$((pass + 1))
fi

# Ordering: every invalidation is followed by an evaluation that started later.
if sed -n '/^  evaluate:/,/^    runs-on:/p' "$WORKFLOW" | grep -q '^    needs: invalidate$' &&
  sed -n '/^  evaluate:/,/^    runs-on:/p' "$WORKFLOW" | grep -q '^      always() && ($'; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: evaluate must need invalidate and run under always()"
fi

echo "codex-review-status: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
