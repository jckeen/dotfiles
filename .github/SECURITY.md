# Security Policy

## Supported Versions

Only the latest `main` branch is supported. There is no LTS, no backports, and
no patched older tags. If you are running an older snapshot of this repo,
update before reporting.

| Version | Supported          |
| ------- | ------------------ |
| `main`  | :white_check_mark: |
| anything else | :x:          |

## Reporting a Vulnerability

**Do not post vulnerability details in a public GitHub issue.**

GitHub's private vulnerability reporting is not currently enabled on this
repository, so the Security tab has no "Report a vulnerability" button. To
report privately today:

1. Open a GitHub issue titled `security: request private contact` containing
   **no vulnerability details** — just a note that you have something to
   report.
2. The maintainer will respond with a private channel.
3. Once a channel exists, provide a clear description, reproduction steps,
   affected files, and (if possible) a suggested fix.

If the **Report a vulnerability** button appears under the repository's
**Security** tab (i.e. private vulnerability reporting has since been
enabled), prefer that flow instead — it skips the contact-request step.

You should expect an initial acknowledgment within a few days. Fix timelines
depend on severity and on the maintainer's capacity — this is a personal
dotfiles repository, not a funded product.

## Out of Scope

This repo bootstraps third-party CLIs. Vulnerabilities in those tools belong
upstream, not here:

- Claude Code (Anthropic)
- Codex CLI (OpenAI)
- `gh` (GitHub CLI)
- Homebrew (`brew`)
- `npm`, `bun`, and any package they install
- system shells, `git`, `curl`, `jq`, etc.

In-scope issues include: command injection in our own scripts, unsafe
`eval`/`source` of untrusted input, secrets handling, file-permission issues
in installed artifacts, and hook scripts that escalate access.

## Acknowledgments

Reporters who follow responsible disclosure will be credited in `CHANGELOG.md`
unless they request anonymity.
