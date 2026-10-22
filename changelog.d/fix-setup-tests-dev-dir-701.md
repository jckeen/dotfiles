## 2026-10-22 — fix(setup): setup test suites no longer find the real claude-memory (#701)

- **setup.sh**: honours `DOTFILES_DEV_DIR` (absolute path) before deriving the
  dev directory from the checkout's parent. A relative value is refused.
- **Test suites**: `setup-services`, `setup-dry-run` and `setup-fuzz-layouts`
  point it at a directory under their own test root, so a checkout directly
  under `~/dev` no longer runs the operator's real `claude-memory/bootstrap.sh`
  against a throwaway `HOME`. `settings-example` never runs `setup.sh`, so it
  needed no change.
- **New guard test**: `setup-dev-dir-isolation` plants a sibling
  `claude-memory` bootstrap, proves it is found without the override and not
  found with it, and checks each suite sets the override before running
  `setup.sh`.
