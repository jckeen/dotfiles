## 2026-10-20 — fix(gates): the Antigravity review cannot write outside a throwaway home (#687)

- **`--mode plan --sandbox` did not stop file writes the user's baseline
  allows.** The installed agy permissions allow `write_file(~/dev/)` under
  `proceed-in-sandbox`, and plan mode honours that rule. A live probe with
  the gate's exact flags on agy 1.4.2 wrote a file under `~/dev` from a
  prompt. A steered review could therefore write into any repository there.
  A write into the reviewed tree was caught by `verify --snapshot`; a write
  anywhere else was not.
- **agy now runs with a private HOME and workspace.** The gate builds a
  0700 temp directory per run. It holds a linked credential, a copied
  installation id and a settings file with no allow rules and
  `write_file(/)` denied. The workspace is a `git archive` extract of the
  reviewed HEAD, with no `.git` leading back. A `~/` rule now resolves
  inside the throwaway directory, which is removed on exit and before a
  re-raised signal. A jail that cannot be built degrades the lane instead
  of running against the real home.
- **Proved live.** In the throwaway home the same probe was refused ("denied
  by a configured deny rule for `write_file`"), including writes inside its
  own workspace. A full gate run on a prompt-injection diff still parsed a
  P0 verdict and wrote nothing. The suite's stub agy records the
  environment it gets and attempts writes into its workspace and `~/dev`;
  neither reaches the repository or the user's home.
- **The workspace is its own empty repository.** agy finds `.agents/`,
  `GEMINI.md` and `AGENTS.md` by walking up to the folder that holds `.git`;
  an extract with none would send that walk into the shared temp directory,
  where a planted `GEMINI.md` could steer the verdict. `git init` in the
  workspace stops the walk there, with no remote back to the reviewed repo.
  The init and agy itself run with git's routing variables (`GIT_DIR`,
  `GIT_WORK_TREE` and the rest) cleared, and a workspace without a real
  `.git` directory fails the jail build.
