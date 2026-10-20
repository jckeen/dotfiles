## 2026-10-19 — fix: run-tests shows progress, and the fuzz suite no longer depends on TMPDIR

- **`claude/scripts/run-tests.sh`** (#650): without `--verbose` a full run
  used to print nothing for about 17 minutes, and agents killed it as hung.
  Each suite's `PASS`/`FAIL` row now prints as the suite finishes. A suite
  that is still running prints `… still running: NAME (Ns)` every
  `RUN_TESTS_HEARTBEAT` seconds (default 30). The final summary is unchanged.
  The heartbeat's `sleep` writes to `/dev/null`, so it cannot hold a caller's
  pipe open, and an EXIT trap stops the heartbeat if the runner dies.
- **`setup.sh --dry-run` mutated a `$HOME` outside `/tmp`** (#621, root
  cause): the dry-run printed `codex --version`. In Codex 0.163, every
  invocation creates `$CODEX_HOME/tmp/arg0-linux/` helper links. It skips
  that only when `CODEX_HOME` sits under the system temp dir, which is `/tmp`
  under the fuzz suite's `env -i`. So `setup-fuzz-layouts` passed with
  `TMPDIR` under `/tmp` and failed 25 of 26 layouts with "mutated $HOME" under
  `/var/tmp` or `~/.cache`. The "unsupported destination type" lines in that
  output are expected refusals for symlinked fixtures, not the failure. The
  dry-run now skips the codex version probe, as it already skipped
  `codex login status`. A new `setup-dry-run` case puts a recording `codex`
  stub on `PATH` and asserts the dry-run never calls it, whether or not the
  host has Codex installed.
- **Git discovery is confined per suite** (#621): `run-tests.sh` runs every
  suite with `GIT_CEILING_DIRECTORIES` extended by the resolved `/tmp`,
  `/var/tmp` and `$TMPDIR`, never the repo root itself. A temp root that has
  become a repository, such as the `/tmp/.git` mount point Codex's sandbox
  creates (#368), can no longer be discovered from a fixture. An empty
  `/tmp/.git` never confused `git` itself; it tripped `worktree-lifecycle`'s
  own ancestor walk, and #623 already moved those fixtures to a clean root.
- **`--changed` treats changelog fragments as test-free**: a changed
  `changelog.d/*.md` selects no suite and no longer widens the run to every
  suite, and a diff of only fragments runs none. No other Markdown is exempt.
- `run-tests.test.sh` gains cases for the progress order, the heartbeat, the
  interval validation, the ceiling, and fragment-only and fragment-plus-script
  diffs.
