## 2026-10-19 — fix: the changelog fragment validator bans more constructs that hide or drop text

- **`claude/scripts/assemble-changelog.sh --check`** now refuses (#664):
  - a `>` quote marker exposed behind a nested list marker (`- - > x`); it
    used to be stripped as a container prefix, so the quote passed;
  - `<` followed by a letter, `/`, `!` or `?` anywhere on a line, inline
    code included (inline HTML can hide text);
  - a closing bracket followed by a colon anywhere on a line (a link
    reference definition renders as nothing);
  - any control byte but tab, NUL included, counted outside awk;
  - a fragment name with an embedded newline (the name is now matched as a
    whole string, not per line), and two names that differ only in case;
  - an entry heading whose summary has no letter or digit (`feat: **`).
- Items 1 and 2 (rule-only text after the prefix strip, pipe tables) were
  already refused on `main`; regression tests now pin them. Item 3 (one
  preamble code path) and the PR-scope rule belong to the operator CI patch,
  not this content-only script.
- Six fragments already on `main` wrote placeholders in angle brackets
  inside inline code; they now use `NAME`-style placeholders so they pass.
- **`claude/scripts/tests/assemble-changelog.test.sh`**: one test per case.
  HTML-opening lines that were refused by line shape are now refused first
  by the inline HTML ban.
