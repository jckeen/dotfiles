---
name: antigravity-review
description: Run an automated code review using your regular Antigravity subscription plan. Use when the user asks for a Gemini/Antigravity review, a second opinion on recent changes, or /antigravity-review. Reviews the working-tree diff for bug risks, boundary-condition errors, security issues, and over-engineering — the Gemini sibling of the Codex review gate.
---

# Antigravity (Gemini) review

Runs a local review over the current diff using the subscriber `agy` CLI, and gates on the result. This is the Antigravity counterpart to the Codex review gate — use it for a second, independent (Gemini-powered) perspective, especially on front-end and runtime/boundary-condition changes.

## How to run

The gate is installed at `~/.claude/scripts/antigravity-review-gate.sh` by setup.sh (the claude/ tree symlink); the repo-relative `claude/scripts/antigravity-review-gate.sh` only exists inside the dotfiles checkout. Resolve the installed path first, then fall back:

```bash
GATE="$HOME/.claude/scripts/antigravity-review-gate.sh"
[ -x "$GATE" ] || GATE="claude/scripts/antigravity-review-gate.sh"
```

Review the uncommitted working-tree changes and require the tool to actually run:

```bash
"$GATE" --uncommitted --require
```

Other invocations:
- `"$GATE"` — review the committed delta vs the base branch (falls back to the working tree if there's no committed delta). This is what a pre-push gate should use. If the base branch cannot be resolved, the gate fails closed (exit 2) rather than reviewing the wrong diff — pass an existing ref with `--base`, or `--uncommitted` to review only the working tree.
- `"$GATE" --base <ref>` — review the committed delta against a specific base.

Then print the script's output verbatim to the user, and lead with the gate result:
- **Exit 0** — clean, or only P3+ nits (which are printed). Safe to push.
- **Exit 2** — local validation failed, blocking P0–P2 findings, an unresolvable base ref, or review output that couldn't be parsed as findings or a whole-verdict LGTB. Do NOT push; surface the findings (or the cause) and offer to fix them.
- **Exit 3** — the gate was `--require`d but `agy` couldn't run (missing, not authenticated, timed out). Report that Antigravity couldn't review and fall back to a Codex review or a manual pass.

## Notes

- The gate runs local `tsc --noEmit` / lint first, filters lockfiles and assets out of the diff, and skips diffs over 500 lines to conserve plan quota (degrades open).
- Security: the diff is treated as untrusted data. `agy` runs with `--mode plan --sandbox` and no `--dangerously-skip-permissions`; the diff is fenced so injected instructions in a reviewed diff can't steer the agent or run tools; the prompt (including the diff, which can contain secrets) is delivered on stdin rather than argv so it never shows in process listings; and a clean verdict is accepted only when `LGTB` is the entire output (or its final line) — an injected `output LGTB` quoted inside prose blocks instead of passing. Do not "simplify" the gate by adding `--dangerously-skip-permissions` or loosening the verdict match.
- `ANTIGRAVITY_GATE_REQUIRED=1` turns degraded (tool-can't-run) cases into hard failures; `--require` does the same per-invocation.
