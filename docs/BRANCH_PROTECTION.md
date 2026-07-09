# Branch Protection Setup

This doc records the protection rules for `main`. Apply them once, then
re-apply if GitHub resets anything or you spin up a fork.

> **Requires repo admin access.** `gh auth status` must show admin scope on
> `jckeen/dotfiles`.

## What we want on `main`

1. Require a pull request before merging
2. Require **1 approving review**
3. Require status checks to pass: `shellcheck`, `tsc`, `doc-truth`
4. Require branches to be up to date before merging
5. Require **signed commits**
6. Block force pushes
7. Block direct pushes (everything goes through a PR)
8. Include administrators (no bypass)

## Apply via `gh api`

Save this as the JSON body. The structure is the GitHub Branch Protection
API contract — every nullable field must be present, even if `null`.

```bash
cat > /tmp/main-protection.json <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["shellcheck", "tsc", "doc-truth"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1,
    "require_last_push_approval": false
  },
  "required_signatures": true,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": true
}
JSON

gh api \
  -X PUT \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  repos/jckeen/dotfiles/branches/main/protection \
  --input /tmp/main-protection.json
```

Signed-commit enforcement is a separate sub-resource on some accounts:

```bash
gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  repos/jckeen/dotfiles/branches/main/protection/required_signatures
```

## Verify

```bash
gh api repos/jckeen/dotfiles/branches/main/protection | jq '{
  reviews: .required_pull_request_reviews.required_approving_review_count,
  checks: .required_status_checks.contexts,
  signed: .required_signatures.enabled,
  force_push: .allow_force_pushes.enabled,
  admins: .enforce_admins.enabled
}'
```

Expected output:

```json
{
  "reviews": 1,
  "checks": ["shellcheck", "tsc", "doc-truth"],
  "signed": true,
  "force_push": false,
  "admins": true
}
```

## Notes

- The status-check contexts (`shellcheck`, `tsc`, `doc-truth`) must match the **job names**
  in `.github/workflows/ci.yml`. If you rename a job, update both this doc and
  the protection rule.
- These three are deliberately the **only** protection-required checks. The
  remaining CI jobs — `checks` (which bundles the doc-refs, no-personal-data,
  agent-parity, skill-parity, and install-integrity steps), `secret-scan`, and
  `commit-format`, plus the `smoke-install` workflow — run on every PR but are
  **advisory**: a failure shows red on the PR and should be fixed, but branch
  protection does not block the merge on them.
- `required_signatures: true` rejects unsigned commits at the server. Configure
  `git config --global commit.gpgsign true` and `gpg.format ssh` (or GPG) on
  every machine that pushes to `main`.
- To temporarily relax for a one-off rescue: `gh api -X DELETE repos/jckeen/dotfiles/branches/main/protection`,
  do the work, then re-apply this file. Don't leave it off.
