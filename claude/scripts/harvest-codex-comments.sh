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
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
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
# TSV record per comment: id, path, line, then the body with newlines flattened.
mapfile -t COMMENTS < <(
  gh api "repos/$REPO/pulls/$PR/comments" --paginate 2>/dev/null \
    | jq -r --arg bot "$BOT" '
        .[] | select(.user.login == $bot)
        | [ (.id|tostring),
            (.path // "?"),
            ((.line // .original_line // 0)|tostring),
            (.body | gsub("[\r\n]+"; " ") | .[0:280])
          ] | @tsv' 2>/dev/null
)

if [[ "${#COMMENTS[@]}" -eq 0 ]]; then
  note "harvest-codex-comments: no $BOT comments on $REPO#$PR."
  exit 0
fi

note "harvest-codex-comments: $REPO#$PR — ${#COMMENTS[@]} Codex-bot comment(s)."
filed=0 skipped=0

for rec in "${COMMENTS[@]}"; do
  IFS=$'\t' read -r cid path line body <<<"$rec"
  [[ -z "${cid:-}" ]] && continue

  # Stable dedup marker: the GitHub comment id. Searching issue BODIES for it
  # survives title changes and re-runs (in-session hook + nightly backstop both
  # run this; neither should double-file).
  marker="codex-comment-id:${REPO}#${PR}:${cid}"
  if gh issue list --repo "$REPO" --state all --search "$marker in:body" \
       --json number --jq 'length' 2>/dev/null | grep -qvx '0'; then
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

  if url="$(gh issue create --repo "$REPO" --title "$title" --body "$ibody" --label "codex-bot-review" 2>/dev/null)" \
     || url="$(gh issue create --repo "$REPO" --title "$title" --body "$ibody" 2>/dev/null)"; then
    echo "  ✓ filed: $url"
    filed=$((filed+1))
  else
    warn "  ⚠ could not file issue for comment $cid"
  fi
done

note "harvest-codex-comments: filed $filed, skipped $skipped (already tracked)."
exit 0
