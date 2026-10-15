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
# --slurp, and records status POSTs as "state|description".
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
path="" slurp=0 post=0 state="" desc=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slurp) slurp=1 ;;
    -X) shift; [ "$1" = POST ] && post=1 ;;
    -f)
      shift
      case "$1" in
        state=*) state="${1#state=}" ;;
        description=*) desc="${1#description=}" ;;
      esac
      ;;
    repos/*) path="$1" ;;
  esac
  shift
done
if [ "$post" = 1 ]; then
  printf '%s|%s\n' "$state" "$desc" >>"$FIX/posted"
  exit 0
fi
case "$path" in
  */pulls/*/files) f=files.json ;;
  */pulls/*) f=pr.json ;;
  */issues/*/comments) f=comments.json ;;
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
  printf '{"state":"open","draft":%s,"user":{"login":"%s"},"head":{"sha":"abc123","ref":"%s"},"labels":%s}\n' \
    "$1" "$2" "$3" "$labels" >"$FIX/pr.json"
}

# files <path>...
files() {
  local out='[' sep=''
  for f in "$@"; do
    out="$out$sep{\"filename\":\"$f\"}"
    sep=','
  done
  printf '%s]\n' "$out" >"$FIX/files.json"
}

# summary <status cell>... — one review row per cell; no args = no comment
summary() {
  if [ $# -eq 0 ]; then
    echo '[{"user":{"login":"someone"},"body":"lgtm"}]' >"$FIX/comments.json"
    return
  fi
  local body rows='' cell nl=$'\n'
  for cell in "$@"; do
    rows="$rows| 📝 **Code Review** | $cell | \`69cff27\` | PR opened |$nl"
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
}

# expect <name> <state> <description fragment>
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
expect "bot review failed fails open" success "ended without completing (❌ Failed)"

setup
expect "no summary comment after the poll fails open" success "did not pick up this PR"

setup; printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"body":"<!-- codex-pull-request-review-summary -->\\n## Codex Review Summary"}]\n' >"$FIX/comments.json"
expect "summary without rows yet" pending "started"

setup; pr false jckeen feat/x codex-skip
expect "codex-skip label" success "codex-skip"

setup; pr false 'dependabot[bot]' dependabot/npm/x
expect "dependabot author" success "Dependabot"

setup; pr false app/claude claude/deps-20261014
expect "nightly dep audit branch" success "Nightly dep audit"

setup; files README.md docs/guide.md LICENSE
expect "docs-only diff" success "Docs-only"

setup; files README.md CLAUDE.md; summary "⏳ **In progress**"
expect "CLAUDE.md is not docs-only" pending "in progress"

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
