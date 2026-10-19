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
new_repo
w CHANGELOG.md "# Changelog" "" "Unreleased entries: changelog.d/." "" "## 2026-10-01 — fix: old" "- o"
w changelog.d/x.md "## 2026-10-02 — feat: new" "- n"
run
expect_file "preamble: entries go after it, before the first entry" CHANGELOG.md \
  "# Changelog" "" "Unreleased entries: changelog.d/." "" \
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
malformed "text before heading" "content before the first ## heading" "intro" "## 2026-10-05 — feat: x" "- b"
malformed "H1 inside" "must be" "## 2026-10-05 — feat: x" "- b" "# Changelog"
malformed "empty" "no \"## YYYY-MM-DD" ""
malformed "unclosed fence" "code fence" "## 2026-10-05 — feat: x" "- b" '```'
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

# A heading quoted inside a fenced example in CHANGELOG.md is not a folded entry.
new_repo
w CHANGELOG.md "# Changelog" "" "## 2026-10-01 — docs: example" "- e.g.:" '  ```' "## 2026-10-05 — feat: x" '  ```'
w changelog.d/x.md "## 2026-10-05 — feat: x" "- b"
run --check
expect "duplicate: a fenced heading in CHANGELOG.md does not count" 0 "1 fragment(s)"
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

# ── Date order holds across existing sections ─────────────────────────
# Each entry goes above the first existing entry dated on or before it, so a
# fragment older than the current head lands in date order, not on top.
new_repo
w CHANGELOG.md "# Changelog" "" "## 2026-10-18 — fix: newest existing" "- n" "" "## 2026-10-01 — fix: oldest existing" "- o"
w changelog.d/top.md "## 2026-10-20 — feat: newer than all" "- t"
w changelog.d/mid.md "## 2026-10-05 — feat: between" "- m"
w changelog.d/same.md "## 2026-10-18 — feat: same day as head" "- s"
w changelog.d/old.md "## 2026-09-01 — feat: older than all" "- a"
run
expect "order: assemble succeeds" 0 "folded 4 entries"
expect_file "order: every entry lands in date order" CHANGELOG.md \
  "# Changelog" "" \
  "## 2026-10-20 — feat: newer than all" "- t" "" \
  "## 2026-10-18 — feat: same day as head" "- s" "" \
  "## 2026-10-18 — fix: newest existing" "- n" "" \
  "## 2026-10-05 — feat: between" "- m" "" \
  "## 2026-10-01 — fix: oldest existing" "- o" "" \
  "## 2026-09-01 — feat: older than all" "- a"
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

# ── Strict line grammar: no fences; every # line is an entry or ### ────
# Fragments are a line-oriented format, not CommonMark: no code fences at all,
# and any line starting (after any indentation) with # must be exactly a valid
# `## ` entry heading or a `### ` subsection, both at column 0, with no tabs.
malformed "fence \`\`\`" "code fence" "## 2026-10-05 — feat: x" "- b" '```' "## not a heading" '```'
malformed "fence ~~~" "code fence" "## 2026-10-05 — feat: x" "- b" '~~~'
malformed "indented fence" "code fence" "## 2026-10-05 — feat: x" "- b" '   ````'
malformed "tab after ## (gate repro)" "tab" "## 2026-10-05 — feat: x" "- b" "$(printf '##\t2026-10-19 — docs: later')" "- c"
malformed "tab after #" "tab" "## 2026-10-05 — feat: x" "- b" "$(printf '#\tTitle')"
malformed "tab in heading text" "tab" "$(printf '## 2026-10-05 — feat: x\ty')" "- b"
malformed "two spaces after ##" "heading must be" "##  2026-10-05 — feat: x" "- b"
malformed "indented ##" "must be" "## 2026-10-05 — feat: x" "- b" "  ## 2026-10-06 — feat: y" "- c"
malformed "4-space ##" "must be" "## 2026-10-05 — feat: x" "- b" "    ## code-looking"
malformed "indented #" "must be" "## 2026-10-05 — feat: x" "- b" "   # Title"
malformed "####" "must be" "## 2026-10-05 — feat: x" "- b" "#### deep"
malformed "#word at line start" "must be" "## 2026-10-05 — feat: x" "- b" "  #626 continued"
malformed "4-space bullet" "no bullet" "## 2026-10-05 — feat: x" "" "    - code, not a list item"
# Gate repros: a commented-out newer heading was sorted into view (and the
# closing --> moved above the <!--); an unclosed <!-- hid later entries.
malformed "balanced HTML comment" "HTML comment" "## 2026-10-05 — feat: x" "- b" "<!--" "## 2026-10-20 — feat: hidden" "- c" "-->"
malformed "unclosed HTML comment" "HTML comment" "## 2026-10-05 — feat: x" "- b" "<!-- open"
new_repo
w changelog.d/ok.md "## 2026-10-05 — feat: x" "" "### What changed" "" "   - three spaces is still a bullet" "- inline \`code\` is fine"
run
expect "grammar: ### subsections, 3-space bullets and inline code pass" 0 "folded 1 entry"
rm -rf "$R"

# ── CHANGELOG.md side: fences only locate insertion points ─────────────
# An open fence at the end of CHANGELOG.md would swallow appended entries
# (gate repro: an older pending entry rendered as code).
new_repo
w CHANGELOG.md "# Changelog" "" "## 2026-10-10 — fix: x" "- e.g.:" '  ```' "  still code"
w changelog.d/old.md "## 2026-10-01 — feat: older" "- b"
run --check
expect "changelog: --check refuses an open fence at the end of CHANGELOG.md" 1 "ends inside an open code fence"
run
expect "changelog: assemble refuses it too" 1 "ends inside an open code fence"
[ -e "$R/changelog.d/old.md" ] && ok "changelog: the fragment is kept" || bad "changelog: the fragment is kept"
rm -rf "$R"
new_repo
w CHANGELOG.md "# Changelog" "" "$(printf '##\t2026-10-10 — fix: tabbed')" "- b"
run --check
expect "changelog: a tab in a ## heading of CHANGELOG.md is refused" 1 "tab"
rm -rf "$R"
# Gate repro: loose headings render but are no insertion point, so an
# October 5 fragment landed below October 1.
for loose in " ## 2026-10-01 — fix: indented" "##  2026-10-01 — fix: two spaces"; do
  new_repo
  w CHANGELOG.md "# Changelog" "" "$loose" "- b"
  w changelog.d/new.md "## 2026-10-05 — feat: newer" "- b"
  run --check
  expect "changelog: --check refuses loose heading '$loose'" 1 "strict form"
  run
  expect "changelog: assemble refuses loose heading '$loose'" 1 "strict form"
  [ -e "$R/changelog.d/new.md" ] && ok "changelog: fragment kept for '$loose'" || bad "changelog: fragment kept for '$loose'"
  rm -rf "$R"
done

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
