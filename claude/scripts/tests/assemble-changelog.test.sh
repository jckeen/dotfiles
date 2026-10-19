#!/usr/bin/env bash
# assemble-changelog.test.sh — fixture tests for assemble-changelog.sh (#626).
# The script is check-only (its fold mode was removed in #661; the name is
# historical). Builds throwaway git repos under mktemp, runs the REAL script in
# them, and asserts exit code, an output fragment, and that nothing was
# written. Run directly; exit 1 on any failure. Mirrors doc-truth.test.sh.
set -uo pipefail

resolve_script_path() {
  local target="$1" dir
  while [[ -L "$target" ]]; do
    dir="$(cd -P "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    [[ "$target" != /* ]] && target="$dir/$target"
  done
  cd -P "$(dirname "$target")" && pwd
}
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
SCRIPT="$SCRIPT_DIR/../assemble-changelog.sh"

pass=0
failed=0
R=""
OUT=""
RC=0

new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name test
  git -C "$R" config commit.gpgsign false
  w CHANGELOG.md "# Changelog" "" "## 2026-10-01 — fix: an old entry" "" "- old bullet"
  git -C "$R" add -A
  git -C "$R" commit -q -m "chore: init"
}

# w <repo-relative path> <line>...  — write a file, one arg per line
w() {
  local p="$R/$1"
  shift
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" >"$p"
}

# tree_sum — every path and its checksum under $R, .git excluded, so a test
# can assert the script wrote, renamed and deleted nothing.
tree_sum() {
  (cd "$R" && find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do
    if [ -f "$f" ] && [ -r "$f" ]; then printf '%s %s\n' "$f" "$(cksum <"$f")"; else printf '%s\n' "$f"; fi
  done)
}

# run <args...> — runs the script and asserts it left the tree untouched.
run() {
  local before
  before="$(tree_sum)"
  OUT="$(cd "$R" && "$SCRIPT" "$@" 2>&1)"
  RC=$?
  if [ "$before" != "$(tree_sum)" ]; then
    bad "never writes: '$*' changed the tree" "$OUT"
  fi
}

ok() {
  pass=$((pass + 1))
  echo "ok   - $1"
}
bad() {
  failed=$((failed + 1))
  echo "FAIL - $1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      | /'
}

# expect <name> <rc> [<output fragment>]
expect() {
  local name="$1" want="$2" frag="${3:-}"
  if [ "$RC" -ne "$want" ]; then
    bad "$name (want rc=$want, got rc=$RC)" "$OUT"
  elif [ -n "$frag" ] && ! grep -qF -- "$frag" <<<"$OUT"; then
    bad "$name (output lacks '$frag')" "$OUT"
  else
    ok "$name"
  fi
}

# The only text allowed above CHANGELOG.md's first ## line: the pointer lines.
# shellcheck disable=SC2016  # literal backticks
P1='Entries not yet folded in live one per PR in `changelog.d/`; they are'
# shellcheck disable=SC2016
P2='copied here by hand at release time (see `claude/scripts/README.md`).'

# ── Two branches' fragments merge with no conflict and both pass ──────
new_repo
git -C "$R" switch -q -c feat/alpha
w changelog.d/feat-alpha.md "## 2026-10-17 — feat: alpha lands" "" "- alpha bullet"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: alpha"
git -C "$R" switch -q main
git -C "$R" switch -q -c fix/beta
w changelog.d/fix-beta.md "## 2026-10-18 — fix(scope): beta lands" "" "- beta bullet" "  continued"
git -C "$R" add -A && git -C "$R" commit -q -m "fix: beta"
git -C "$R" switch -q main
if git -C "$R" merge -q --no-edit feat/alpha >/dev/null 2>&1 \
  && git -C "$R" merge -q --no-edit fix/beta >/dev/null 2>&1; then
  ok "two branches' fragments merge without conflict"
else
  bad "two branches' fragments merge without conflict" "$(git -C "$R" status --short)"
fi
run --check
expect "check: two well-formed fragments pass" 0 "2 fragment(s) well-formed"
rm -rf "$R"

# ── The fold mode is gone: no flags prints usage and exits 2 ──────────
new_repo
w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
run
expect "usage: no flags prints usage and exits 2" 2 "--check"
rm -rf "$R"

# ── No changelog.d/ at all is a clean check ───────────────────────────
new_repo
run --check
expect "no fragments: --check passes" 0 "0 fragment(s)"
rm -rf "$R"

# Real calendar dates: Feb 29 only in a leap year.
new_repo
w changelog.d/leap.md "## 2028-02-29 — docs: leap day" "- b"
run --check
expect "date: 2028-02-29 is valid" 0 "1 fragment(s)"
rm -rf "$R"

# ── Allowed shapes pass ────────────────────────────────────────────────
new_repo
w changelog.d/ok.md "## 2026-10-05 — feat: x" "" "### What changed" "" "   - three spaces is still a bullet" "- inline \`code\` is fine" "  continued, with <tags> and | pipes mid-line" "    - nested bullet" "" "## 2026-10-04 — fix(scope)!: y" "* star bullet"
run --check
expect "grammar: subsections, bullets, continuations, inline code and several entries pass" 0 "1 fragment(s)"
rm -rf "$R"

# ── Malformed fragments are refused (and nothing is written) ──────────
malformed() { # <name> <expected output fragment> <fragment line>...
  local name="$1" frag="$2"
  shift 2
  new_repo
  w changelog.d/good.md "## 2026-10-05 — feat: good" "- fine"
  w changelog.d/bad.md "$@"
  run --check
  expect "malformed ($name): --check refuses" 1 "$frag"
  rm -rf "$R"
}
L="a line must be"
malformed "no type" "heading must be" "## 2026-10-05 — something happened" "- b"
malformed "unknown type" "heading must be" "## 2026-10-05 — feature: x" "- b"
malformed "hyphen not em dash" "heading must be" "## 2026-10-05 - feat: x" "- b"
malformed "bad date" "invalid date" "## 2026-13-05 — feat: x" "- b"
malformed "Feb 30" "invalid date" "## 2026-02-30 — feat: x" "- b"
malformed "Feb 29 off leap year" "invalid date" "## 2026-02-29 — feat: x" "- b"
malformed "Apr 31" "invalid date" "## 2026-04-31 — feat: x" "- b"
malformed "no bullet" "no bullet" "## 2026-10-05 — feat: x" "" "prose only"
malformed "text before heading" "content before the first ## heading" "- intro" "## 2026-10-05 — feat: x" "- b"
malformed "H1 inside" "a line must be" "## 2026-10-05 — feat: x" "- b" "# Changelog"
malformed "empty" "no \"## YYYY-MM-DD" ""
malformed "unclosed fence" "comment or fence marker" "## 2026-10-05 — feat: x" "- b" '```'
malformed "CRLF" "CRLF" "$(printf '## 2026-10-05 — feat: x\r')" "- b"
malformed "fence \`\`\`" "comment or fence marker" "## 2026-10-05 — feat: x" "- b" '```' "## not a heading" '```'
malformed "fence ~~~" "comment or fence marker" "## 2026-10-05 — feat: x" "- b" '~~~'
malformed "indented fence" "comment or fence marker" "## 2026-10-05 — feat: x" "- b" '   ````'
malformed "continuation fence" "comment or fence marker" "## 2026-10-05 — feat: x" "- b" '  ```'
malformed "tab after ## (gate repro)" "$L" "## 2026-10-05 — feat: x" "- b" "$(printf '##\t2026-10-19 — docs: later')" "- c"
malformed "tab after #" "$L" "## 2026-10-05 — feat: x" "- b" "$(printf '#\tTitle')"
malformed "tab in heading text" "tab" "$(printf '## 2026-10-05 — feat: x\ty')" "- b"
malformed "two spaces after ##" "heading must be" "##  2026-10-05 — feat: x" "- b"
malformed "indented ##" "$L" "## 2026-10-05 — feat: x" "- b" "  ## 2026-10-06 — feat: y" "- c"
malformed "4-space ##" "$L" "## 2026-10-05 — feat: x" "- b" "    ## code-looking"
malformed "indented #" "$L" "## 2026-10-05 — feat: x" "- b" "   # Title"
malformed "####" "$L" "## 2026-10-05 — feat: x" "- b" "#### deep"
malformed "#word at line start" "$L" "## 2026-10-05 — feat: x" "- b" "  #626 continued"
malformed "4-space bullet" "no bullet" "## 2026-10-05 — feat: x" "" "    - code, not a list item"
malformed "balanced HTML comment" "comment or fence marker" "## 2026-10-05 — feat: x" "- b" "<!--" "## 2026-10-20 — feat: hidden" "- c" "-->"
malformed "unclosed HTML comment" "comment or fence marker" "## 2026-10-05 — feat: x" "- b" "<!-- open"
malformed "balanced <pre>" "$L" "## 2026-10-05 — feat: x" "- b" "<pre>" "## 2026-10-20 — feat: hidden" "- c" "</pre>"
malformed "unclosed <pre>" "$L" "## 2026-10-05 — feat: x" "- b" "<pre>"
malformed "bullet opening <pre>" "$L" "## 2026-10-05 — feat: x" "- <pre>"
malformed "continuation opening an HTML block" "$L" "## 2026-10-05 — feat: x" "- b" "  <div>"
malformed "setext === underline" "$L" "## 2026-10-05 — feat: x" "- b" "  ==="
malformed "setext --- underline" "$L" "## 2026-10-05 — feat: x" "- b" "  ---"
malformed "thematic break bullet" "$L" "## 2026-10-05 — feat: x" "- b" "* * *"
malformed "blockquote" "$L" "## 2026-10-05 — feat: x" "- b" "> quoted"
malformed "indented blockquote" "$L" "## 2026-10-05 — feat: x" "- b" "  > quoted"
malformed "table row" "$L" "## 2026-10-05 — feat: x" "- b" "  | a | b |"
malformed "plain column-0 text" "$L" "## 2026-10-05 — feat: x" "- b" "lazy continuation"
malformed "empty bullet" "$L" "## 2026-10-05 — feat: x" "- b" "- "
malformed "+ bullet" "$L" "## 2026-10-05 — feat: x" "+ plus"
malformed "nested list comment" "comment or fence marker" "## 2026-10-05 — feat: x" "- - <!--"
malformed "deeper nested comment" "comment or fence marker" "## 2026-10-05 — feat: x" "- * - <!--"
malformed "tab-prefixed comment" "comment or fence marker" "## 2026-10-05 — feat: x" "$(printf -- '- \t<!--')"
malformed "comment mid-line" "comment or fence marker" "## 2026-10-05 — feat: x" "- text <!-- hidden"
malformed "comment closer" "comment or fence marker" "## 2026-10-05 — feat: x" "- b" "  done -->"
malformed "inline triple backtick" "comment or fence marker" "## 2026-10-05 — feat: x" "- uses \`\`\` inline"
malformed "inline ~~~" "comment or fence marker" "## 2026-10-05 — feat: x" "- uses ~~~ inline"
malformed "nested <pre>" "$L" "## 2026-10-05 — feat: x" "- - <pre>"
malformed "ordered-list <pre>" "$L" "## 2026-10-05 — feat: x" "- b" "  1. <pre>"
malformed "bullet ordered-list <pre>" "$L" "## 2026-10-05 — feat: x" "- 1) <pre>"
malformed "quoted <pre>" "$L" "## 2026-10-05 — feat: x" "- > <pre>"
malformed "tab-nested <pre>" "$L" "## 2026-10-05 — feat: x" "$(printf -- '- \t+ <pre>')"
malformed "nested heading" "$L" "## 2026-10-05 — feat: x" "- - ## 2026-10-20 — feat: y"
malformed "table delimiter without pipes" "$L" "## 2026-10-05 — feat: x" "- b" "  name | value" "  --- | ---" "  one | two"
malformed "table delimiter with colons" "$L" "## 2026-10-05 — feat: x" "- b" "  :--- | ---:"
malformed "rule after nested marker" "$L" "## 2026-10-05 — feat: x" "- b" "- - ---"

# ── Non-fragment files and unreadable or symlinked inputs ──────────────
new_repo
w changelog.d/notes.txt "hello"
run --check
expect "files: a non-.md file in changelog.d/ is refused" 1 "not a .md fragment"
rm -rf "$R"
new_repo
w "changelog.d/has space.md" "## 2026-10-05 — feat: x" "- b"
run --check
expect "files: a fragment name that is not a slug is refused" 1 "fragment name must be"
rm -rf "$R"
new_repo
w "changelog.d/..hidden.md" "## 2026-10-05 — feat: x" "- b"
run --check
expect "files: a double-dot file in changelog.d/ is seen and refused" 1 "fragment name must be"
rm -rf "$R"

# Root reads anything, so the unreadable cases are meaningless there.
if [ "$(id -u)" -ne 0 ]; then
  new_repo
  w changelog.d/locked.md "## 2026-10-05 — feat: x" "- b"
  chmod 000 "$R/changelog.d/locked.md"
  run --check
  expect "unreadable: an unreadable fragment is refused" 1 "could not be read"
  chmod 644 "$R/changelog.d/locked.md"
  rm -rf "$R"
  new_repo
  w changelog.d/bad.md "not a fragment"
  chmod 000 "$R/changelog.d"
  OUT="$(cd "$R" && "$SCRIPT" --check 2>&1)"
  RC=$?
  expect "unreadable: an unreadable changelog.d/ is refused" 1 "is not readable"
  chmod 755 "$R/changelog.d"
  rm -rf "$R"
fi

new_repo
outside="$(mktemp -d)"
printf '%s\n' "## 2026-10-05 — feat: x" "- b" >"$outside/x.md"
ln -s "$outside" "$R/changelog.d"
run --check
expect "symlink: a symlinked changelog.d/ is refused" 1 "is a symlink"
rm -rf "$outside" "$R"
new_repo
real="$(mktemp)"
cp "$R/CHANGELOG.md" "$real"
rm -f "$R/CHANGELOG.md"
ln -s "$real" "$R/CHANGELOG.md"
run --check
expect "symlink: a symlinked CHANGELOG.md is refused" 1 "is a symlink"
rm -f "$real"
rm -rf "$R"

# ── Duplicate headings ─────────────────────────────────────────────────
# Already in CHANGELOG.md, as an exact line anywhere (a false match only
# refuses, which is safe): the fragment was folded once and survived.
new_repo
w changelog.d/dup.md "## 2026-10-01 — fix: an old entry" "- old bullet"
run --check
expect "duplicate: an already-folded entry is refused" 1 "already in CHANGELOG.md"
rm -rf "$R"
new_repo
w CHANGELOG.md "# Changelog" "" "## 2026-10-01 — docs: example" "- e.g.:" "" '```' "## 2026-10-05 — feat: x" '```'
w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
run --check
expect "duplicate: a heading quoted anywhere in CHANGELOG.md refuses" 1 "already in CHANGELOG.md"
rm -rf "$R"
# The match at the top of a long history: an early grep -q exit must still
# count as a hit (no SIGPIPE-turned-miss).
new_repo
{
  printf '%s\n' "# Changelog" "" "## 2026-10-09 — fix: early match" "- b"
  for n in $(seq 1 3000); do printf '%s\n' "" "## 2026-01-01 — chore: filler $n" "- f"; done
} >"$R/CHANGELOG.md"
w changelog.d/dup.md "## 2026-10-09 — fix: early match" "- b"
run --check
expect "duplicate: an early match in a long changelog is refused" 1 "already in CHANGELOG.md"
rm -rf "$R"
# Among pending fragments, in two files or one.
new_repo
w changelog.d/one.md "## 2026-10-06 — feat: same title" "- a"
w changelog.d/two.md "## 2026-10-06 — feat: same title" "- b"
run --check
expect "duplicate: the same heading in two fragments is refused" 1 "also in changelog.d/one.md"
rm -rf "$R"
new_repo
w changelog.d/one.md "## 2026-10-06 — feat: twice" "- a" "" "## 2026-10-06 — feat: twice" "- b"
run --check
expect "duplicate: the same heading twice in one fragment is refused" 1 "repeated"
rm -rf "$R"

# ── CHANGELOG.md: preconditions and the exact preamble allowlist ───────
new_repo
rm -f "$R/CHANGELOG.md"
w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
run --check
expect "precondition: a missing CHANGELOG.md is refused" 1 "CHANGELOG.md not found"
rm -rf "$R"
new_repo
w CHANGELOG.md "" "# Changelog" "" "## 2026-10-01 — fix: old" "- o"
w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
run --check
expect "precondition: a title that is not line 1 is refused" 1 "must start with a '# ' title line"
rm -rf "$R"
new_repo
w CHANGELOG.md "## 2026-10-01 — fix: old" "- o"
w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
run --check
expect "precondition: a missing title line is refused" 1 "exactly one"
rm -rf "$R"
new_repo
w CHANGELOG.md "# Changelog" "" "$P1" "$P2" "" "## 2026-10-01 — fix: old" "- o"
w changelog.d/x.md "## 2026-10-02 — feat: new" "- n"
run --check
expect "preamble: the pointer lines, blanks and one title pass" 0 "1 fragment(s)"
rm -rf "$R"
new_repo
w CHANGELOG.md "# Changelog" "" "$P1" "$P2"
w changelog.d/x.md "## 2026-10-02 — feat: new" "- n"
run --check
expect "preamble: a changelog with no entries yet passes" 0 "1 fragment(s)"
rm -rf "$R"
preamble_refused() { # <name> <line>
  new_repo
  w CHANGELOG.md "# Changelog" "" "$2" "## 2026-10-01 — fix: hidden" "-->" "" "## 2026-09-01 — fix: x" "- b"
  w changelog.d/new.md "## 2026-10-05 — feat: newer" "- b"
  run --check
  expect "preamble ($1): refused" 1 "above the first ## entry"
  rm -rf "$R"
}

preamble_refused "HTML comment" "<!--"
preamble_refused "fence" '```'
preamble_refused "tilde fence" '~~~'
preamble_refused "blockquote" "> note"
preamble_refused "table" "| a |"
preamble_refused "indented heading" "  ## 2026-10-02 — fix: loose"
preamble_refused "list-prefixed comment" "- <!--"
preamble_refused "plain text" "Some note."
preamble_refused "second title" "# Another title"
preamble_refused "pointer line with extra text" "$P1 more"

# ── PR scope (--base) ──────────────────────────────────────────────────
# One added fragment, any valid name: <branch-slug>.md is a convention, not
# enforced, because distinct branches can share a slug.
new_repo
git -C "$R" switch -q -c feat/one-thing
w changelog.d/any-name-at-all.md "## 2026-10-06 — feat: one thing" "- b"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: one"
run --check --base main
expect "scope: one fragment with any valid name passes" 0 "1 fragment(s)"
w changelog.d/feat-second.md "## 2026-10-06 — feat: second" "- b"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: two"
run --check --base main
expect "scope: two fragments added by one branch are refused" 1 "adds 2 fragments"
run --check --base no-such-ref
expect "scope: an unresolvable base fails closed" 1 "is not a commit here"
rm -rf "$R"
# No modifying or renaming another PR's pending fragment, and no CHANGELOG.md
# entry alongside a new fragment. The fold PR (fragments deleted, entries
# added) passes.
new_repo
w changelog.d/theirs.md "## 2026-10-04 — fix: theirs" "- t"
git -C "$R" add -A && git -C "$R" commit -q -m "fix: theirs"
git -C "$R" switch -q -c feat/edit-theirs
w changelog.d/theirs.md "## 2026-10-04 — fix: theirs" "- t" "- edited by someone else"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: edit"
run --check --base main
expect "scope: modifying a pending fragment from the base is refused" 1 "modifies or renames"
git -C "$R" switch -q main
git -C "$R" switch -q -c feat/rename-theirs
git -C "$R" mv changelog.d/theirs.md changelog.d/mine.md
git -C "$R" commit -q -m "feat: rename"
run --check --base main
expect "scope: renaming a pending fragment from the base is refused" 1 "modifies or renames"
git -C "$R" switch -q main
git -C "$R" switch -q -c docs/fold
w CHANGELOG.md "# Changelog" "" "## 2026-10-04 — fix: theirs" "- t" "" "## 2026-10-01 — fix: an old entry" "" "- old bullet"
git -C "$R" rm -q changelog.d/theirs.md
git -C "$R" add -A && git -C "$R" commit -q -m "docs: fold changelog fragments"
run --check --base main
expect "scope: a fold PR (fragments removed, entries added) passes" 0 "0 fragment(s)"
git -C "$R" switch -q main
git -C "$R" switch -q -c feat/both
w changelog.d/feat-both.md "## 2026-10-06 — feat: both" "- b"
w CHANGELOG.md "# Changelog" "" "## 2026-10-06 — feat: also prepended" "- p" "" "## 2026-10-01 — fix: an old entry" "" "- old bullet"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: both"
run --check --base main
expect "scope: adding a fragment and a CHANGELOG.md entry is refused" 1 "also adds an entry to CHANGELOG.md"
rm -rf "$R"

# ── Usage errors ──────────────────────────────────────────────────────
new_repo
run --bogus
expect "usage: unknown argument exits 2" 2 "unknown argument"
run --check --branch x
expect "usage: --branch is gone" 2 "unknown argument"
run --base main
expect "usage: --base without --check exits 2" 2 "only applies with --check"
rm -rf "$R"

echo ""
echo "assemble-changelog: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
