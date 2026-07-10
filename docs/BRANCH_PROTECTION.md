# Branch Protection Setup

This doc records the protection rules for `main`. Apply them once, then
re-apply if GitHub resets anything or you spin up a fork.

> **Requires repo admin access.** `gh auth status` must show admin scope on
> `jckeen/dotfiles`.

## What we want on `main`

1. Require a pull request before merging
2. Require **1 approving review**
3. Require status checks to pass: `shellcheck`, `tsc`, `doc-truth`,
   `agentpack-generated`, and the two `smoke-install` matrix jobs
   (`setup.sh syntax + --help (ubuntu-latest)` and
   `setup.sh syntax + --help (macos-latest)`)
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
    "contexts": [
      "shellcheck",
      "tsc",
      "doc-truth",
      "agentpack-generated",
      "setup.sh syntax + --help (ubuntu-latest)",
      "setup.sh syntax + --help (macos-latest)"
    ]
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
  "checks": ["shellcheck", "tsc", "doc-truth", "agentpack-generated", "setup.sh syntax + --help (ubuntu-latest)", "setup.sh syntax + --help (macos-latest)"],
  "signed": true,
  "force_push": false,
  "admins": true
}
```

> **Pending operator action (#203, #237):** the live rule may still list only
> the original three contexts — agents cannot edit branch protection. To flip
> the `smoke-install` jobs and `agentpack-generated` to required without
> re-applying the whole rule (one call covers both):
>
> ```bash
> cat > /tmp/required-checks.json <<'JSON'
> {
>   "strict": true,
>   "contexts": [
>     "shellcheck",
>     "tsc",
>     "doc-truth",
>     "agentpack-generated",
>     "setup.sh syntax + --help (ubuntu-latest)",
>     "setup.sh syntax + --help (macos-latest)"
>   ]
> }
> JSON
> gh api -X PATCH \
>   repos/jckeen/dotfiles/branches/main/protection/required_status_checks \
>   --input /tmp/required-checks.json
> ```
>
> `agentpack-generated` must exist as a job on `main` before the PATCH (it
> does once the PR for #237 merges — a context that never reports leaves
> every PR stuck on "Expected"). Delete this callout once `Verify` above
> shows all six contexts.

## Notes

- The status-check contexts must match the **job names**: `shellcheck`, `tsc`,
  `doc-truth`, and `agentpack-generated` live in `.github/workflows/ci.yml`;
  the two `setup.sh syntax + --help (...)` contexts are the matrix jobs of
  `.github/workflows/smoke-install.yml`. If you rename a job, update both this
  doc and the protection rule.
- `smoke-install` is gating as of 2026-07 (#203): its `continue-on-error` was
  removed, and it always runs (no `paths:` filter — a first step skips the real
  work when no smoke-relevant file changed) so it can be protection-required
  without non-matching PRs hanging on "Expected".
- `agentpack-generated` (`gen-agentpack.sh --check`) has no `paths:` filter,
  so it reports on every PR and is safe to require (#237) — a manifest-stale
  PR that edits `claude/skills/*/SKILL.md` or `claude/agents/*.md` without
  regenerating `claude/AGENTPACK.yaml` is blocked at merge, not noticed after.
- The remaining CI jobs — `checks` (which bundles the doc-refs,
  no-personal-data, agent-parity, skill-parity, install-integrity, and gate
  self-test steps), `secret-scan`, and `commit-format` — run on every PR but
  are **advisory**: a failure shows red on the PR and should be fixed, but
  branch protection does not block the merge on them.
- `required_signatures: true` rejects unsigned commits at the server. Configure
  `git config --global commit.gpgsign true` and `gpg.format ssh` (or GPG) on
  every machine that pushes to `main`.
- To temporarily relax for a one-off rescue: `gh api -X DELETE repos/jckeen/dotfiles/branches/main/protection`,
  do the work, then re-apply this file. Don't leave it off.
