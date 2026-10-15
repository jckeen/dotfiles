#!/usr/bin/env bash
# fleet-codex-review.sh — roll the codex-review merge hold out across the fleet.
#
# Usage:
#   fleet-codex-review.sh [--check] [owner/repo ...]   report state; writes nothing (default)
#   fleet-codex-review.sh --apply [owner/repo ...]     converge each repo one step
#
# With no repos named, acts on ENFORCE and ADVISORY below. Per repo, --apply
# takes at most one step, so re-run it after each rollout PR merges:
#   1. The default branch lacks .github/workflows/codex-review.yml, or its copy
#      differs from this checkout's: open (or reuse) a PR on branch
#      ci/codex-review-status carrying the canonical file, with auto-merge on.
#   2. The workflow is current and the repo is in ENFORCE: create the
#      `codex-review` ruleset on ~DEFAULT_BRANCH — required status
#      `codex-review` plus required review-thread resolution. Never before step
#      1 lands: a required status no workflow posts would hold every PR forever,
#      including the rollout PR itself (pull_request_target runs the base
#      branch's workflow).
# A dedicated ruleset leaves every existing rule untouched and reverts with one
# call: gh api -X DELETE repos/<owner/repo>/rulesets/<id>.
#
# Self-test: claude/scripts/tests/fleet-codex-review.test.sh (fake gh).
# Requires gh authenticated with admin on each repo, and jq.

set -euo pipefail

# Repos whose PRs get Codex bot reviews and land through PRs only.
ENFORCE=(
  jckeen/dotfiles
  jckeen/agent-pack
  jckeen/aios
  jckeen/allora-engine
  jckeen/atlas
  jckeen/clarity-engine
  jckeen/claude-council-review
  Keen-Media/TRNN
  Keen-Media/beacon
  Keen-Media/impact-dash
  Keen-Media/keen-media
  Keen-Media/newsroom-cut
  Keen-Media/operator-commons
  Keen-Media/parlance
  Keen-Media/pp2qbo
  Keen-Media/smss
  Keen-Media/stringer
)
# Bot-reviewed repos whose default branch still takes direct pushes, which a
# required status would block: the workflow posts the status, nothing requires it.
ADVISORY=(
  jckeen/agentpack-web
  jckeen/creator-studios
  Keen-Media/giant-steps
)

WORKFLOW_PATH=.github/workflows/codex-review.yml
BRANCH=ci/codex-review-status
RULESET=codex-review
# The GitHub Actions app (gh api apps/github-actions). Pinning the required
# status to it means only a workflow can satisfy it, not a person or another
# integration posting `codex-review` by hand.
ACTIONS_APP_ID=15368
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/$WORKFLOW_PATH"

mode=check
repos=()
for arg in "$@"; do
  case "$arg" in
    --check) mode=check ;;
    --apply) mode=apply ;;
    -h | --help)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    */*) repos+=("$arg") ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done
[ -f "$CANONICAL" ] || {
  echo "canonical workflow missing: $CANONICAL" >&2
  exit 2
}
if [ "${#repos[@]}" -eq 0 ]; then
  repos=("${ENFORCE[@]}" "${ADVISORY[@]}")
fi

enforced() {
  local r
  for r in "${ENFORCE[@]}"; do [ "$r" = "$1" ] && return 0; done
  return 1
}

# Prints current | stale | missing for the workflow on <repo>@<ref>.
workflow_state() {
  local repo="$1" ref="$2" content
  if ! content="$(gh api "repos/$repo/contents/$WORKFLOW_PATH?ref=$ref" --jq .content 2>/dev/null)"; then
    echo missing
    return
  fi
  if [ "$(printf '%s' "$content" | base64 -d)" = "$(cat "$CANONICAL")" ]; then
    echo current
  else
    echo stale
  fi
}

ruleset_id() {
  gh api "repos/$1/rulesets" --jq "[.[] | select(.name == \"$RULESET\")][0].id // empty"
}

open_rollout_pr() {
  gh pr list -R "$1" --head "$BRANCH" --state open --json number --jq '.[0].number // empty'
}

# Called from an OR-list, where bash suspends errexit inside the function, so
# every write checks its own result and stops the rollout for this repo.
ship_workflow() {
  local repo="$1" base="$2" pr base_sha file_sha body
  pr="$(open_rollout_pr "$repo")"
  if [ -n "$pr" ]; then
    echo "  rollout PR #$pr already open"
    return 0
  fi
  # A leftover branch with no open PR is reported, never force-reset: it may
  # hold someone's work.
  if gh api "repos/$repo/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
    echo "  branch $BRANCH exists with no open PR; inspect or delete it, then re-run" >&2
    return 1
  fi
  if ! base_sha="$(gh api "repos/$repo/git/ref/heads/$base" --jq .object.sha)" || [ -z "$base_sha" ]; then
    echo "  could not read $base" >&2
    return 1
  fi
  if ! gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$base_sha" >/dev/null; then
    echo "  could not create branch $BRANCH" >&2
    return 1
  fi
  file_sha="$(gh api "repos/$repo/contents/$WORKFLOW_PATH?ref=$BRANCH" --jq .sha 2>/dev/null || true)"
  local args=(-X PUT "repos/$repo/contents/$WORKFLOW_PATH" -f branch="$BRANCH"
    -f message="ci: hold merges until the Codex bot review finishes"
    -f content="$(base64 -w0 <"$CANONICAL")")
  [ -n "$file_sha" ] && args+=(-f sha="$file_sha")
  if ! gh api "${args[@]}" >/dev/null; then
    echo "  could not write $WORKFLOW_PATH on $BRANCH; branch left for inspection" >&2
    return 1
  fi
  body="$(mktemp)"
  cat >"$body" <<'EOF'
Adds the `codex-review` workflow from jckeen/dotfiles (`.github/workflows/codex-review.yml`, copied verbatim by `claude/scripts/fleet-codex-review.sh`).

It posts a `codex-review` commit status on each PR: pending while the GitHub Codex bot reviews, success once its summary table reads Completed. Docs-only and Dependabot PRs pass at once. A review counts only for the PR's head commit: a later push gets an `@codex review` request and holds until that review completes. If the bot never picks a PR up at all, the status passes after three minutes. A `codex-skip` label applied by an admin or maintainer passes it by hand.

Nothing requires the status until the follow-up `codex-review` ruleset is created after this merges; this PR on its own changes no merge behavior.

Revert: `git revert <merge sha>` (delete the `codex-review` ruleset first if it was created).
EOF
  if ! pr="$(gh pr create -R "$repo" --base "$base" --head "$BRANCH" \
    --title "ci: hold merges until the Codex bot review finishes" --body-file "$body")"; then
    rm -f "$body"
    echo "  could not open the rollout PR; branch $BRANCH left for inspection" >&2
    return 1
  fi
  rm -f "$body"
  echo "  opened $pr"
  if ! gh pr merge -R "$repo" --auto --squash "$pr" >/dev/null; then
    echo "  could not enable auto-merge on $pr; merge it by hand" >&2
    return 1
  fi
}

create_ruleset() {
  local repo="$1"
  jq -n --arg name "$RULESET" --argjson app "$ACTIONS_APP_ID" '{
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false,
        do_not_enforce_on_create: false,
        required_status_checks: [{context: "codex-review", integration_id: $app}]}},
      {type: "pull_request", parameters: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: true,
        allowed_merge_methods: ["merge", "squash", "rebase"]}}
    ]
  }' | gh api -X POST "repos/$repo/rulesets" --input - --jq '"  created ruleset \(.id)"'
}

rc=0
for repo in "${repos[@]}"; do
  echo "== $repo"
  if ! base="$(gh api "repos/$repo" --jq .default_branch 2>/dev/null)"; then
    echo "  cannot read repo" >&2
    rc=1
    continue
  fi
  wf="$(workflow_state "$repo" "$base")"
  rs="$(ruleset_id "$repo" || true)"
  if enforced "$repo"; then want=enforce; else want=advisory; fi
  echo "  workflow=$wf ruleset=${rs:-none} mode=$want"
  [ "$mode" = apply ] || continue
  if [ "$wf" != current ] && [ "$repo" = jckeen/dotfiles ]; then
    # The canonical copy lands here through dotfiles' own reviewed PR.
    echo "  workflow lands through the dotfiles PR; nothing to do here"
  elif [ "$wf" != current ]; then
    ship_workflow "$repo" "$base" || rc=1
  elif [ "$want" = enforce ] && [ -z "$rs" ]; then
    create_ruleset "$repo" || rc=1
    # PRs opened before the workflow landed have no status yet; any new event
    # (a push, or adding and removing a label) posts one.
    gh pr list -R "$repo" --state open --json number,title \
      --jq '.[] | "  open PR without a status until its next event: #\(.number) \(.title)"'
  else
    echo "  nothing to do"
  fi
done
exit "$rc"
