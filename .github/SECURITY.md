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

Use GitHub's private vulnerability reporting:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Provide a clear description, reproduction steps, affected files, and (if
   possible) a suggested fix.

If the button is ever missing (the feature was turned off), fall back to
opening a GitHub issue titled `security: request private contact` containing
**no vulnerability details**; the maintainer will respond with a private
channel.

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
