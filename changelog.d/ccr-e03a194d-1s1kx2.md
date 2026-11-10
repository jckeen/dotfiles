## 2026-11-10 — chore: retire the Jules lane and close the loops around the review and retro flow

### Removed

- **The Jules routine lane.** Jules was shut down, so ADR-0009 moves from
  Paused to Retired. Gone: `claude/scripts/jules-dispatch.sh` and its test
  suite, the `jules-dispatch` systemd unit pair, the `agents/routines/` catalog,
  the `jules` runtime and `routine-lane` capability in
  `agents/capabilities.json`, the Jules CLI install and login steps in
  `setup.sh`, and the CI step that ran the dispatcher's suite.
- `setup.sh` now disables a `jules-dispatch.timer` an earlier install left
  behind and removes its unit files, so no machine keeps firing a unit whose
  script is gone.

### Changed

- **The root `AGENTS.md` brief is the cloud-session brief.** Its source moves
  from `agents/canon/fragments/jules.md` to `fragments/cloud.md`, it names
  Claude Code and Codex cloud sessions, and it states that such a session has
  no global instruction file, skills, hooks or local review gates, so none of
  them may be reported as having run.
- **`.codex-review-ignore` declares the instruction text that is directive by
  design**: the three skill trees, `agents/canon/`, `claude/MULTI-AGENT.md` and
  `changelog.d/`. One skills change had produced eleven near-identical
  low-severity issues (#744 to #753 and #757), one per file. The exemption
  stays narrow by form (#484).
- **Closing keywords are repeated per issue.** Both `commit-push-pr` skills and
  `claude/MULTI-AGENT.md` now say that GitHub closes only the first number of a
  comma list after one `Closes`. Two merged pull requests (#743, #754) had left
  eleven fixed issues open that way; they are closed now.
- **Security fixes leave the weekly instruction-surface batch.**
  `claude/MULTI-AGENT.md` gives a security finding its own patch and branch as
  soon as it is reviewed.
- **The auth checklist and the Vercel log flags load on demand.** Two new
  Claude skills, `auth-boundary` and `vercel-logs`, hold the detail;
  `claude/CLAUDE.md` keeps the auth rule in one paragraph that points at the
  skill.
- `kickoff` no longer describes `CHANGELOG.md` as an end-of-session log, which
  contradicted the canon.
- `ROADMAP.md` reflects that the operator pass landed and only #615 remains.

### Added

- **`RetroProposalsReminder.hook.sh`** (#741): a SessionStart hook that prints
  one status line when `~/.claude/retro-proposals/` holds proposals newer than
  its `.last-reviewed` marker. It prints a count and a date, never proposal
  text. `/session-retro --review` walks the proposals and touches the marker.
  Registered in `claude/settings.example.json`; a private `settings.json` needs
  the same entry.
