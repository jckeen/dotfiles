## 2026-10-19 — docs: pause the Jules routine lane; add the two drifted plugins to the manifest

- **`docs/adr/0009-jules-routine-lane.md`**: Status changes from Accepted to
  Paused, with a dated status update. The lane never ran as decided: no timer,
  two manual dispatches, no weekly report, so the 30% merge-rate rule was never
  applied (#589, #446). The update states three restart criteria: the #639
  fixes (already met by #670), an installed timer plus a recorded first weekly report, and web-app
  PRs recorded in the same ledger. The PR-stage fallback in #606 is declined
  along with the lane. `agents/README.md`, `README.md` and
  `claude/scripts/README.md` no longer describe the timer as running.
- **`claude/plugins.txt`**: adds `frontend-design@anthropic-plugin-directory`
  ([global], already enabled) and `supabase@anthropic-plugin-directory`
  ([per-project], listing its Supabase projects). Both were installed but not
  in the manifest, which made PluginDriftCheck report reverse drift at every
  SessionStart. The Anthropic Directory marketplace is built into Claude Code,
  so `setup.sh` gets a no-op registration arm for it, which
  `check-install-integrity.sh` requires for every marketplace in the manifest.
- **`claude/systemd/install.sh`** enforces the pause. The Jules unit is
  installed only with `JULES_LANE_ENABLED=1`. Without it the unit is skipped,
  and a timer an earlier install enabled is disabled, so re-running setup can't
  restart the lane (Codex bot, #678). `setup.sh` no longer tells the user to
  enable the timer. `tests/jules-dispatch.test.sh` covers both paths.
- **`setup.sh`** also disables a `jules-dispatch.timer` that an earlier install
  enabled, unless `JULES_LANE_ENABLED=1`. The normal `dotfiles-update` path
  runs `setup.sh`, not the systemd installer, so the pause has to be enforced
  there too (Codex bot, #678). Under `--dry-run` this is only a preview.
