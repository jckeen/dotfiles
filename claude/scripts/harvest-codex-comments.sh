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
# One issue per PR (#556), titled `Codex review of #<n>: <PR title>`: a checklist
# with one item per bot comment — priority badge, path:line, link, and the FULL
# comment body quoted. The issue is the finding list, not the work item; promote
# an individual item to its own issue only when it needs separate tracking.
#
# Dedup is two-level, both against one REST prefetch of every issue body:
#   - outer, by PR: the `codex-review-pr:<repo>#<n>` marker finds the PR's
#     consolidated issue in any state. When it exists, NEW comments are appended
#     to its body (a closed one is reopened, since the new items are unread);
#     ticked boxes and other edits are kept, because the body is re-read right
#     before the edit.
#   - inner, by comment: each item carries `codex-comment-id:<repo>#<n>:<id>`, so
#     a comment already tracked — in the consolidated issue or in a legacy
#     one-issue-per-comment issue — is never added twice.
# Appending edits the body rather than adding an issue comment because the
# prefetch reads bodies only: an id left in a comment would be invisible to the
# next run's dedup, and the item would be re-appended every run.
#
# An issue whose items touch the Codex gate's own instruction surface also gets
# the `instruction-surface` label (#557); see INSTRUCTION_SURFACE_RE below.
#
# Obsolete comments are skipped (#159): outdated anchors are detected via REST;
# resolved threads via a best-effort GraphQL call that degrades to "keep" when
# GraphQL is blocked (REST is the only hard dependency — see dedup note below).
#
# Callers, one logic, idempotent against each other through the dedup above:
#   - .github/workflows/harvest-codex-comments.yml — on PR close (merged), under
#     GITHUB_TOKEN: the primary capture (#555). Auto-merge lands after CI, by
#     which time the bot has normally reviewed.
#   - nightly-docs-steward routine — cloud backstop for comments that land
#     later; those append to the same issue.
#   - PreMergeCodexHarvest.hook.sh — in-session, warn-only, at `gh pr merge`
#     time. Under `--auto` it runs before the bot has reviewed, so it usually
#     finds nothing and says the close-time harvest will file it.
#
# Usage:
#   harvest-codex-comments.sh [--pr N] [--repo owner/name] [--dry-run] [--quiet]
#     --pr N       specific PR (default: the current branch's open PR)
#     --repo slug  owner/name (default: the current repo)
#     --dry-run    print what would be filed or appended; write nothing
#     --quiet      suppress the "nothing to harvest" success line
#
# Exit: always 0 (informational — never blocks a caller). Degrades silently when
# gh, a repo, or a PR is absent.

set -uo pipefail

# gate-lib.sh ships beside this script in BOTH install locations (the repo's
# claude/scripts/ and the ~/.claude/scripts symlink farm), so a plain dirname
# is sufficient and portable — no readlink -f (absent on stock macOS). It
# provides the shared issue prefetch used for dedup below.
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}" && printf .)" || exit 0
SCRIPT_DIR=${SCRIPT_DIR%$'\n.'}
SCRIPT_DIR="$(cd -- "$SCRIPT_DIR" && pwd && printf .)" || exit 0
SCRIPT_DIR=${SCRIPT_DIR%$'\n.'}
# This script never blocks a caller, so a missing library degrades to a skip
# rather than a hard failure — but it says so instead of running dedup-blind.
# shellcheck source=gate-lib.sh
if ! . "$SCRIPT_DIR/gate-lib.sh"; then
  echo "harvest-codex-comments: gate-lib.sh not found beside this script — skipping." >&2
  exit 0
fi

BOT="chatgpt-codex-connector[bot]"
PR=""
REPO=""
DRY_RUN=false
QUIET=false

# Copied verbatim from the self-review guard in codex-review-gate.sh (the
# `grep -qE` on CHANGED_PATHS). The two must stay in sync: a bot comment on a
# path the gate refuses to self-review is a finding a human must look at, so the
# issue carrying it is labelled for that queue. The harvester test compares the
# two strings, so an edit to one without the other fails CI.
INSTRUCTION_SURFACE_RE='(^|/)AGENTS(\.local)?\.md$|(^|/)\.?codex(/|$)|(^|/)\.?agents(/skills(/|$)|$)|(^|/)\.?claude(/scripts)?$|(^|/)(gate-lib\.sh|review-receipt\.py|review-multipart\.py|codex-review-schema\.json)$|(^|/)(codex|antigravity)-review-gate\.sh$|(^|/)\.codex-review-ignore$'

# GitHub rejects an issue body over 65536 characters. Past this budget the
# items drop their quoted comment text and keep badge, location, link and
# marker, so dedup stays exact and the full text is one click away.
BODY_BUDGET=60000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)      PR="${2:-}"; shift 2 ;;
    --repo)    REPO="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --quiet)   QUIET=true; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
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
# PR goes into markers and an API path; anything but digits is a caller error.
[[ "$PR" =~ ^[0-9]+$ ]] || { warn "harvest-codex-comments: --pr must be a number, got '$PR' — skipping."; exit 0; }

# Fetch the bot's inline review comments. jq selects only the bot's, emitting one
# TSV record per comment: id, path, line, freshness, then the body base64-encoded
# (last, so an empty body cannot shift a field) — the full text survives
# newlines and tabs and is decoded per item below.
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
            ((.path // "?") | gsub("[\t\r\n]"; " ")),
            ((.line // .original_line // 0)|tostring),
            (if (.subject_type // "line") == "file" then "current"
             elif (.position == null) or (.line == null) then "outdated"
             else "current" end),
            ((.body // "") | @base64)
          ] | @tsv' 2>/dev/null
)

if [[ "${#COMMENTS[@]}" -eq 0 ]]; then
  note "harvest-codex-comments: no $BOT comments on $REPO#$PR."
  exit 0
fi

note "harvest-codex-comments: $REPO#$PR — ${#COMMENTS[@]} Codex-bot comment(s)."
skipped=0 obsolete=0

# Pre-fetch existing issues ONCE for dedup, through the shared gate-lib
# mechanism (gate_issue_prefetch) that the review gate's low-finding feed also
# uses: one REST call, one in-memory index, one place to fix. The REST-only
# rationale lives with it — `gh issue list --search` and `gh issue create` go
# through GitHub's GraphQL API, which egress-restricted proxies (e.g. Claude
# Cloud routine sandboxes) block. The index rows are
# "number<TAB>state<TAB>state_reason<TAB>body".
#
# A failed prefetch leaves the index empty, which is the pre-existing posture
# here: this script never blocks a caller, and its markers are the immutable
# PR number and comment ids, so the worst case is a duplicate issue rather
# than a wrong one.
if ! gate_issue_prefetch "$REPO"; then
  warn "harvest-codex-comments: could not pre-fetch existing issues — dedup is blind for this run."
fi
existing_bodies="$GATE_ISSUE_INDEX"

# Markers include the closing ` -->`, so `#1` never matches `#12` and comment
# 123 never matches 1234.
pr_marker="<!-- codex-review-pr:${REPO}#${PR} -->"
existing_num="" existing_state=""
while IFS=$'\t' read -r num state _reason ibody_row; do
  if [[ "$ibody_row" == *"$pr_marker"* ]]; then
    existing_num="$num" existing_state="$state"
    break
  fi
done <<<"$existing_bodies"

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

items_full="" items_compact="" new_count=0 surface=false
for rec in "${COMMENTS[@]}"; do
  IFS=$'\t' read -r cid path line fresh b64 <<<"$rec"
  [[ -z "${cid:-}" ]] && continue

  # Skip obsolete comments: outdated anchors (REST signal, computed above) and
  # resolved threads (optional GraphQL signal). The flagged code was already
  # fixed or the thread was closed out — filing it would track a non-problem.
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

  marker="<!-- codex-comment-id:${REPO}#${PR}:${cid} -->"
  if [[ "$existing_bodies" == *"$marker"* ]]; then
    skipped=$((skipped+1))
    continue
  fi

  body="$(jq -rn --arg b "$b64" '$b | @base64d' 2>/dev/null || true)"
  # A comment body must not be able to forge a marker (or open an HTML comment
  # that swallows the real one after it), so its `<!--` is escaped. The
  # replacement is quoted: bash 5.2's patsub_replacement makes a bare `&` in it
  # mean "the matched text".
  body="${body//<!--/"&lt;!--"}"
  prio="$(grep -oE 'P[0-3] Badge' <<<"$body" | head -1 | cut -c1-2 || true)"
  if grep -qE "$INSTRUCTION_SURFACE_RE" <<<"$path"; then
    surface=true
  fi
  link="https://github.com/${REPO}/pull/${PR}#discussion_r${cid}"
  head_line="- [ ] ${prio:+**[$prio]** }\`${path}:${line}\` — [comment]($link)"
  quoted="$(sed 's/^/  > /; s/[[:space:]]*$//' <<<"$body")"
  items_full+="${head_line}

${quoted}

  ${marker}

"
  items_compact+="${head_line} (text omitted: issue body size limit)
  ${marker}

"
  new_count=$((new_count+1))
done

if [[ "$new_count" -eq 0 ]]; then
  note "harvest-codex-comments: nothing new — skipped $skipped (already tracked), $obsolete obsolete (outdated/resolved)."
  exit 0
fi

labels=(codex-finding)
[[ "$surface" == "true" ]] && labels+=(instruction-surface)

# ── Append to the PR's existing consolidated issue ─────────────────────
if [[ -n "$existing_num" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    extra=""
    [[ "$surface" == "true" ]] && extra+=" (+ label instruction-surface)"
    [[ "$existing_state" == "closed" ]] && extra+=" and reopen it"
    echo "  [dry-run] would append $new_count item(s) to #$existing_num$extra"
    note "harvest-codex-comments: dry run — $new_count new, skipped $skipped (already tracked), $obsolete obsolete (outdated/resolved)."
    exit 0
  fi
  # Re-read the live body (not the prefetched copy) so an operator's ticks and
  # edits since the prefetch survive the rewrite. A failed read writes nothing.
  if ! current="$(gh api "repos/$REPO/issues/$existing_num" --jq '.body // ""' 2>/dev/null)"; then
    warn "  ⚠ could not read #$existing_num to append $new_count item(s) — nothing written."
    exit 0
  fi
  new_body="${current}

${items_full}"
  if [[ "${#new_body}" -gt "$BODY_BUDGET" ]]; then
    new_body="${current}

${items_compact}"
  fi
  patch_args=(-f body="$new_body")
  [[ "$existing_state" == "closed" ]] && patch_args+=(-f state=open)
  if gh api -X PATCH "repos/$REPO/issues/$existing_num" "${patch_args[@]}" --jq '.html_url' >/dev/null 2>&1; then
    reopened=""
    [[ "$existing_state" == "closed" ]] && reopened=" (reopened)"
    echo "  ✓ appended $new_count item(s) to #$existing_num$reopened"
    if [[ "$surface" == "true" ]]; then
      gh api "repos/$REPO/issues/$existing_num/labels" -f 'labels[]=instruction-surface' >/dev/null 2>&1 \
        || warn "  ⚠ could not add label instruction-surface to #$existing_num"
    fi
  else
    warn "  ⚠ could not append to #$existing_num"
  fi
  note "harvest-codex-comments: appended $new_count, skipped $skipped (already tracked), $obsolete obsolete (outdated/resolved)."
  exit 0
fi

# ── File a new consolidated issue for this PR ──────────────────────────
pr_title="$(gh api "repos/$REPO/pulls/$PR" --jq '.title' 2>/dev/null || true)"
pr_title="${pr_title//$'\n'/ }"
title="Codex review of #${PR}: ${pr_title:-(title unavailable)}"
preamble="Filed by harvest-codex-comments — the GitHub Codex bot's inline review comments on ${REPO}#${PR}, one checklist item each, so they are not lost after merge. Tick an item once it is handled or moot; promote one to its own issue only when it needs separate tracking. Later bot comments on the same PR are appended here.

**PR:** https://github.com/${REPO}/pull/${PR}

"
ibody="${preamble}${items_full}${pr_marker}"
if [[ "${#ibody}" -gt "$BODY_BUDGET" ]]; then
  ibody="${preamble}${items_compact}${pr_marker}"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [dry-run] would file: $title ($new_count item(s); labels: ${labels[*]})"
  note "harvest-codex-comments: dry run — $new_count new, skipped $skipped (already tracked), $obsolete obsolete (outdated/resolved)."
  exit 0
fi

# File via REST (POST /repos/{owner}/{repo}/issues), not `gh issue create`
# (GraphQL). The `codex-finding` label is what the weekly janitor's issue-
# custodian phase keys on to re-verify and close fixed findings; a REST create
# may reject an unavailable label. Retry only a confirmed label validation
# response: a transport failure may follow a successful creation, and the
# body marker does not enforce server-side uniqueness.
label_args=()
for l in "${labels[@]}"; do label_args+=(-f "labels[]=$l"); done
create_status=0
response="$(gh api "repos/$REPO/issues" -f title="$title" -f body="$ibody" "${label_args[@]}" --include 2>/dev/null)" || create_status=$?
response_body="$(sed '1,/^[[:space:]]*$/d' <<<"$response")"
created=false
if [[ "$create_status" -eq 0 ]]; then
  if url="$(jq -er '.html_url | select(type == "string" and length > 0)' <<<"$response_body" 2>/dev/null)"; then
    created=true
  fi
elif [[ "$response" =~ ^HTTP/[0-9.]+[[:space:]]422[[:space:]] ]] \
  && jq -e '
    (.errors | type == "array" and length > 0) and
    all(.errors[];
      ((.resource == "Issue" and .field == "labels") or
       (.resource == "Label" and .field == "name")) and
      (.code == "invalid" or .code == "missing" or .code == "missing_field"))
  ' <<<"$response_body" >/dev/null 2>&1; then
  if url="$(gh api "repos/$REPO/issues" -f title="$title" -f body="$ibody" --jq '.html_url' 2>/dev/null)"; then
    created=true
  fi
fi
if [[ "$created" == "true" ]]; then
  echo "  ✓ filed: $url ($new_count item(s))"
  note "harvest-codex-comments: filed 1 issue with $new_count item(s), skipped $skipped (already tracked), $obsolete obsolete (outdated/resolved)."
else
  warn "  ⚠ could not file the consolidated issue for $REPO#$PR ($new_count item(s))"
fi
exit 0
