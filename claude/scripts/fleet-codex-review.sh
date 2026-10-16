#!/usr/bin/env bash
# fleet-codex-review.sh — roll the codex-review merge hold out across the fleet.
#
# Usage:
#   fleet-codex-review.sh [--check] [owner/repo ...]   report state; writes nothing (default)
#   fleet-codex-review.sh --apply [owner/repo ...]     converge each repo one step
#
# With no repos named, acts on ENFORCE and ADVISORY below. Per repo, --apply
# takes at most one step, so re-run it after each rollout PR merges:
#   1. The default branch lacks one of WORKFLOWS (.github/workflows/
#      codex-review.yml, codex-findings.yml), or its copy differs from this
#      checkout's: open (or reuse) a PR on branch ci/codex-review-status
#      carrying every file that is not current, with auto-merge on.
#   2. Every workflow is current and the repo is in ENFORCE: create the
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

# codex-review.yml posts the required status; codex-findings.yml labels PRs
# that still have unresolved bot threads (dotfiles#617).
WORKFLOW_DIR=.github/workflows
WORKFLOWS=(codex-review.yml codex-findings.yml)
BRANCH=ci/codex-review-status
RULESET=codex-review
# The GitHub Actions app (gh api apps/github-actions). Pinning the required
# status to it means only a workflow can satisfy it, not a person or another
# integration posting `codex-review` by hand.
ACTIONS_APP_ID=15368
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL_DIR="$ROOT/$WORKFLOW_DIR"

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
for f in "${WORKFLOWS[@]}"; do
  [ -f "$CANONICAL_DIR/$f" ] || {
    echo "canonical workflow missing: $CANONICAL_DIR/$f" >&2
    exit 2
  }
done
if [ "${#repos[@]}" -eq 0 ]; then
  repos=("${ENFORCE[@]}" "${ADVISORY[@]}")
fi

enforced() {
  local r
  for r in "${ENFORCE[@]}"; do [ "$r" = "$1" ] && return 0; done
  return 1
}

# Prints current | stale | missing | unreadable for one workflow file on
# <repo>@<ref>. Only a 404 is missing; any other failed read is unreadable,
# which stops the repo rather than shipping a file it may already have.
file_state() {
  local repo="$1" ref="$2" f="$3" content err
  err="$(mktemp)"
  if ! content="$(gh api "repos/$repo/contents/$WORKFLOW_DIR/$f?ref=$ref" --jq .content 2>"$err")"; then
    if grep -q 'HTTP 404' "$err"; then echo missing; else echo unreadable; fi
    rm -f "$err"
    return
  fi
  rm -f "$err"
  if [ "$(printf '%s' "$content" | base64 -d)" = "$(cat "$CANONICAL_DIR/$f")" ]; then
    echo current
  else
    echo stale
  fi
}

# Prints current when every workflow is, else the files that are not, as
# file:state pairs (e.g. "codex-findings.yml:missing").
workflow_state() {
  local repo="$1" ref="$2" f st out=()
  for f in "${WORKFLOWS[@]}"; do
    st="$(file_state "$repo" "$ref" "$f")"
    [ "$st" = current ] || out+=("$f:$st")
  done
  if [ "${#out[@]}" -eq 0 ]; then echo current; else echo "${out[*]}"; fi
}

# Fails when the rulesets cannot be read, so the caller never mistakes a
# failed read for "no ruleset" and creates a duplicate.
ruleset_id() {
  gh api "repos/$1/rulesets" --jq "[.[] | select(.name == \"$RULESET\")][0].id // empty"
}

open_rollout_pr() {
  gh pr list -R "$1" --head "$BRANCH" --state open --json number --jq '.[0].number // empty'
}

# Called from an OR-list, where bash suspends errexit inside the function, so
# every write checks its own result and stops the rollout for this repo.
# ship_workflow <repo> <base> <workflow state>: the state is workflow_state's
# file:state pairs from the one read the caller already checked, so nothing
# here re-reads the default branch and acts on a failed read.
ship_workflow() {
  local repo="$1" base="$2" todo="$3" pr base_sha file_sha body pair f st
  if ! pr="$(open_rollout_pr "$repo")"; then
    echo "  could not list open PRs" >&2
    return 1
  fi
  if [ -n "$pr" ]; then
    echo "  rollout PR #$pr already open"
    return 0
  fi
  # A leftover branch with no open PR is reported, never force-reset: it may
  # hold someone's work.
  local err
  err="$(mktemp)"
  if gh api "repos/$repo/git/ref/heads/$BRANCH" >/dev/null 2>"$err"; then
    rm -f "$err"
    echo "  branch $BRANCH exists with no open PR; inspect or delete it, then re-run" >&2
    return 1
  fi
  # Only a 404 means the branch is absent.
  if ! grep -q 'HTTP 404' "$err"; then
    echo "  could not read branch $BRANCH: $(cat "$err")" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  if ! base_sha="$(gh api "repos/$repo/git/ref/heads/$base" --jq .object.sha)" || [ -z "$base_sha" ]; then
    echo "  could not read $base" >&2
    return 1
  fi
  # Every read happens before the first write: a stale file's blob sha is
  # read at the base commit the branch is about to be cut from (the same
  # blob), so a failed read leaves no branch and no partial upload behind.
  local shas=()
  for pair in $todo; do
    f=${pair%%:*}
    st=${pair#*:}
    file_sha=""
    if [ "$st" = stale ]; then
      if ! file_sha="$(gh api "repos/$repo/contents/$WORKFLOW_DIR/$f?ref=$base_sha" --jq .sha)" || [ -z "$file_sha" ]; then
        echo "  could not read $WORKFLOW_DIR/$f at $base_sha; nothing written" >&2
        return 1
      fi
    fi
    shas+=("$file_sha")
  done
  if ! gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$base_sha" >/dev/null; then
    echo "  could not create branch $BRANCH" >&2
    return 1
  fi
  local i=0
  for pair in $todo; do
    f=${pair%%:*}
    local args=(-X PUT "repos/$repo/contents/$WORKFLOW_DIR/$f" -f branch="$BRANCH"
      -f message="ci: add or update $f from jckeen/dotfiles"
      -f content="$(base64 -w0 <"$CANONICAL_DIR/$f")")
    [ -n "${shas[$i]}" ] && args+=(-f sha="${shas[$i]}")
    i=$((i + 1))
    if ! gh api "${args[@]}" >/dev/null; then
      echo "  could not write $WORKFLOW_DIR/$f on $BRANCH; branch left for inspection" >&2
      return 1
    fi
  done
  body="$(mktemp)"
  cat >"$body" <<'EOF'
Adds or updates the Codex review workflows from jckeen/dotfiles (`.github/workflows/codex-review.yml` and `codex-findings.yml`, copied verbatim by `claude/scripts/fleet-codex-review.sh`). Only files that differ from the canonical copy are in this PR.

`codex-review` posts a `codex-review` commit status on each PR: pending while the GitHub Codex bot reviews, success once its summary table reads Completed. Docs-only and Dependabot PRs pass at once. A review counts only for the PR's head commit: a later push gets an `@codex review` request and holds until that review completes. If the bot never picks a PR up at all, the status passes after three minutes. A `codex-skip` label applied by an admin or maintainer passes it by hand.

`codex-findings` labels a PR `codex-findings` while the bot has review threads on it that nobody has resolved, so `gh pr list --label codex-findings` lists the PRs waiting on bot findings.

Nothing requires the status until the follow-up `codex-review` ruleset is created after this merges; this PR on its own changes no merge behavior.

Revert: `git revert <merge sha>` (delete the `codex-review` ruleset first if it was created).
EOF
  if ! pr="$(gh pr create -R "$repo" --base "$base" --head "$BRANCH" \
    --title "ci: Codex review workflows from jckeen/dotfiles" --body-file "$body")"; then
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
  if [[ "$wf" == *unreadable* ]]; then
    echo "  workflow=$wf; cannot read the workflows, skipping" >&2
    rc=1
    continue
  fi
  if ! rs="$(ruleset_id "$repo")"; then
    echo "  cannot read rulesets, skipping" >&2
    rc=1
    continue
  fi
  if enforced "$repo"; then want=enforce; else want=advisory; fi
  echo "  workflow=$wf ruleset=${rs:-none} mode=$want"
  [ "$mode" = apply ] || continue
  if [ "$wf" != current ] && [ "$repo" = jckeen/dotfiles ]; then
    # The canonical copy lands here through dotfiles' own reviewed PR.
    echo "  workflow lands through the dotfiles PR; nothing to do here"
  elif [ "$wf" != current ]; then
    ship_workflow "$repo" "$base" "$wf" || rc=1
  elif [ "$want" = enforce ] && [ -z "$rs" ]; then
    if create_ruleset "$repo"; then
      # PRs opened before the workflow landed have no status yet and may see
      # no further event: evaluate every open PR now.
      if gh workflow run codex-review.yml -R "$repo" --ref "$base" >/dev/null; then
        echo "  started an evaluation of every open PR"
      else
        echo "  could not start codex-review; run it by hand (gh workflow run codex-review.yml -R $repo)" >&2
        rc=1
      fi
    else
      rc=1
    fi
  else
    echo "  nothing to do"
  fi
done
exit "$rc"
