#!/usr/bin/env bash
# assemble-changelog.test.sh — fixture tests for assemble-changelog.sh (#626).
# Builds throwaway git repos under mktemp, runs the REAL script in them, and
# asserts exit code, an output fragment, and the resulting CHANGELOG.md bytes.
# Run directly; exit 1 on any failure. Mirrors doc-truth.test.sh.
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

run() {
  OUT="$(cd "$R" && "$SCRIPT" "$@" 2>&1)"
  RC=$?
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

# expect_file <name> <path> <line>...  — exact contents
expect_file() {
  local name="$1" path="$R/$2"
  shift 2
  local want got
  want="$(printf '%s\n' "$@")"
  got="$(cat "$path")"
  if [ "$want" = "$got" ]; then ok "$name"; else bad "$name" "$(diff <(printf '%s\n' "$want") "$path")"; fi
}

# ── Two branches' fragments merge with no conflict and fold in order ──
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
run
expect "assemble: folds both fragments" 0 "folded 2 entries from 2 fragment(s)"
expect_file "assemble: newest date first, above the existing head" CHANGELOG.md \
  "# Changelog" "" \
  "## 2026-10-18 — fix(scope): beta lands" "" "- beta bullet" "  continued" "" \
  "## 2026-10-17 — feat: alpha lands" "" "- alpha bullet" "" \
  "## 2026-10-01 — fix: an old entry" "" "- old bullet"
if [ ! -e "$R/changelog.d/feat-alpha.md" ] && [ ! -e "$R/changelog.d/fix-beta.md" ]; then
  ok "assemble: folded fragments are deleted"
else
  bad "assemble: folded fragments are deleted" "$(ls -la "$R/changelog.d")"
fi
before="$(cat "$R/CHANGELOG.md")"
run
expect "idempotent: a second run is a no-op" 0 "nothing to assemble"
[ "$before" = "$(cat "$R/CHANGELOG.md")" ] && ok "idempotent: CHANGELOG.md unchanged" \
  || bad "idempotent: CHANGELOG.md unchanged"
rm -rf "$R"

# ── No fragments (no changelog.d/ at all) is a no-op ─────────────────
new_repo
before="$(cat "$R/CHANGELOG.md")"
run
expect "no-op: no changelog.d/" 0 "nothing to assemble"
[ "$before" = "$(cat "$R/CHANGELOG.md")" ] && ok "no-op: CHANGELOG.md unchanged" \
  || bad "no-op: CHANGELOG.md unchanged"
run --check
expect "no-op: --check with no fragments passes" 0 "0 fragment(s)"
rm -rf "$R"

# ── Same date: tie-break by filename, then order within a fragment ────
new_repo
w changelog.d/b-two.md "## 2026-10-18 — docs: b first" "- b1" "" "## 2026-10-18 — docs: b second" "- b2"
w changelog.d/a-one.md "## 2026-10-18 — docs: a" "- a1"
run
expect "ties: assemble succeeds" 0
expect_file "ties: by filename, then position in the fragment" CHANGELOG.md \
  "# Changelog" "" \
  "## 2026-10-18 — docs: a" "- a1" "" \
  "## 2026-10-18 — docs: b first" "- b1" "" \
  "## 2026-10-18 — docs: b second" "- b2" "" \
  "## 2026-10-01 — fix: an old entry" "" "- old bullet"
rm -rf "$R"

# ── A preamble under the title stays above the folded entries ─────────
# The only text allowed above the first ## line is the script's own pointer.
P1='Entries not yet assembled live one per PR in `changelog.d/`, and'
P2='the script `claude/scripts/assemble-changelog.sh` inserts them here in assembly order.'
new_repo
w CHANGELOG.md "# Changelog" "" "$P1" "$P2" "" "## 2026-10-01 — fix: old" "- o"
w changelog.d/x.md "## 2026-10-02 — feat: new" "- n"
run
expect_file "preamble: entries go after it, before the first entry" CHANGELOG.md \
  "# Changelog" "" "$P1" "$P2" "" \
  "## 2026-10-02 — feat: new" "- n" "" \
  "## 2026-10-01 — fix: old" "- o"
rm -rf "$R"

# Real calendar dates: Feb 29 only in a leap year, no day 31 in a 30-day month.
new_repo
w changelog.d/leap.md "## 2028-02-29 — docs: leap day" "- b"
run --check
expect "date: 2028-02-29 is valid" 0 "1 fragment(s)"
rm -rf "$R"

# ── Malformed fragments are refused and nothing is written ────────────
malformed() { # <name> <expected output fragment> <fragment line>...
  local name="$1" frag="$2"
  shift 2
  new_repo
  w changelog.d/good.md "## 2026-10-05 — feat: good" "- fine"
  w changelog.d/bad.md "$@"
  local before
  before="$(cat "$R/CHANGELOG.md")"
  run --check
  expect "malformed ($name): --check refuses" 1 "$frag"
  run
  expect "malformed ($name): assemble refuses" 1 "Nothing was written"
  if [ "$before" = "$(cat "$R/CHANGELOG.md")" ] && [ -e "$R/changelog.d/good.md" ] && [ -e "$R/changelog.d/bad.md" ]; then
    ok "malformed ($name): CHANGELOG.md and fragments untouched"
  else
    bad "malformed ($name): CHANGELOG.md and fragments untouched"
  fi
  rm -rf "$R"
}
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

# Non-fragment files in changelog.d/ are refused too.
new_repo
w changelog.d/notes.txt "hello"
run --check
expect "malformed: a non-.md file in changelog.d/ is refused" 1 "not a .md fragment"
rm -rf "$R"
new_repo
w "changelog.d/has space.md" "## 2026-10-05 — feat: x" "- b"
run --check
expect "malformed: a fragment name that is not a slug is refused" 1 "fragment name must be"
rm -rf "$R"
new_repo
w "changelog.d/..hidden.md" "## 2026-10-05 — feat: x" "- b"
run --check
expect "malformed: a double-dot file in changelog.d/ is seen and refused" 1 "fragment name must be"
rm -rf "$R"

# An unreadable fragment is an error, never a clean report. (Root reads
# anything, so the case is meaningless there.)
if [ "$(id -u)" -ne 0 ]; then
  new_repo
  w changelog.d/locked.md "## 2026-10-05 — feat: x" "- b"
  chmod 000 "$R/changelog.d/locked.md"
  run --check
  expect "unreadable: --check refuses an unreadable fragment" 1 "could not be read"
  run
  expect "unreadable: assemble refuses an unreadable fragment" 1 "Nothing was written"
  chmod 644 "$R/changelog.d/locked.md"
  rm -rf "$R"
fi

# A planted staging-name symlink is never written through.
new_repo
victim="$(mktemp)"
echo "victim" >"$victim"
ln -s "$victim" "$R/CHANGELOG.md.assemble.tmp"
w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
run
expect "staging: assemble succeeds beside a planted symlink" 0 "folded 1 entry"
[ "$(cat "$victim")" = "victim" ] && [ ! -L "$R/CHANGELOG.md" ] \
  && grep -qF "feat: x" "$R/CHANGELOG.md" \
  && ok "staging: the symlink target is untouched and CHANGELOG.md is a real file" \
  || bad "staging: the symlink target is untouched and CHANGELOG.md is a real file"
rm -f "$victim"
rm -rf "$R"

# A symlinked changelog.d (fragments outside the root) is refused.
new_repo
outside="$(mktemp -d)"
printf '%s\n' "## 2026-10-05 — feat: x" "- b" >"$outside/x.md"
ln -s "$outside" "$R/changelog.d"
run
expect "symlink dir: assemble refuses a symlinked changelog.d" 1 "is a symlink"
[ -e "$outside/x.md" ] && ok "symlink dir: the outside fragment is not deleted" \
  || bad "symlink dir: the outside fragment is not deleted"
rm -rf "$outside" "$R"

# An unreadable changelog.d is an error, not an empty directory.
if [ "$(id -u)" -ne 0 ]; then
  new_repo
  w changelog.d/bad.md "not a fragment"
  chmod 000 "$R/changelog.d"
  run --check
  expect "unreadable dir: --check refuses" 1 "is not readable"
  chmod 755 "$R/changelog.d"
  rm -rf "$R"
fi

# The duplicate check is an exact match against ANY line of CHANGELOG.md, even
# one quoted in a fenced example: a false match only refuses, which is safe.
new_repo
w CHANGELOG.md "# Changelog" "" "## 2026-10-01 — docs: example" "- e.g.:" "" '```' "## 2026-10-05 — feat: x" '```'
w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
run --check
expect "duplicate: a heading quoted anywhere in CHANGELOG.md refuses" 1 "already in CHANGELOG.md"
rm -rf "$R"

# A fragment whose entry is already in CHANGELOG.md was folded once already.
new_repo
w changelog.d/dup.md "## 2026-10-01 — fix: an old entry" "- old bullet"
run
expect "duplicate: an already-assembled entry is refused" 1 "already in CHANGELOG.md"
rm -rf "$R"

# Same, with the match at the top of a long history: an early grep -q exit
# must still count as a hit (no SIGPIPE-turned-miss).
new_repo
{
  printf '%s\n' "# Changelog" "" "## 2026-10-09 — fix: early match" "- b"
  for n in $(seq 1 3000); do printf '%s\n' "" "## 2026-01-01 — chore: filler $n" "- f"; done
} >"$R/CHANGELOG.md"
w changelog.d/dup.md "## 2026-10-09 — fix: early match" "- b"
run --check
expect "duplicate: an early match in a long changelog is refused" 1 "already in CHANGELOG.md"
rm -rf "$R"

# ── PR scope (--base): at most one fragment added, any valid name ─────
# The <branch-slug>.md name is a convention, not enforced: distinct branches
# can share a slug (feat/a-b and feat-a/b), so the check never derives a
# filename from the branch.
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

# ── Top insertion: entries appear in assembly order ───────────────────
# All pending entries go immediately above CHANGELOG.md's first `## ` line,
# newest date first within this assembly; existing history is never reordered
# or parsed, so an entry older than the current head still lands on top.
new_repo
w CHANGELOG.md "# Changelog" "" "## 2026-10-18 — fix: newest existing" "- n" "" "## 2026-10-01 — fix: oldest existing" "- o"
w changelog.d/top.md "## 2026-10-20 — feat: newer than all" "- t"
w changelog.d/mid.md "## 2026-10-05 — feat: between" "- m"
w changelog.d/old.md "## 2026-09-01 — feat: older than all" "- a"
run
expect "order: assemble succeeds" 0 "folded 3 entries"
expect_file "order: all pending entries on top, newest first; history untouched" CHANGELOG.md \
  "# Changelog" "" \
  "## 2026-10-20 — feat: newer than all" "- t" "" \
  "## 2026-10-05 — feat: between" "- m" "" \
  "## 2026-09-01 — feat: older than all" "- a" "" \
  "## 2026-10-18 — fix: newest existing" "- n" "" \
  "## 2026-10-01 — fix: oldest existing" "- o"
rm -rf "$R"

# Below the first `## ` line nothing is parsed: an HTML comment or fence in
# old history cannot absorb the inserted entries, which sit above it.
new_repo
w CHANGELOG.md "# Changelog" "" "## 2026-10-01 — fix: a" "- a" "<!--" "## 2026-09-01 — fix: commented" "-->" '```'
w changelog.d/new.md "## 2026-10-05 — feat: new" "- n"
run
expect_file "order: markup in history is left alone, entries go above it" CHANGELOG.md \
  "# Changelog" "" \
  "## 2026-10-05 — feat: new" "- n" "" \
  "## 2026-10-01 — fix: a" "- a" "<!--" "## 2026-09-01 — fix: commented" "-->" '```'
rm -rf "$R"

# No `## ` line at all: the entries are appended after the preamble.
new_repo
w CHANGELOG.md "# Changelog" "" "$P1" "$P2"
w changelog.d/first.md "## 2026-10-05 — feat: first" "- f"
run
expect_file "order: a changelog with no entries gets them appended" CHANGELOG.md \
  "# Changelog" "" "$P1" "$P2" "" "## 2026-10-05 — feat: first" "- f"
rm -rf "$R"

# ── Duplicate headings among pending fragments ─────────────────────────
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

# ── Allowlisted line shapes; every old repro stays refused ────────────
# Each fragment line must be blank, an entry heading, a `### ` subsection, a
# bullet (indented 0-3), or a continuation (2+ spaces); bullet and
# continuation text may not open a block construct or be a rule.
L="a line must be"
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
# Gate repros: a commented-out newer heading was sorted into view (and the
# closing --> moved above the <!--); an unclosed <!-- hid later entries; a
# <pre> block did the same.
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
# Gate round-9 repros: a nested list marker hid a comment opener from the
# first-character rule. Comment and fence markers are now refused anywhere on
# a line, and every leading container prefix is stripped before that rule.
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
new_repo
w changelog.d/ok.md "## 2026-10-05 — feat: x" "" "### What changed" "" "   - three spaces is still a bullet" "- inline \`code\` is fine" "  continued, with <tags> and | pipes mid-line" "    - nested bullet"
run
expect "grammar: subsections, bullets, continuations and inline code pass" 0 "folded 1 entry"
rm -rf "$R"

# ── CHANGELOG.md: only the region above the first ## line is checked ──
# Gate repro: an HTML comment around a dated heading absorbed an inserted
# entry. Above the insertion point only titles, blanks and plain text pass.
preamble_refused() { # <name> <line>
  new_repo
  w CHANGELOG.md "# Changelog" "" "$2" "## 2026-10-01 — fix: hidden" "-->" "" "## 2026-09-01 — fix: x" "- b"
  w changelog.d/new.md "## 2026-10-05 — feat: newer" "- b"
  run --check
  expect "preamble ($1): --check refuses" 1 "above the first ## entry"
  run
  expect "preamble ($1): assemble refuses" 1 "Nothing was written"
  [ -e "$R/changelog.d/new.md" ] && ok "preamble ($1): fragment kept" || bad "preamble ($1): fragment kept"
  rm -rf "$R"
}
preamble_refused "HTML comment" "<!--"
preamble_refused "fence" '```'
preamble_refused "tilde fence" '~~~'
preamble_refused "blockquote" "> note"
preamble_refused "table" "| a |"
preamble_refused "indented heading" "  ## 2026-10-02 — fix: loose"
# Gate round-9 repro: a list-prefixed comment opener hid the inserted entries.
preamble_refused "list-prefixed comment" "- <!--"
# Exact allowlist: anything but the pointer lines is refused, however plain.
preamble_refused "plain text" "Some note."
preamble_refused "second title" "# Another title"
preamble_refused "pointer line with extra text" "$P1 more"
new_repo
w CHANGELOG.md "# Changelog" "" "$P1" "" "$P2" "" "## 2026-10-01 — fix: old" "- o"
w changelog.d/x.md "## 2026-10-02 — feat: new" "- n"
run --check
expect "preamble: the pointer lines, blanks and one title pass" 0 "1 fragment(s)"
rm -rf "$R"
new_repo
w CHANGELOG.md "" "## 2026-10-01 — fix: old" "- o"
w changelog.d/x.md "## 2026-10-02 — feat: new" "- n"
run --check
expect "preamble: a missing title line is refused" 1 "exactly one"
rm -rf "$R"

# ── Bot review round 2 (#661) ─────────────────────────────────────────
# A GFM table needs a delimiter row; refuse one with or without outer pipes,
# and rule-only text after a nested marker.
malformed "table delimiter without pipes" "$L" "## 2026-10-05 — feat: x" "- b" "  name | value" "  --- | ---" "  one | two"
malformed "table delimiter with colons" "$L" "## 2026-10-05 — feat: x" "- b" "  :--- | ---:"
malformed "rule after nested marker" "$L" "## 2026-10-05 — feat: x" "- b" "- - ---"

# --check now applies assembly's own preconditions: CHANGELOG.md must exist
# and its first line must be the title.
new_repo
rm -f "$R/CHANGELOG.md"
w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
run --check
expect "precondition: --check refuses a missing CHANGELOG.md" 1 "CHANGELOG.md not found"
rm -rf "$R"
new_repo
w CHANGELOG.md "" "# Changelog" "" "## 2026-10-01 — fix: old" "- o"
w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
run --check
expect "precondition: --check refuses a title that is not line 1" 1 "must start with a '# ' title line"
rm -rf "$R"

# Assembly checks it can delete every fragment before replacing CHANGELOG.md,
# so a failure never leaves the entries folded and the fragments behind.
if [ "$(id -u)" -ne 0 ]; then
  new_repo
  w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
  before="$(cat "$R/CHANGELOG.md")"
  chmod 555 "$R/changelog.d"
  run
  expect "delete preflight: an undeletable fragment refuses assembly" 1 "cannot delete"
  [ "$before" = "$(cat "$R/CHANGELOG.md")" ] && ok "delete preflight: CHANGELOG.md untouched" \
    || bad "delete preflight: CHANGELOG.md untouched"
  chmod 755 "$R/changelog.d"
  rm -rf "$R"
fi

# PR scope: a branch may not modify, rename or (outside assembly) touch
# another PR's pending fragment, nor prepend an entry to CHANGELOG.md while
# adding a fragment. Deleting fragments (the assembly PR) stays allowed.
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
git -C "$R" switch -q -c docs/assemble
run
git -C "$R" add -A && git -C "$R" commit -q -m "docs: assemble changelog fragments"
run --check --base main
expect "scope: an assembly PR (fragments deleted, entries added) passes" 0 "0 fragment(s)"
git -C "$R" switch -q main
git -C "$R" switch -q -c feat/both
w changelog.d/feat-both.md "## 2026-10-06 — feat: both" "- b"
w CHANGELOG.md "# Changelog" "" "## 2026-10-06 — feat: also prepended" "- p" "" "## 2026-10-01 — fix: an old entry" "" "- old bullet"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: both"
run --check --base main
expect "scope: adding a fragment and a CHANGELOG.md entry is refused" 1 "also adds an entry to CHANGELOG.md"
rm -rf "$R"

# Gate finding: when replacing CHANGELOG.md fails AND putting a fragment back
# fails, the held fragment must survive (it used to sit in a scratch dir the
# exit trap deleted). Fault injection: a PATH shim makes every mv that targets
# CHANGELOG.md or changelog.d/ fail, so the hold succeeds and both later
# steps fail.
new_repo
shim="$(mktemp -d)"
cat >"$shim/mv" <<'SHIM'
#!/usr/bin/env bash
last="${!#}"
case "$last" in
  CHANGELOG.md | changelog.d/) exit 1 ;;
esac
exec /bin/mv "$@"
SHIM
chmod +x "$shim/mv"
w changelog.d/precious.md "## 2026-10-05 — feat: precious" "- keep me"
before="$(cat "$R/CHANGELOG.md")"
OUT="$(cd "$R" && PATH="$shim:$PATH" "$SCRIPT" 2>&1)"
RC=$?
expect "rollback: a failed replace and a failed restore exit non-zero" 1 "kept in"
held="$(find "$R" -maxdepth 2 -name precious.md -path '*.assemble-held.*' | head -n 1)"
if [ -n "$held" ] && grep -qF "keep me" "$held" && [ "$before" = "$(cat "$R/CHANGELOG.md")" ]; then
  ok "rollback: the fragment survives in the holding dir; CHANGELOG.md unchanged"
else
  bad "rollback: the fragment survives in the holding dir; CHANGELOG.md unchanged" "$OUT"
fi
grep -qF "fragments are preserved in" <<<"$OUT" && ok "rollback: the holding path is printed" \
  || bad "rollback: the holding path is printed" "$OUT"
rm -rf "$shim" "$R"

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
