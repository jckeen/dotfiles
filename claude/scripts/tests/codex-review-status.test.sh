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
    */statuses/*) printf '%s|%s\n' "$state" "$desc" >>"$FIX/posted" ;;
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
  */pulls/*/files) f=files.json ;;
  */pulls/*/commits) f=commits.json ;;
  */pulls/*)
    # changed_files is the files fixture's length unless a case overrides it.
    jq --argjson n "$(cat "$FIX/changed_files" 2>/dev/null || jq length "$FIX/files.json")" \
      '. + {changed_files: $n}' "$FIX/pr.json"
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
  printf '{"state":"open","draft":%s,"user":{"login":"%s"},"head":{"sha":"69cff27a1b2c3d","ref":"%s"},"labels":%s}\n' \
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

# summary <status cell[@commit]>... — one review row per cell, reviewing the
# head commit unless @commit names another; no args = no summary comment
summary() {
  if [ $# -eq 0 ]; then
    echo '[{"user":{"login":"someone"},"body":"lgtm"}]' >"$FIX/comments.json"
    return
  fi
  local body rows='' cell nl=$'\n'
  local commit
  for cell in "$@"; do
    commit=69cff27
    case "$cell" in *@*) commit="${cell##*@}" cell="${cell%@*}" ;; esac
    rows="$rows| 📝 **Code Review** | $cell | \`$commit\` | PR opened |$nl"
  done
  body="<!-- codex-pull-request-review-summary -->$nl## Codex Review Summary$nl$nl| Review | Status | Commit | Review trigger |$nl| --- | --- | --- | --- |$nl$rows${nl}Codex reacts with 👀 while any review is running"
  jq -n --arg body "$body" '[{user: {login: "chatgpt-codex-connector[bot]"}, body: $body}]' >"$FIX/comments.json"
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
  echo write >"$FIX/role"
  echo '[{"author":{"login":"dependabot[bot]"}}]' >"$FIX/commits.json"
}

# expect <name> <state> <description fragment> — exactly one status posted.
expect() {
  local got
  REPO=o/r PR=1 RUN_URL=u POLL_SECONDS=0 POLL_INTERVAL=1 PATH="$TMP/bin:$PATH" \
    bash "$TMP/status.sh" >"$FIX/out" 2>&1
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

setup; summary "$done_cell" "❌ **Failed**"
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
echo '[{"author":{"login":"dependabot[bot]"}},{"author":{"login":"someone"}}]' >"$FIX/commits.json"
expect "a human commit on a Dependabot branch is reviewed" pending "in progress"

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

setup; summary "$done_cell@0dd1e55"
jq --arg m '<!-- codex-review-rerequest:69cff27a1b2c3d -->' '. + [{user: {login: "github-actions[bot]"}, body: ("@codex review\n\n" + $m)}]' \
  "$FIX/comments.json" >"$FIX/c2" && mv "$FIX/c2" "$FIX/comments.json"
expect "an earlier request for this head is not repeated" pending "re-review requested"
if [ -e "$FIX/commented" ]; then
  failed=$((failed + 1))
  echo "FAIL: re-review requested twice for one head: $(cat "$FIX/commented")"
else
  pass=$((pass + 1))
fi

setup; summary "$done_cell@0dd1e55"
jq --arg m '<!-- codex-review-rerequest:69cff27a1b2c3d -->' '. + [{user: {login: "someone"}, body: ("@codex review\n\n" + $m)}]' \
  "$FIX/comments.json" >"$FIX/c2" && mv "$FIX/c2" "$FIX/comments.json"
expect "a pasted marker does not suppress the re-review request" pending "re-review requested"
if grep -q 'codex-review-rerequest:69cff27a1b2c3d' "$FIX/commented" 2>/dev/null; then
  pass=$((pass + 1))
else
  failed=$((failed + 1))
  echo "FAIL: a marker from a non-workflow account suppressed the re-review request"
fi

setup; summary "$done_cell@0dd1e55" "⏳ **In progress**"
expect "an old completed row does not pass a running head review" pending "in progress"

setup; files README.md docs/guide.md LICENSE
expect "docs-only diff" success "Docs-only"

setup; files README.md CLAUDE.md; summary "⏳ **In progress**"
expect "CLAUDE.md is not docs-only" pending "in progress"

setup; files docs/claude.md; summary "⏳ **In progress**"
expect "instruction names match case-insensitively" pending "in progress"

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
expect "draft waits for ready" pending "Draft"

setup; printf '{"state":"closed","draft":false,"user":{"login":"jckeen"},"head":{"sha":"abc123","ref":"x"},"labels":[]}\n' >"$FIX/pr.json"
REPO=o/r PR=1 RUN_URL=u POLL_SECONDS=0 POLL_INTERVAL=1 PATH="$TMP/bin:$PATH" bash "$TMP/status.sh" >/dev/null 2>&1
if [ -e "$FIX/posted" ]; then
  failed=$((failed + 1))
  echo "FAIL: closed PR — posted a status: $(cat "$FIX/posted")"
else
  pass=$((pass + 1))
fi

echo "codex-review-status: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
