#!/usr/bin/env bash
# harvest-codex-comments.sh — capture GitHub Codex-bot (chatgpt-codex-connector[bot])
# PR review comments as tracked GitHub issues, so the bot's asynchronous findings
# aren't lost when a PR merges before or without them being read.
#
# The local Codex gate (codex-review-gate.sh) and the GitHub Codex bot are two
# different reviewers with different context, so the bot surfaces things the local
# gate doesn't — but it comments server-side, ~1-2 min after the PR opens, which is
# easy to merge past. This turns those comments into issues (the fleet's tracker).
#
# Obsolete comments are skipped (#159): outdated anchors are detected via REST;
# resolved threads via a best-effort GraphQL call that degrades to "keep" when
# GraphQL is blocked (REST is the only hard dependency — see dedup note below).
#
# Two callers, one logic:
#   - PreMergeCodexHarvest.hook.ts  — in-session, warn-only, at `gh pr merge` time.
#   - nightly-docs-steward routine  — cloud backstop for comments that land later.
#
# Usage:
#   harvest-codex-comments.sh [--pr N] [--repo owner/name] [--dry-run] [--quiet]
#     --pr N       specific PR (default: the current branch's open PR)
#     --repo slug  owner/name (default: the current repo)
#     --dry-run    print what would be filed; create nothing
#     --quiet      suppress the "nothing to harvest" success line
#
# Exit: always 0 (informational — never blocks a caller). Degrades silently when
# gh, a repo, or a PR is absent.

set -uo pipefail

BOT="chatgpt-codex-connector[bot]"
PR=""
REPO=""
DRY_RUN=false
QUIET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)      PR="${2:-}"; shift 2 ;;
    --repo)    REPO="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --quiet)   QUIET=true; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *)         echo "harvest-codex-comments: unknown arg: $1" >&2; exit 0 ;;  # never hard-fail a caller
  esac
done

note()  { [[ "$QUIET" == "true" ]] || echo "$*"; }
warn()  { echo "$*" >&2; }

command -v gh >/dev/null 2>&1 || { warn "harvest-codex-comments: gh not found — skipping."; exit 0; }

# Resolve repo + PR from context when not given.
if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
[[ -z "$REPO" ]] && { warn "harvest-codex-comments: no repo context — skipping."; exit 0; }

if [[ -z "$PR" ]]; then
  PR="$(gh pr view --json number --jq .number 2>/dev/null || true)"
fi
[[ -z "$PR" ]] && { note "harvest-codex-comments: no PR for current branch — nothing to harvest."; exit 0; }

# Fetch the bot's inline review comments. jq selects only the bot's, emitting one
# TSV record per comment: id, path, line, freshness, then the body flattened.
#
# Freshness: an "outdated" comment is one whose anchor no longer exists in the
# current head diff — the code it flagged was already changed, so filing an issue
# for it would track a fixed problem (#159). REST signals for that: the docs say
# `position` goes null, but empirically GitHub may instead re-anchor `commit_id`
# to the new head and null out `line` (keeping `original_line`), so we treat
# either as outdated. `position` and `line` are legitimately null on file-level
# comments (subject_type "file"), so those are exempt from both signals.
mapfile -t COMMENTS < <(
  gh api "repos/$REPO/pulls/$PR/comments" --paginate 2>/dev/null \
    | jq -r --arg bot "$BOT" '
        .[] | select(.user.login == $bot)
        | [ (.id|tostring),
            (.path // "?"),
            ((.line // .original_line // 0)|tostring),
            (if (.subject_type // "line") == "file" then "current"
             elif (.position == null) or (.line == null) then "outdated"
             else "current" end),
            (.body | gsub("[\r\n]+"; " ") | .[0:280])
          ] | @tsv' 2>/dev/null
)

if [[ "${#COMMENTS[@]}" -eq 0 ]]; then
  note "harvest-codex-comments: no $BOT comments on $REPO#$PR."
  exit 0
fi

note "harvest-codex-comments: $REPO#$PR — ${#COMMENTS[@]} Codex-bot comment(s)."
filed=0 skipped=0 obsolete=0

# Pre-fetch existing issue bodies ONCE via REST for dedup. We deliberately avoid
# `gh issue list --search` and `gh issue create`: both go through GitHub's GraphQL
# API, which egress-restricted proxies (e.g. Claude Cloud routine sandboxes) block
# — only plain REST under repos/{owner}/{repo}/... is served. REST works in those
# environments AND locally, so the whole script stays portable. Dedup then greps
# the stable per-comment marker (the GitHub comment id) in-memory.
existing_bodies="$(gh api "repos/$REPO/issues?state=all&per_page=100" --paginate --jq '.[].body // ""' 2>/dev/null || true)"

# Best-effort resolved-thread check (#159). Thread resolution (isResolved) is
# NOT exposed by REST — only by GraphQL, which egress-restricted proxies (the
# Claude Cloud routine sandbox) block. So this is strictly optional: when the
# call fails or returns nothing, resolved_ids stays empty and every comment is
# treated as unresolved, exactly as before. Never make this path required.
# shellcheck disable=SC2016  # $owner/$name/$pr are GraphQL variables, not shell
resolved_ids="$(gh api graphql \
  -f query='query($owner:String!,$name:String!,$pr:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$pr){
          reviewThreads(first:100){
            nodes{ isResolved comments(first:50){ nodes{ databaseId } } } } } } }' \
  -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F pr="$PR" \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved) | .comments.nodes[].databaseId' 2>/dev/null || true)"

# Pre-fetch existing issue bodies ONCE via REST for dedup. We deliberately avoid
# `gh issue list --search` and `gh issue create`: both go through GitHub's GraphQL
# API, which egress-restricted proxies (e.g. Claude Cloud routine sandboxes) block
# — only plain REST under repos/{owner}/{repo}/... is served. REST works in those
# environments AND locally, so the whole script stays portable. Dedup then greps
# the stable per-comment marker (the GitHub comment id) in-memory.
existing_bodies="$(gh api "repos/$REPO/issues?state=all&per_page=100" --paginate --jq '.[].body // ""' 2>/dev/null || true)"

for rec in "${COMMENTS[@]}"; do
  IFS=$'\t' read -r cid path line fresh body <<<"$rec"
  [[ -z "${cid:-}" ]] && continue

  # Skip obsolete comments: outdated anchors (REST signal, computed above) and
  # resolved threads (optional GraphQL signal). The flagged code was already
  # fixed or the thread was closed out — filing an issue would track a non-problem.
  if [[ "$fresh" == "outdated" ]]; then
    note "  ∅ skipping outdated comment $cid ($path:$line — anchor gone from head diff)"
    obsolete=$((obsolete+1))
    continue
  fi
  if [[ -n "$resolved_ids" ]] && grep -qxF "$cid" <<<"$resolved_ids"; then
    note "  ∅ skipping resolved comment $cid ($path:$line — thread marked resolved)"
    obsolete=$((obsolete+1))
    continue
  fi

  marker="codex-comment-id:${REPO}#${PR}:${cid}"
  if grep -qF "$marker" <<<"$existing_bodies"; then
    skipped=$((skipped+1))
    continue
  fi

  # Trim a priority tag out of the badge markdown if present, for the title.
  prio="$(grep -oE 'P[0-3]' <<<"$body" | head -1 || true)"
  short="$(sed -E 's/!\[[^]]*\]\([^)]*\)//g; s/<[^>]*>//g; s/[*`_]//g; s/^[[:space:]]+//' <<<"$body" | cut -c1-70)"
  title="codex-bot${prio:+ [$prio]}: ${path}:${line} — ${short}"
  ibody="Filed by harvest-codex-comments — a GitHub Codex-bot review comment on a PR, captured so it isn't lost after merge.

**Source:** ${REPO}#${PR} inline comment on \`${path}:${line}\`
**Comment:** ${body}
**Link:** https://github.com/${REPO}/pull/${PR}#discussion_r${cid}

<!-- ${marker} -->"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] would file: $title"
    filed=$((filed+1))
    continue
  fi

  # File via REST (POST /repos/{owner}/{repo}/issues), not `gh issue create`
  # (GraphQL). No label: a REST create with a non-existent label 422s, and the
  # body marker is what dedup relies on. --jq pulls the new issue URL.
  if url="$(gh api "repos/$REPO/issues" -f title="$title" -f body="$ibody" --jq '.html_url' 2>/dev/null)"; then
    echo "  ✓ filed: $url"
    filed=$((filed+1))
  else
    warn "  ⚠ could not file issue for comment $cid"
  fi
done

note "harvest-codex-comments: filed $filed, skipped $skipped (already tracked), $obsolete obsolete (outdated/resolved)."
exit 0
