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

# ── A ## line inside a code fence is content, not a new entry ─────────
new_repo
w changelog.d/fenced.md "## 2026-10-03 — docs: fenced" "- see:" "  \`\`\`" "## not a heading" "# nor this" "  \`\`\`"
run --check
expect "fence: ## and # inside a fence are content" 0 "1 fragment(s)"
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
malformed "no bullet" "no bullet" "## 2026-10-05 — feat: x" "" "prose only"
malformed "text before heading" "content before the first ## heading" "intro" "## 2026-10-05 — feat: x" "- b"
malformed "H1 inside" "top-level" "## 2026-10-05 — feat: x" "- b" "# Changelog"
malformed "empty" "no \"## YYYY-MM-DD" ""
malformed "unclosed fence" "unclosed code fence" "## 2026-10-05 — feat: x" "- b" '```'
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

# A fragment whose entry is already in CHANGELOG.md was folded once already.
new_repo
w changelog.d/dup.md "## 2026-10-01 — fix: an old entry" "- old bullet"
run
expect "duplicate: an already-assembled entry is refused" 1 "already in CHANGELOG.md"
rm -rf "$R"

# ── PR scope (--base/--branch): one fragment, named after the branch ──
new_repo
git -C "$R" switch -q -c feat/one-thing
w changelog.d/feat-one-thing.md "## 2026-10-06 — feat: one thing" "- b"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: one"
run --check --base main --branch feat/one-thing
expect "scope: one fragment named after the branch passes" 0 "1 fragment(s)"
run --check --base main --branch feat/other
expect "scope: a fragment not named after the branch is refused" 1 "expected 'changelog.d/feat-other.md'"
w changelog.d/feat-second.md "## 2026-10-06 — feat: second" "- b"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: two"
run --check --base main
expect "scope: two fragments added by one branch are refused" 1 "adds 2 fragments"
run --check --base no-such-ref
expect "scope: an unresolvable base fails closed" 1 "is not a commit here"
rm -rf "$R"

# ── Usage errors ──────────────────────────────────────────────────────
new_repo
run --bogus
expect "usage: unknown argument exits 2" 2 "unknown argument"
run --check --branch x
expect "usage: --branch without --base exits 2" 2 "only applies with --base"
run --base main
expect "usage: --base without --check exits 2" 2 "only applies with --check"
rm -rf "$R"

echo ""
echo "assemble-changelog: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
