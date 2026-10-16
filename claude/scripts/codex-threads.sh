#!/usr/bin/env bash
# codex-threads.sh — list and close out the GitHub Codex bot's
# (chatgpt-codex-connector[bot]) unresolved PR review threads.
#
# The `codex-review` ruleset (fleet-codex-review.sh) requires every review
# thread to be resolved before merge, so an agent shipping a PR has to answer
# each bot thread: fix it and say where, or say why it is moot. This is the
# tool for both halves. It never resolves a thread without posting a reply
# first, so the reason stays on the PR next to the finding.
#
# Usage:
#   codex-threads.sh list [--repo owner/name] (--pr N | --merged-since YYYY-MM-DD)
#       One TSV line per unresolved bot thread:
#       pr  thread-id  path:line  priority  outdated  title  url
#   codex-threads.sh resolve [--repo owner/name] --thread ID --reply TEXT
#       Replies on the thread, then resolves it. Refuses a thread the bot did
#       not open, and does nothing to one that is already resolved. After the
#       PR's last bot thread is resolved, starts the codex-findings workflow so
#       it removes the PR's `codex-findings` label (GitHub has no workflow
#       trigger for a resolved thread); a repo without that workflow is
#       skipped. Refuses a thread from a repository other than --repo.
#
# Exit: 0 success; 1 a read or write failed (never a silent partial list);
# 2 usage error.

set -euo pipefail

# GraphQL reports a GitHub App's login without the `[bot]` suffix, and a user
# account could hold that bare name, so the author must also be a Bot actor.
BOT_RE='^chatgpt-codex-connector(\[bot\])?$'

die() { echo "codex-threads: $*" >&2; exit 1; }
usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0" >&2; exit 2; }

[ $# -ge 1 ] || usage
CMD=$1
shift
REPO="" PR="" SINCE="" THREAD="" REPLY="" HAVE_REPLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:-}; shift 2 ;;
    --pr) PR=${2:-}; shift 2 ;;
    --merged-since) SINCE=${2:-}; shift 2 ;;
    --thread) THREAD=${2:-}; shift 2 ;;
    --reply) REPLY=${2:-}; HAVE_REPLY=true; shift 2 ;;
    -h | --help) usage ;;
    *) echo "codex-threads: unknown argument: $1" >&2; usage ;;
  esac
done

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) ||
    die "could not determine the repository; pass --repo owner/name"
fi
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "bad --repo: $REPO"
OWNER=${REPO%/*}
NAME=${REPO#*/}

# list_pr N — print the PR's unresolved bot threads. Fails rather than
# truncating when the PR has more threads than one page holds.
list_pr() {
  local out
  out=$(gh api graphql -f owner="$OWNER" -f name="$NAME" -F pr="$1" -f query='
query($owner:String!,$name:String!,$pr:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$pr){
      reviewThreads(first:100){
        pageInfo{hasNextPage}
        nodes{id isResolved isOutdated path line originalLine
          comments(first:1){nodes{author{__typename login} body url}}}}}}}') ||
    die "could not read review threads of #$1"
  if [ "$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$out")" != false ]; then
    die "#$1 has more than 100 review threads (or none could be read); not listing a partial set"
  fi
  jq -r --arg pr "$1" --arg re "$BOT_RE" '
    .data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved | not)
    | .comments.nodes[0] as $c
    | select($c.author.__typename == "Bot" and (($c.author.login // "") | test($re)))
    | ((try ($c.body | capture("!\\[(?<p>P[0-9]) Badge\\]").p)) // "-") as $prio
    | ([$c.body | split("\n")[]
        | gsub("<[^>]*>|!\\[[^]]*\\]\\([^)]*\\)|\\*\\*|\\t|^#+"; "")
        | gsub("^\\s+|\\s+$"; "") | select(length > 0)] | first // "-") as $title
    | [$pr, .id, "\(.path):\(.line // .originalLine // "-")", $prio,
       (if .isOutdated then "outdated" else "current" end), $title, $c.url]
    | @tsv' <<<"$out" || die "could not parse review threads of #$1"
}

case "$CMD" in
  list)
    if [ -n "$PR" ] && [ -z "$SINCE" ]; then
      [[ "$PR" =~ ^[0-9]+$ ]] || die "bad --pr: $PR"
      list_pr "$PR"
    elif [ -n "$SINCE" ] && [ -z "$PR" ]; then
      [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "bad --merged-since: $SINCE"
      # --limit caps the whole result, so a result that reaches it may be
      # missing older PRs: refuse it rather than list a partial set.
      limit=1000
      prs=$(gh pr list -R "$REPO" --state merged --search "merged:>=$SINCE" \
        --limit "$limit" --json number --jq '.[].number') ||
        die "could not list PRs merged since $SINCE"
      if [ "$(wc -w <<<"$prs")" -ge "$limit" ]; then
        die "$limit or more PRs merged since $SINCE; use a later date"
      fi
      # Collect every PR before printing anything, so a failed read part way
      # through leaves stdout empty rather than a partial list.
      all=""
      for n in $prs; do
        rows=$(list_pr "$n") || exit 1
        [ -n "$rows" ] && all+="$rows"$'\n'
      done
      printf '%s' "$all"
    else
      echo "codex-threads: list takes exactly one of --pr or --merged-since" >&2
      usage
    fi
    ;;
  resolve)
    [ -n "$THREAD" ] || { echo "codex-threads: resolve needs --thread" >&2; usage; }
    # A resolve with no reason would erase the only record of why the finding
    # was dropped, so an empty or whitespace-only reply is refused.
    if ! $HAVE_REPLY || [ -z "${REPLY//[[:space:]]/}" ]; then
      echo "codex-threads: resolve needs a non-empty --reply" >&2
      usage
    fi
    info=$(gh api graphql -f id="$THREAD" -f query='
query($id:ID!){node(id:$id){... on PullRequestReviewThread{
  isResolved
  pullRequest{number repository{nameWithOwner}}
  comments(first:1){nodes{author{__typename login}}}}}}') ||
      die "could not read thread $THREAD"
    # Node ids are global, so a thread from another repository would pass
    # every other check here; the recount below would then hit the wrong PR.
    thread_repo=$(jq -r '.data.node.pullRequest.repository.nameWithOwner // ""' <<<"$info")
    [ "${thread_repo,,}" = "${REPO,,}" ] ||
      die "$THREAD belongs to ${thread_repo:-an unreadable repository}, not $REPO; refusing"
    author=$(jq -r '.data.node.comments.nodes[0].author.login // ""' <<<"$info")
    [ -n "$author" ] || die "$THREAD is not a readable review thread"
    kind=$(jq -r '.data.node.comments.nodes[0].author.__typename // ""' <<<"$info")
    [[ "$kind" = Bot && "$author" =~ $BOT_RE ]] ||
      die "$THREAD was opened by $author ($kind), not the Codex bot; refusing"
    if [ "$(jq -r '.data.node.isResolved' <<<"$info")" = true ]; then
      echo "already resolved: $THREAD"
      exit 0
    fi
    # Reply and resolve are separate requests: in one GraphQL document a
    # rejected reply (its field is nullable) would not stop the resolve, and
    # the thread would close with no reason on it.
    out=$(gh api graphql -f tid="$THREAD" -f body="$REPLY" -f query='
mutation($tid:ID!,$body:String!){
  addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$tid,body:$body}){comment{url}}}') ||
      die "could not reply on $THREAD; it was not resolved"
    url=$(jq -r '.data.addPullRequestReviewThreadReply.comment.url // ""' <<<"$out")
    [ -n "$url" ] || die "the reply on $THREAD did not post; it was not resolved"
    out=$(gh api graphql -f tid="$THREAD" -f query='
mutation($tid:ID!){resolveReviewThread(input:{threadId:$tid}){thread{isResolved}}}') ||
      die "replied on $THREAD ($url) but could not resolve it; resolve it on the PR"
    [ "$(jq -r '.data.resolveReviewThread.thread.isResolved' <<<"$out")" = true ] ||
      die "replied on $THREAD ($url) but it did not resolve; resolve it on the PR"
    echo "resolved: $THREAD $url"
    pr=$(jq -r '.data.node.pullRequest.number // ""' <<<"$info")
    [[ "$pr" =~ ^[0-9]+$ ]] || die "resolved $THREAD but could not read its PR number to recount"
    # The thread is resolved now and a retry exits at "already resolved", so
    # every failure from here names the command that finishes the job.
    recount="gh workflow run codex-findings.yml -R $REPO -f pr=$pr"
    remaining=$(list_pr "$pr") ||
      die "resolved $THREAD but could not recount #$pr; run: $recount"
    if [ -n "$remaining" ]; then
      exit 0 # other bot threads remain, so the label stays
    fi
    # A repo without the workflow has no label to clear; any other failure
    # to read or start it leaves a stale label, so it fails the run.
    if ! err=$(gh api "repos/$REPO/actions/workflows/codex-findings.yml" 2>&1 >/dev/null); then
      if grep -q 'HTTP 404' <<<"$err"; then
        echo "no bot threads left on #$pr ($REPO has no codex-findings workflow)"
        exit 0
      fi
      die "resolved $THREAD but could not read codex-findings.yml in $REPO ($err); run: $recount"
    fi
    gh workflow run codex-findings.yml -R "$REPO" -f pr="$pr" >/dev/null ||
      die "resolved $THREAD but could not start codex-findings; run: $recount"
    echo "no bot threads left on #$pr; started codex-findings to clear its label"
    ;;
  *) usage ;;
esac
