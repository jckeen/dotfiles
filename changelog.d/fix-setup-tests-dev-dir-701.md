## 2026-11-20 — fix(setup): setup test suites and checkers honour DOTFILES_DEV_DIR (#701)

- **lib-checks.sh**: adds `dotfiles_dev_dir` so `setup.sh` and the three runtime checkers (`check-claude.sh`, `check-codex.sh`, `check-antigravity.sh`) honour an absolute, single-line `DOTFILES_DEV_DIR` (trimming trailing slashes while keeping `/`) before falling back to the checkout parent.
- **setup.sh & health checkers**: route `claude-memory`, `codex-memory`, `agy-memory`, and `agy-memory/permissions.local.json` through `dotfiles_dev_dir` while preserving explicit `CODEX_MEMORY_REPO` and `AGY_MEMORY_REPO` overrides.
- **Test suites**: `setup-services`, `setup-dry-run`, and `setup-fuzz-layouts` isolate `DOTFILES_DEV_DIR` under their test roots with behavioral guard assertions against fake planted siblings and host sibling paths.
