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
#     newest consolidated issue in any state. When it exists, NEW comments are
#     appended to its body (a closed one is reopened, since the new items are
#     unread). The body is re-read right before the edit, so ticked boxes are
#     kept and a comment a concurrent run appended meanwhile is not added
#     twice. Items that would push a body past GitHub's size limit go to a
#     `(continued)` issue carrying the same PR marker.
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

# GitHub rejects an issue body over 65536 characters, so no body this script
# writes exceeds this budget (an append counts the existing body too). An item
# that does not fit whole drops its quoted text and keeps badge, location, link
# and marker, so dedup stays exact and the full text is one click away; items
# that fit in neither form go to a continuation issue with the same PR marker.
# HARVEST_BODY_BUDGET overrides it for the tests only.
BODY_BUDGET="${HARVEST_BODY_BUDGET:-60000}"
[[ "$BODY_BUDGET" =~ ^[0-9]+$ ]] || BODY_BUDGET=60000

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
# A failed fetch is reported, never mistaken for "no comments": the close-time
# workflow fails its run on the "could not" wording.
if ! raw_comments="$(gh api "repos/$REPO/pulls/$PR/comments" --paginate 2>/dev/null)"; then
  warn "harvest-codex-comments: could not fetch the review comments of $REPO#$PR — nothing harvested."
  exit 0
fi
mapfile -t COMMENTS < <(
  jq -r --arg bot "$BOT" '
        .[] | select(.user.login == $bot)
        | [ (.id|tostring),
            ((.path // "?") | gsub("[\t\r\n]"; " ")),
            ((.line // .original_line // 0)|tostring),
            (if (.subject_type // "line") == "file" then "current"
             elif (.position == null) or (.line == null) then "outdated"
             else "current" end),
            ((.body // "") | @base64)
          ] | @tsv' <<<"$raw_comments" 2>/dev/null
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
# The index is newest-first, so the first match is the issue appends go to;
# PR_ISSUES keeps every match (continuations included) for label repair.
existing_num="" existing_state="" PR_ISSUES=()
while IFS=$'\t' read -r num state _reason ibody_row; do
  if [[ "$ibody_row" == *"$pr_marker"* ]]; then
    PR_ISSUES+=("$num")
    [[ -z "$existing_num" ]] && existing_num="$num" existing_state="$state"
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

IT_FULL=() IT_COMPACT=() IT_MARKER=() new_count=0 surface_any=false
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

  # Computed over tracked comments too, so a label that failed to apply on an
  # earlier run is repaired on the next one (ensure_labels below).
  if grep -qE "$INSTRUCTION_SURFACE_RE" <<<"$path"; then
    surface_any=true
  fi

  marker="<!-- codex-comment-id:${REPO}#${PR}:${cid} -->"
  if [[ "$existing_bodies" == *"$marker"* ]]; then
    skipped=$((skipped+1))
    continue
  fi

  # Decoded through stdin, never argv: Linux caps one argument at 128 KiB and a
  # long multibyte comment's base64 exceeds it. A failed decode leaves the
  # comment untracked (no marker written), so the next run retries it.
  if ! body="$(printf '"%s"' "$b64" | jq -r '@base64d' 2>/dev/null)"; then
    warn "  ⚠ could not decode comment $cid — left for the next run"
    continue
  fi
  # A comment body must not be able to forge a marker (or open an HTML comment
  # that swallows the real one after it), so its `<!--` is escaped. The
  # replacement is quoted: bash 5.2's patsub_replacement makes a bare `&` in it
  # mean "the matched text".
  body="${body//<!--/"&lt;!--"}"
  # The path is equally untrusted (any valid git path) and lands in the same
  # marker-indexed body, so it gets the same escape. The instruction-surface
  # match above already ran on the raw path.
  path="${path//<!--/"&lt;!--"}"
  prio="$(grep -oE 'P[0-3] Badge' <<<"$body" | head -1 | cut -c1-2 || true)"
  link="https://github.com/${REPO}/pull/${PR}#discussion_r${cid}"
  head_line="- [ ] ${prio:+**[$prio]** }\`${path}:${line}\` — [comment]($link)"
  quoted="$(sed 's/^/  > /; s/[[:space:]]*$//' <<<"$body")"
  IT_FULL+=("${head_line}

${quoted}

  ${marker}

")
  IT_COMPACT+=("${head_line} (text omitted: issue body size limit)
  ${marker}

")
  IT_MARKER+=("$marker")
  new_count=$((new_count+1))
done

labels=(codex-finding)
[[ "$surface_any" == "true" ]] && labels+=(instruction-surface)
pending=()
for ((i = 0; i < new_count; i++)); do pending+=("$i"); done

# pack_items <prefix> <suffix> — move pending items, in order, into
# prefix+suffix while the total stays within BODY_BUDGET: the full item if it
# fits, else its compact form, else stop. Sets PACKED_BODY and PACKED_N and
# leaves `pending` alone: only a caller whose write succeeded consumes the
# packed items (consume_packed), so a failed write leaves them pending.
pack_items() {
  local prefix="$1" suffix="$2" acc="" i item
  PACKED_N=0
  for i in "${pending[@]}"; do
    item="${IT_FULL[$i]}"
    if (( ${#prefix} + ${#acc} + ${#item} + ${#suffix} > BODY_BUDGET )); then
      item="${IT_COMPACT[$i]}"
      (( ${#prefix} + ${#acc} + ${#item} + ${#suffix} > BODY_BUDGET )) && break
    fi
    acc+="$item"
    PACKED_N=$((PACKED_N+1))
  done
  PACKED_BODY="${prefix}${acc}${suffix}"
}
consume_packed() { pending=("${pending[@]:PACKED_N}"); }

# ensure_labels — give every issue carrying this PR's marker (continuations
# included) each label in `labels` it lacks: `codex-finding` always, and
# `instruction-surface` when any of the PR's comments is on the gate's
# instruction surface. Checked every run (a read per issue; a write only when
# something is missing), because a label that failed at create time or in a
# separate add would otherwise never be retried: the comments it belongs to
# are already tracked, so no later run has anything new to file.
ensure_labels() {
  [[ "$DRY_RUN" != "true" ]] || return 0
  local n have l missing
  for n in "${PR_ISSUES[@]}"; do
    if ! have="$(gh api "repos/$REPO/issues/$n" --jq '.labels[].name' 2>/dev/null)"; then
      warn "  ⚠ could not read the labels of #$n"
      continue
    fi
    missing=()
    for l in "${labels[@]}"; do
      grep -qxF "$l" <<<"$have" || missing+=(-f "labels[]=$l")
    done
    [[ "${#missing[@]}" -eq 0 ]] && continue
    if gh api "repos/$REPO/issues/$n/labels" "${missing[@]}" >/dev/null 2>&1; then
      echo "  ✓ repaired labels on #$n"
    else
      warn "  ⚠ could not add labels to #$n"
    fi
  done
}

summary() {
  note "harvest-codex-comments: $1, skipped $skipped (already tracked), $obsolete obsolete (outdated/resolved)."
}

# create_issue <title> — file one consolidated issue holding as many pending
# items as fit. Returns 1 when nothing was filed.
create_issue() {
  local title="$1" labels_json payload create_status=0 response response_body url
  pack_items "$preamble" "$pr_marker"
  if [[ "$PACKED_N" -eq 0 ]]; then
    warn "  ⚠ an item does not fit an empty issue body (budget $BODY_BUDGET) — nothing filed."
    return 1
  fi
  # File via REST (POST /repos/{owner}/{repo}/issues), not `gh issue create`
  # (GraphQL). The `codex-finding` label is what the weekly janitor's issue-
  # custodian phase keys on to re-verify and close fixed findings; a REST create
  # may reject an unavailable label. Retry only a confirmed label validation
  # response: a transport failure may follow a successful creation, and the
  # body marker does not enforce server-side uniqueness.
  #
  # The request travels as JSON on stdin (`--input -`), never as `-f body=`:
  # a body near the budget in multibyte text exceeds Linux's 128 KiB cap on a
  # single argument.
  labels_json="$(printf '%s\n' "${labels[@]}" | jq -R . | jq -sc .)"
  payload="$(body_json --arg title "$title" --argjson labels "$labels_json" \
    '{title: $title, body: $body, labels: $labels}')" || { warn "  ⚠ could not build the issue request"; return 1; }
  response="$(gh api "repos/$REPO/issues" --input - --include <<<"$payload" 2>/dev/null)" || create_status=$?
  response_body="$(sed '1,/^[[:space:]]*$/d' <<<"$response")"
  if [[ "$create_status" -eq 0 ]]; then
    url="$(jq -er '.html_url | select(type == "string" and length > 0)' <<<"$response_body" 2>/dev/null)" || url=""
  elif [[ "$response" =~ ^HTTP/[0-9.]+[[:space:]]422[[:space:]] ]] \
    && jq -e '
      (.errors | type == "array" and length > 0) and
      all(.errors[];
        ((.resource == "Issue" and .field == "labels") or
         (.resource == "Label" and .field == "name")) and
        (.code == "invalid" or .code == "missing" or .code == "missing_field"))
    ' <<<"$response_body" >/dev/null 2>&1; then
    # Retry with `codex-finding` alone first when more was asked for, so a
    # rejected `instruction-surface` never costs the janitor's label; drop
    # labels entirely only if that is rejected too. ensure_labels restores
    # what is missing on a later run.
    url=""
    if [[ "${#labels[@]}" -gt 1 ]]; then
      url="$(jq -c '.labels = ["codex-finding"]' <<<"$payload" | gh api "repos/$REPO/issues" --input - --jq '.html_url' 2>/dev/null)" || url=""
    fi
    if [[ -z "$url" ]]; then
      url="$(jq -c 'del(.labels)' <<<"$payload" | gh api "repos/$REPO/issues" --input - --jq '.html_url' 2>/dev/null)" || url=""
    fi
  else
    url=""
  fi
  if [[ -z "$url" ]]; then
    warn "  ⚠ could not file the consolidated issue for $REPO#$PR ($PACKED_N item(s))"
    return 1
  fi
  consume_packed
  echo "  ✓ filed: $url ($PACKED_N item(s))"
  return 0
}

pr_title=""
title_for() {  # title_for <continued:true|false>
  if [[ -z "$pr_title" ]]; then
    pr_title="$(gh api "repos/$REPO/pulls/$PR" --jq '.title' 2>/dev/null || true)"
    pr_title="${pr_title//$'\n'/ }"
    pr_title="${pr_title:-(title unavailable)}"
  fi
  local prefix room
  if [[ "$1" == "true" ]]; then
    prefix="Codex review of #${PR} (continued): "
  else
    prefix="Codex review of #${PR}: "
  fi
  # GitHub caps an issue title at 256 characters and rejects a longer one, which
  # would fail every later run the same way; a PR title can already be 256.
  room=$((256 - ${#prefix}))
  if [[ "${#pr_title}" -gt "$room" ]]; then
    printf '%s%s…' "$prefix" "${pr_title:0:room-1}"
  else
    printf '%s%s' "$prefix" "$pr_title"
  fi
}

preamble="Filed by harvest-codex-comments — the GitHub Codex bot's inline review comments on ${REPO}#${PR}, one checklist item each, so they are not lost after merge. Tick an item once it is handled or moot; promote one to its own issue only when it needs separate tracking. Later bot comments on the same PR are appended here (or, once this body is full, to a continuation issue).

**PR:** https://github.com/${REPO}/pull/${PR}

"

if [[ "$new_count" -eq 0 ]]; then
  ensure_labels
  summary "nothing new"
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  if [[ -n "$existing_num" ]]; then
    extra=""
    [[ "$existing_state" == "closed" ]] && extra=" and reopen it"
    echo "  [dry-run] would append $new_count item(s) to #$existing_num$extra (labels: ${labels[*]})"
  else
    echo "  [dry-run] would file: $(title_for false) ($new_count item(s); labels: ${labels[*]})"
  fi
  summary "dry run — $new_count new"
  exit 0
fi

# body_json <jq args...> — run jq with PACKED_BODY bound to $body. The body goes
# through a temp file and --rawfile: never argv (Linux's 128 KiB per-argument
# cap), and never `jq -R`/`-Rs`, which in jq 1.7 splits a multibyte character
# at its 4 KiB read-buffer boundary into U+FFFD replacement characters.
body_tmp="$(mktemp "${TMPDIR:-/tmp}/harvest-codex-body.XXXXXX")" \
  || { warn "harvest-codex-comments: could not create a temp file — nothing written."; exit 0; }
trap 'rm -f "$body_tmp"' EXIT
body_json() {
  printf '%s' "$PACKED_BODY" >"$body_tmp" || return 1
  jq -nc --rawfile body "$body_tmp" "$@"
}

continued=false
# ── Append to the PR's newest consolidated issue ───────────────────────
if [[ -n "$existing_num" ]]; then
  continued=true
  # Re-read the live body (not the prefetched copy) so an operator's ticks and
  # edits since the prefetch survive the rewrite, and re-check every marker
  # against it: a concurrent harvest (the close-time workflow racing the
  # nightly routine) may have appended the same comments since the prefetch.
  # A failed read writes nothing.
  #
  # Issues have no conditional (If-Match) PATCH, so a writer racing the window
  # between this read and the PATCH below can still drop an item or an
  # operator's tick. The design converges anyway: dedup reads markers from the
  # bodies, so a dropped item is simply absent and the next run appends it
  # again (the tests pin this). The close-time workflow serializes its runs
  # for one PR with a concurrency group; only a nightly run landing in the
  # same second can race it.
  if ! current="$(gh api "repos/$REPO/issues/$existing_num" --jq '.body // ""' 2>/dev/null)"; then
    warn "  ⚠ could not read #$existing_num to append $new_count item(s) — nothing written."
    exit 0
  fi
  fresh_pending=()
  for i in "${pending[@]}"; do
    if [[ "$current" == *"${IT_MARKER[$i]}"* ]]; then
      skipped=$((skipped+1))
    else
      fresh_pending+=("$i")
    fi
  done
  pending=("${fresh_pending[@]}")
  if [[ "${#pending[@]}" -eq 0 ]]; then
    ensure_labels
    summary "nothing new after re-reading #$existing_num"
    exit 0
  fi
  pack_items "${current}

" ""
  if [[ "$PACKED_N" -gt 0 ]]; then
    new_state=""
    [[ "$existing_state" == "closed" ]] && new_state=open
    # JSON on stdin for the same argv-size reason as create_issue.
    if ! body_json --arg state "$new_state" '{body: $body} + (if $state == "" then {} else {state: $state} end)' \
      | gh api -X PATCH "repos/$REPO/issues/$existing_num" --input - --jq '.html_url' >/dev/null 2>&1; then
      warn "  ⚠ could not append to #$existing_num — nothing more written this run."
      exit 0
    fi
    consume_packed
    reopened=""
    [[ "$existing_state" == "closed" ]] && reopened=" (reopened)"
    echo "  ✓ appended $PACKED_N item(s) to #$existing_num$reopened"
  fi
  ensure_labels
fi

# ── File consolidated issues for whatever is still pending ─────────────
# Normally one; more only when the items overflow one issue body, in which
# case each further issue is a continuation carrying the same PR marker.
while [[ "${#pending[@]}" -gt 0 ]]; do
  create_issue "$(title_for "$continued")" || break
  continued=true
done
left=""
[[ "${#pending[@]}" -gt 0 ]] && left=", ${#pending[@]} left for the next run"
summary "$((new_count - ${#pending[@]})) new item(s) tracked$left"
exit 0
