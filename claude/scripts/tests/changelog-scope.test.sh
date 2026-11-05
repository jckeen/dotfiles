#!/usr/bin/env bash
# changelog-scope.test.sh — the ci.yml "Changelog fragments (PR scope)" step.
# Extracts the step's `run:` block from .github/workflows/ci.yml (so the test
# runs the shell CI runs, not a copy that can drift), builds a fixture repo
# under mktemp with a base commit holding CHANGELOG.md and one fragment, and
# runs the step against one commit per case with BASE_SHA set to the base.
# Fixture git config is hostile on purpose (colour always, noprefix, renames
# on): the rule reads `--name-status -z` and must not notice. Exit 1 on any
# failure.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_YML="$SCRIPT_DIR/../../../.github/workflows/ci.yml"
pass=0; failed=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export RUNNER_TEMP="$T/runner"; mkdir -p "$RUNNER_TEMP"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# The step body: lines of the `run: |` block that follows the step's name,
# de-indented by the block's own indent, up to the next key at that indent.
awk '
  /^      - name: Changelog fragments \(PR scope\)$/ { in_step = 1; next }
  in_step && /^        run: \|$/ { in_run = 1; next }
  in_run {
    if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print; next }
    exit
  }
' "$CI_YML" >"$T/step.sh"
if [ ! -s "$T/step.sh" ] || ! grep -q 'name-status' "$T/step.sh"; then
  echo "FAIL - could not extract the PR scope step from ci.yml"; exit 1
fi
if ! bash -n "$T/step.sh"; then echo "FAIL - extracted step does not parse"; exit 1; fi

git init -q "$T/repo"; cd "$T/repo" || exit 1
git config color.ui always; git config color.diff always; git config diff.noprefix true; git config diff.renames true
# shellcheck disable=SC2016
printf '# Changelog\n\nEntries not yet folded in live one per PR in `changelog.d/`; they are\ncopied here by hand at release time (see `claude/scripts/README.md`).\n\n## 2026-10-01 — fix: old\n\n- old\n- theirs\n' >CHANGELOG.md
mkdir changelog.d
printf '## 2026-10-20 — fix: theirs\n\n- theirs\n' >changelog.d/theirs.md
printf '## 2026-10-19 — fix: other\n\n- other\n' >changelog.d/other.md
git add -A && git commit -qm base
BASE_SHA="$(git rev-parse HEAD)"; export BASE_SHA

# case <name> <pass|fail> <shell snippet run in the fixture>
case_() {
  local name="$1" expect="$2" snippet="$3" got
  git checkout -q -f -B case "$BASE_SHA" && git clean -fdq
  bash -c "$snippet" >/dev/null 2>&1
  git add -A >/dev/null 2>&1 && git commit -qm "$name" --allow-empty
  if bash "$T/step.sh" >"$T/out" 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$expect" ]; then pass=$((pass + 1)); echo "ok   - $name ($got)"
  else failed=$((failed + 1)); echo "FAIL - $name: expected $expect, got $got"; sed 's/^/     | /' "$T/out"; fi
}

case_ "one added fragment" pass 'printf "## 2026-10-22 — fix: mine\n\n- mine\n" > changelog.d/mine.md'
case_ "unrelated change, no fragment" pass 'echo x > code.sh'
case_ "CHANGELOG.md edit with no fragment (archive move)" pass 'printf "\n- [2026 Q3](docs/changelog/x.md)\n" >> CHANGELOG.md'
case_ "fold: every base fragment removed and every entry copied in" pass 'rm changelog.d/theirs.md changelog.d/other.md; printf "## 2026-10-20 — fix: theirs\n\n- theirs\n\n## 2026-10-19 — fix: other\n\n- other\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold that keeps a .gitkeep" pass 'rm changelog.d/theirs.md changelog.d/other.md; : > changelog.d/.gitkeep; printf "## 2026-10-20 — fix: theirs\n\n- theirs\n\n## 2026-10-19 — fix: other\n\n- other\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fragment beside an added .gitkeep" pass ': > changelog.d/.gitkeep; echo "## m" > changelog.d/mine.md'
case_ "fragment whose name holds a newline" pass 'printf "## m\n" > "changelog.d/a
b.md"'
case_ "two added fragments" fail 'echo "## x" > changelog.d/a.md; echo "## y" > changelog.d/b.md'
case_ "two fragments, one with a newline in its name" fail 'printf "## m\n" > "changelog.d/a
b.md"; echo "## y" > changelog.d/c.md'
case_ "two fragments, one with a quote in its name" fail 'echo "## m" > changelog.d/mine.md; echo "## y" > "changelog.d/q\"uote.md"'
case_ "modifies a base fragment" fail 'echo "- more" >> changelog.d/theirs.md'
case_ "mode change on a base fragment" fail 'chmod +x changelog.d/theirs.md'
case_ "base fragment retyped to a symlink" fail 'rm changelog.d/theirs.md; ln -s ../CHANGELOG.md changelog.d/theirs.md'
case_ "deletes a base fragment alone" fail 'rm changelog.d/theirs.md'
case_ "deletes a base fragment and adds its own" fail 'rm changelog.d/theirs.md; echo "## m" > changelog.d/mine.md'
case_ "renames a base fragment" fail 'git mv changelog.d/theirs.md changelog.d/renamed.md'
case_ "rewrites a base fragment under a new name" fail 'git mv changelog.d/theirs.md changelog.d/renamed.md; echo x >> changelog.d/renamed.md'
case_ "deletes one base fragment beside a token CHANGELOG.md edit" fail 'rm changelog.d/theirs.md; echo >> CHANGELOG.md'
case_ "fake fold: every fragment removed, one blank line added" fail 'rm changelog.d/theirs.md changelog.d/other.md; echo >> CHANGELOG.md'
case_ "half fold: every fragment removed, one entry copied" fail 'rm changelog.d/theirs.md changelog.d/other.md; printf "## 2026-10-20 — fix: theirs\n\n- theirs\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold that copies the headings but drops every bullet" fail 'rm changelog.d/theirs.md changelog.d/other.md; printf "## 2026-10-20 — fix: theirs\n\n## 2026-10-19 — fix: other\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold whose copied bullet differs by a byte" fail 'rm changelog.d/theirs.md changelog.d/other.md; printf "## 2026-10-20 — fix: theirs\n\n- theirs!\n\n## 2026-10-19 — fix: other\n\n- other\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold that omits a bullet an older entry happens to share" fail 'rm changelog.d/theirs.md changelog.d/other.md; printf "## 2026-10-20 — fix: theirs\n\n## 2026-10-19 — fix: other\n\n- other\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold that hides the copied fragments in an HTML comment" fail 'rm changelog.d/theirs.md changelog.d/other.md; printf "<!--\n## 2026-10-20 — fix: theirs\n\n- theirs\n\n## 2026-10-19 — fix: other\n\n- other\n-->\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold that also edits an older entry" fail 'rm changelog.d/theirs.md changelog.d/other.md; printf "## 2026-10-20 — fix: theirs\n\n- theirs\n\n## 2026-10-19 — fix: other\n\n- other\n\n" | cat - CHANGELOG.md | sed "s/^- old$/- old, edited/" > c && mv c CHANGELOG.md'
case_ "fold that interleaves two fragments' lines" fail 'rm changelog.d/theirs.md changelog.d/other.md; printf "## 2026-10-20 — fix: theirs\n\n## 2026-10-19 — fix: other\n\n- theirs\n\n- other\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold that inserts the fragments between an older heading and its bullets" fail 'rm changelog.d/theirs.md changelog.d/other.md; awk '"'"'{print} /^## 2026-10-01/{print ""; printf "## 2026-10-20 — fix: theirs\n\n- theirs\n\n## 2026-10-19 — fix: other\n\n- other\n"}'"'"' CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold placed directly above the first existing entry" pass 'rm changelog.d/theirs.md changelog.d/other.md; awk '"'"'/^## 2026-10-01/{printf "## 2026-10-20 — fix: theirs\n\n- theirs\n\n## 2026-10-19 — fix: other\n\n- other\n\n"} {print}'"'"' CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold whose copied heading differs by a byte" fail 'rm changelog.d/theirs.md changelog.d/other.md; printf "## 2026-10-20 — fix: theirs!\n\n- theirs\n\n## 2026-10-19 — fix: other\n\n- other\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'

# A fragment may hold several dated entries, and a fold orders every entry
# newest first, so one fragment's entries can straddle another's. A new base
# adds such a fragment; the cases below run against it.
git checkout -q -f -B base2 "$BASE_SHA" && git clean -fdq
printf '## 2026-10-21 — fix: multi-new\n\n- newer\n\n## 2026-10-18 — fix: multi-old\n\n- older\n' >changelog.d/multi.md
git add -A && git commit -qm "base with a two-entry fragment"
BASE_SHA="$(git rev-parse HEAD)"; export BASE_SHA
RM_ALL='rm changelog.d/theirs.md changelog.d/other.md changelog.d/multi.md'
case_ "fold of a two-entry fragment, every entry newest first" pass "$RM_ALL"'; printf "## 2026-10-21 — fix: multi-new\n\n- newer\n\n## 2026-10-20 — fix: theirs\n\n- theirs\n\n## 2026-10-19 — fix: other\n\n- other\n\n## 2026-10-18 — fix: multi-old\n\n- older\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold that keeps fragments whole and so breaks date order" fail "$RM_ALL"'; printf "## 2026-10-20 — fix: theirs\n\n- theirs\n\n## 2026-10-19 — fix: other\n\n- other\n\n## 2026-10-21 — fix: multi-new\n\n- newer\n\n## 2026-10-18 — fix: multi-old\n\n- older\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold that splits an entry around another" fail "$RM_ALL"'; printf "## 2026-10-21 — fix: multi-new\n\n## 2026-10-20 — fix: theirs\n\n- theirs\n\n- newer\n\n## 2026-10-19 — fix: other\n\n- other\n\n## 2026-10-18 — fix: multi-old\n\n- older\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fold that drops one entry of a two-entry fragment" fail "$RM_ALL"'; printf "## 2026-10-21 — fix: multi-new\n\n- newer\n\n## 2026-10-20 — fix: theirs\n\n- theirs\n\n## 2026-10-19 — fix: other\n\n- other\n\n" | cat - CHANGELOG.md > c && mv c CHANGELOG.md'
case_ "fragment plus a direct ## entry" fail 'echo "## m" > changelog.d/mine.md; printf "\n## 2026-10-22 — fix: direct\n\n- d\n" >> CHANGELOG.md'
case_ "fragment plus an entry grep would call binary" fail 'echo "## m" > changelog.d/mine.md; printf "\n## 2026-10-22 — fix: direct \xff\n" >> CHANGELOG.md'
case_ "fragment plus a NUL byte in CHANGELOG.md" fail 'echo "## m" > changelog.d/mine.md; printf "\0\n## 2026-10-22 — fix: direct\n" >> CHANGELOG.md'
case_ "fragment plus an indented heading" fail 'echo "## m" > changelog.d/mine.md; printf "\n  ## 2026-10-22 — fix: direct\n" >> CHANGELOG.md'
case_ "fragment plus a setext heading" fail 'echo "## m" > changelog.d/mine.md; printf "\n2026-10-22 — fix: direct\n---\n" >> CHANGELOG.md'
case_ "fragment plus CRLF CHANGELOG.md" fail 'echo "## m" > changelog.d/mine.md; sed -i "s/\$/\r/" CHANGELOG.md'
case_ "fragment plus CHANGELOG.md deleted" fail 'echo "## m" > changelog.d/mine.md; git rm -q CHANGELOG.md'

# A bad base SHA must fail the step, not pass it.
git checkout -q -f -B case "$BASE_SHA"
if BASE_SHA=0000000000000000000000000000000000000000 bash "$T/step.sh" >"$T/out" 2>&1; then
  failed=$((failed + 1)); echo "FAIL - unknown base SHA passed the step"
else pass=$((pass + 1)); echo "ok   - unknown base SHA fails the step"; fi

echo; echo "changelog-scope: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
