# Global Instructions

## Git Workflow (Auto-Commit Routine)
- Use conventional-style commit messages: `type: short description`
  - Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `style`
- **Commit automatically** after completing each meaningful unit of work — do not wait for the user to ask
  - A "meaningful unit" = a feature, fix, refactor, config change, or any coherent set of changes
  - Run the project's build/check command before committing to ensure nothing is broken; do not commit broken code
  - If the build fails, fix it first, then commit
- **Push periodically** — after every 2-3 commits, or when finishing a task
- Stage specific files rather than `git add -A` to avoid accidentally committing secrets or junk
- Do not commit `.env`, `*.db`, `node_modules/`, or other sensitive/generated files
