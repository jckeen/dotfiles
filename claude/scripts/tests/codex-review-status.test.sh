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
path="" slurp=0 post=0 state="" desc="" body=""
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
      printf '%s|%s\n' "$state" "$desc" >>"$FIX/posted"
      printf '%s|%s\n' "${path##*/}" "$state" >>"$FIX/posted_sha"
      ;;
    */comments) printf '%s\n' "$body" >>"$FIX/commented" ;;
    *) echo "fake gh: unexpected POST $path" >&2; exit 1 ;;
  esac
  exit 0
fi
case "$path" in
  */collaborators/*/permission)
    # gh's --jq .role_name, answered directly.
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
    prf="$FIX/pr.json"
    [ "$num" = 1 ] || prf="$FIX/pr$num.json"
    jq --argjson n "$(cat "$FIX/changed_files" 2>/dev/null || jq length "$FIX/files.json")" \
      --argjson c "$(cat "$FIX/commit_count" 2>/dev/null || jq length "$FIX/commits.json")" \
      '. + {changed_files: $n, commits: $c}' "$prf"
    exit 0
    ;;
  */issues/*/comments) f=comments.json ;;
  */issues/*/events) f=events.json ;;
  *) echo "fake gh: unexpected path $path" >&2; exit 1 ;;
esac
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

# pr <draft> <author> <ref> [label]
pr() {
  local labels='[]'
  [ -n "${4:-}" ] && labels="[{\"name\":\"$4\"}]"
  printf '{"state":"open","draft":%s,"user":{"login":"%s"},"head":{"sha":"69cff27a1b2c3d","ref":"%s","repo":{"full_name":"o/r"}},"labels":%s}\n' \
    "$1" "$2" "$3" "$labels" >"$FIX/pr.json"
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
  REPO=o/r PR=1 RUN_URL=u POLL_SECONDS=0 POLL_INTERVAL=1 PATH="$TMP/bin:$PATH" \
    ACTION="$CASE_ACTION" EVENT_HEAD="$CASE_EVENT_HEAD" BEFORE="$CASE_BEFORE" \
    bash "$TMP/status.sh" >"$FIX/out" 2>&1
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
  CASE_ACTION="" CASE_EVENT_HEAD="" CASE_BEFORE=""
  echo write >"$FIX/role"
  echo '[{"sha":"69cff27a1b2c3d","author":{"login":"dependabot[bot]"}}]' >"$FIX/commits.json"
}

# expect <name> <state> <description fragment> — exactly one status posted.
expect() {
  local got
  run_status
  got="$(cat "$FIX/posted" 2>/dev/null || true)"
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
expect "a docs-only PR sharing its head holds" pending "also the head of #2"

setup; summary "$done_cell"; open_prs '1:69cff27a1b2c3d' '2:69cff27a1b2c3d'
expect "a reviewed PR sharing its head holds" pending "also the head of #2"

setup; pr false jckeen feat/x codex-skip; labeled_by jckeen admin; open_prs '1:69cff27a1b2c3d' '2:69cff27a1b2c3d'
expect "codex-skip does not pass a shared head" pending "also the head of #2"

setup; files README.md; open_prs '1:69cff27a1b2c3d' '2:69cff27a1b2c3d:true'
expect "a draft sibling does not count" success "Docs-only"

setup; files README.md; open_prs '1:69cff27a1b2c3d' '2:ffff0001'
expect "a PR that moved past this commit does not count" success "Docs-only"

setup; summary "$done_cell"; open_prs '1:69cff27a1b2c3d' '2:69cff27a1b2c3d:false:fork/r'
expect "a fork PR at the same head does not hold a same-repo PR" success "Codex review completed"

setup; summary "$done_cell"; open_prs '1:69cff27a1b2c3d:false:fork/r' '2:69cff27a1b2c3d'
jq '.head.repo.full_name = "fork/r"' "$FIX/pr.json" >"$FIX/p2" && mv "$FIX/p2" "$FIX/pr.json"
run_status
if [ -e "$FIX/posted" ]; then
  failed=$((failed + 1))
  echo "FAIL: a fork PR sharing a same-repo PR's head posted: $(cat "$FIX/posted")"
else
  pass=$((pass + 1))
fi

# PR 1 closed; PR 2 is left as the sole owner of the head and is evaluated.
setup; summary "$done_cell"; open_prs '2:69cff27a1b2c3d'
cp "$FIX/pr.json" "$FIX/pr2.json"
CASE_ACTION=closed CASE_EVENT_HEAD=69cff27a1b2c3d
expect "closing a sibling re-evaluates the survivor" success "Codex review completed"

# PR 1 pushed past 0dd1e55; PR 2 still has it as head and is re-evaluated too.
setup; summary "$done_cell" "$done_cell@0dd1e55"; open_prs '1:69cff27a1b2c3d' '2:0dd1e55aaaa'
jq '.head.sha = "0dd1e55aaaa"' "$FIX/pr.json" >"$FIX/pr2.json"
CASE_ACTION=synchronize CASE_BEFORE=0dd1e55aaaa
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

echo "codex-review-status: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
