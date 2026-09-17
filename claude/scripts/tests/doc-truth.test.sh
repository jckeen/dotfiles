#!/usr/bin/env bash
# doc-truth.test.sh — fixture tests for check-doc-truth.sh (no framework).
# Builds throwaway git repos under mktemp, runs the checker, asserts exit
# code + an output fragment. Run directly; exit 1 on any failure.
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
CHECKER="$SCRIPT_DIR/../check-doc-truth.sh"

pass=0
failed=0
R=""

new_repo() {
  R="$(mktemp -d)"
  git -C "$R" init -q
}

# w <repo-relative path> <line>...  — write a file, one arg per line
w() {
  local p="$R/$1"
  shift
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" > "$p"
}

# check-doc-truth.sh is vendored into other repos and holds to a bash 3.2
# floor — the macOS system bash (#424). Point DOC_TRUTH_BASH3 at a bash 3.2
# binary (or put `bash-3.2`/`bash3` on PATH) and EVERY fixture below runs the
# checker under it, so the failure paths — malformed contracts, banned hits,
# dead refs — get 3.2 coverage too, not just the happy path. CI's `doc-truth
# (bash 3.2)` job builds one and does exactly that.
#
# The interpreter is version-checked, not merely executable: pointing
# DOC_TRUTH_BASH3 at bash 5 would run everything under a shell that cannot
# reproduce the 3.2 traps and report a pass that proves nothing. An explicit
# DOC_TRUTH_BASH3 that is missing or is not bash 3.x is a FAILURE — asking for
# a 3.2 run must not degrade into a silent skip. An auto-discovered binary that
# turns out not to be bash 3.x just skips.
bash3_version() { # prints the version word, empty if the binary won't report one
  [[ -x "$1" ]] || return 1
  "$1" --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9.]*\).*/\1/p'
}

# check() runs the checker from inside the throwaway repo, so a relative or
# PATH-resolved interpreter would resolve against that directory and every
# case would die with 127. Resolve to an absolute path up front.
abs_path() {
  local d b
  d="$(dirname "$1")"
  b="$(basename "$1")"
  d="$(cd "$d" 2>/dev/null && pwd)" || return 1
  printf '%s/%s' "$d" "$b"
}

BASH3="${DOC_TRUTH_BASH3:-}"
BASH3_EXPLICIT=0
[[ -n "$BASH3" ]] && BASH3_EXPLICIT=1
if [[ -z "$BASH3" ]]; then
  BASH3="$(command -v bash-3.2 2>/dev/null || command -v bash3 2>/dev/null || true)"
fi
# A bare name goes through PATH first; command -v can itself hand back a
# relative path when PATH holds a relative entry, so normalize unconditionally
# afterwards rather than only on the non-PATH branch.
if [[ -n "$BASH3" && "$BASH3" != */* ]]; then
  BASH3="$(command -v "$BASH3" 2>/dev/null || true)"
fi
if [[ -n "$BASH3" && "$BASH3" != /* ]]; then
  BASH3="$(abs_path "$BASH3" || true)"
fi

BASH3_VER=""
[[ -n "$BASH3" ]] && BASH3_VER="$(bash3_version "$BASH3" || true)"

if [[ -n "$BASH3_VER" && "$BASH3_VER" != 3.* ]]; then
  if [[ "$BASH3_EXPLICIT" -eq 1 ]]; then
    echo "✖ DOC_TRUTH_BASH3=$BASH3 is bash $BASH3_VER, not 3.x — it cannot reproduce the 3.2 traps"
    failed=$((failed + 1))
  else
    echo "… running under the default bash ($BASH3 is bash $BASH3_VER, not 3.x)"
  fi
  BASH3=""
elif [[ "$BASH3_EXPLICIT" -eq 1 && -z "$BASH3_VER" ]]; then
  echo "✖ DOC_TRUTH_BASH3=${DOC_TRUTH_BASH3} is not an executable that reports a bash version"
  failed=$((failed + 1))
  BASH3=""
fi

# CHECKER_BASH, when non-empty, runs the checker under that interpreter rather
# than its shebang.
CHECKER_BASH=""
if [[ -n "$BASH3" && -n "$BASH3_VER" ]]; then
  CHECKER_BASH="$BASH3"
  echo "  (every fixture runs the checker under $("$BASH3" --version | head -n 1))"
else
  echo "  (fixtures run the checker under its shebang; set DOC_TRUTH_BASH3 for a bash 3.2 pass)"
fi

# check <name> <expected-exit> [<required output fragment>]
check() {
  local name="$1" want="$2" frag="${3:-}"
  git -C "$R" add -A >/dev/null 2>&1
  local out rc
  if [[ -n "$CHECKER_BASH" ]]; then
    out="$(cd "$R" && "$CHECKER_BASH" "$CHECKER" 2>&1)"
  else
    out="$(cd "$R" && "$CHECKER" 2>&1)"
  fi
  rc=$?
  if [[ "$rc" -ne "$want" ]]; then
    echo "✖ $name — expected exit $want, got $rc"
    echo "$out" | sed 's/^/    /'
    failed=$((failed + 1))
  elif [[ -n "$frag" ]] && ! grep -qF "$frag" <<<"$out"; then
    echo "✖ $name — output missing '$frag'"
    echo "$out" | sed 's/^/    /'
    failed=$((failed + 1))
  else
    echo "✓ $name"
    pass=$((pass + 1))
  fi
  rm -rf "$R"
}

# ── Cycle 1: parsing, coverage, stale entries ──────────────────────

new_repo
w .doc-contract 'LIVING README.md'
w README.md '# Hi'
check "declared file passes" 0 "doc-truth: OK"

new_repo
w .doc-contract '# comment line' '' 'LIVING README.md'
w README.md '# Hi'
check "comments and blanks ignored" 0 "doc-truth: OK"

new_repo
w .doc-contract 'LIVING README.md'
w README.md '# Hi'
w NOTES.md 'stray'
check "undeclared md fails coverage" 1 "coverage"

new_repo
w .doc-contract 'LIVING README.md' 'LIVING GONE.md'
w README.md '# Hi'
check "stale non-glob entry fails" 1 "stale-entry"

new_repo
w .doc-contract 'LIVING README.md' 'HISTORICAL docs/audits/*.md'
w README.md '# Hi'
check "zero-match glob entry passes" 0 "doc-truth: OK"

new_repo
w .doc-contract 'WIBBLE README.md' 'LIVING README.md'
w README.md '# Hi'
check "unknown keyword fails" 1 "unknown keyword"

new_repo
w README.md '# Hi'
check "missing contract fails" 1 "not found"

new_repo
w .doc-contract 'SOURCE sub/*.md' 'LIVING README.md'
w README.md '# Hi'
w sub/a.md 'a'
check "glob tier covers nested file" 0 "doc-truth: OK"

# ── Cycle 2: HISTORICAL banner ─────────────────────────────────────

new_repo
w .doc-contract 'HISTORICAL OLD.md'
w OLD.md '# Old notes'
check "historical without banner fails" 1 "banner"

new_repo
w .doc-contract 'HISTORICAL OLD.md'
w OLD.md '# Old notes' '' '> **Historical** — point-in-time record (2026-06-12). Do not act on this.'
check "historical with banner passes" 0 "doc-truth: OK"

new_repo
w .doc-contract 'HISTORICAL docs/adr/0001.md'
w docs/adr/0001.md '# 1. Decide things' '' '- **Status:** Accepted' '- **Date:** 2026-01-01'
check "ADR status header accepted as banner" 0 "doc-truth: OK"

new_repo
w .doc-contract 'HISTORICAL OLD.md'
w OLD.md '# Old' 'x' 'x' 'x' 'x' '> **Historical** — point-in-time record.'
check "banner beyond first 5 lines fails" 1 "banner"

new_repo
w .doc-contract 'HISTORICAL docs/*.md' 'LIVING docs/guide.md'
w docs/guide.md '# Guide'
check "first match wins over later entries" 1 "banner"

# ── Cycle 3: dead relative links (LIVING + GENERATED only) ─────────

new_repo
w .doc-contract 'LIVING README.md'
w README.md 'See [guide](docs/guide.md).'
check "dead relative link fails" 1 "dead-ref"

new_repo
w .doc-contract 'LIVING README.md' 'SOURCE docs/guide.md'
w docs/guide.md '# Guide'
w README.md 'See [guide](docs/guide.md), [site](https://example.com), [top](#top), [mail](mailto:a@b.c).'
check "live link, url, anchor, mailto pass" 0 "doc-truth: OK"

new_repo
w .doc-contract 'LIVING docs/index.md' 'SOURCE docs/sub/x.md'
w docs/sub/x.md '# X'
w docs/index.md 'see [x](sub/x.md#section "title")'
check "link resolves relative to file dir, anchor+title stripped" 0 "doc-truth: OK"

new_repo
w .doc-contract 'SOURCE notes/n.md'
w notes/n.md 'see [gone](../missing.md)'
check "source tier skips dead-ref" 0 "doc-truth: OK"

new_repo
w .doc-contract 'LIVING CHANGELOG.md'
w CHANGELOG.md 'removed [old thing](deleted.md) today'
check "changelog exempt from dead-ref" 0 "doc-truth: OK"

# ── Cycle 4: BANNED patterns + scopes ──────────────────────────────

new_repo
w .doc-contract 'LIVING README.md' 'BANNED Agent Commons'
w README.md 'Agent Commons lives on here'
check "banned hit in living fails" 1 "banned"

new_repo
w .doc-contract 'LIVING README.md' 'BANNED agent commons'
w README.md 'AGENT COMMONS in caps'
check "banned match is case-insensitive" 1 "banned"

new_repo
w .doc-contract 'HISTORICAL OLD.md' 'BANNED Agent Commons'
w OLD.md '> **Historical** — point-in-time record (2026-01-01).' 'Agent Commons was the old name'
check "historical exempt from banned" 0 "doc-truth: OK"

new_repo
w .doc-contract 'SOURCE s.md' 'BANNED old-name'
w s.md 'frontmatter: old-name'
check "unscoped banned includes source" 1 "banned"

new_repo
w .doc-contract 'SOURCE s.md' 'BANNED:LIVING,GENERATED ^[[:space:]]*[-*] \[ \]'
w s.md '- [ ] template checkbox'
check "scoped banned skips source" 0 "doc-truth: OK"

new_repo
w .doc-contract 'LIVING t.md' 'BANNED:LIVING,GENERATED ^[[:space:]]*[-*] \[ \]'
w t.md '- [ ] open work item'
check "checkbox guard catches living tracker" 1 "banned"

new_repo
w .doc-contract 'LIVING README.md' 'BANNED'
w README.md '# Hi'
check "empty banned regex fails contract" 1 "no regex"

new_repo
w .doc-contract 'HISTORICAL OLD.md' 'BANNED:HISTORICAL,LIVING badword'
w OLD.md '> **Historical** — point-in-time record (2026-01-01).' 'badword here'
check "historical exempt even when scope names it" 0 "doc-truth: OK"

new_repo
w .doc-contract 'LIVING README.md' 'BANNED foo(bar'
w README.md '# Hi'
check "invalid banned regex fails contract" 1 "invalid"

new_repo
w .doc-contract 'LIVING README.md'
w README.md 'See [guide][g].' '' '[g]: docs/guide.md'
check "dead reference-style link fails" 1 "dead-ref"

new_repo
w .doc-contract 'LIVING README.md' 'SOURCE docs/guide.md'
w docs/guide.md '# G'
w README.md 'See [guide][g].' '' '[g]: docs/guide.md' '[ext]: https://example.com "Site"'
check "live reference-style link and external def pass" 0 "doc-truth: OK"

new_repo
w .doc-contract 'LIVING README.md' 'BANNED:LIVNG old-name'
w README.md 'old-name here'
check "unknown banned scope fails contract" 1 "unknown BANNED scope"

new_repo
w .doc-contract 'LIVING README.md' 'BANNED: old-name'
w README.md '# Hi'
check "empty banned scope fails contract" 1 "scope"

new_repo
w .doc-contract 'LIVING README.md' 'SOURCE docs/guide.md'
w docs/guide.md '# G'
w README.md "See [a](docs/guide.md 'Guide') and [b](docs/guide.md (Guide))."
check "single-quoted and paren link titles stripped" 0 "doc-truth: OK"

new_repo
w .doc-contract 'LIVING t.md' 'BANNED:LIVING,GENERATED ^[[:space:]]*[-*] \[ \]'
w t.md '  - [ ] indented open item'
check "posix-class checkbox guard catches indented checkbox" 1 "banned"

# ── Cycle 6 (v2): code spans and fences exempt from dead-ref only ──

new_repo
w .doc-contract 'LIVING README.md'
w README.md 'slug must match `/^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/`.'
check "regex in inline code span is not a link" 0 "doc-truth: OK"

new_repo
w .doc-contract 'LIVING README.md'
w README.md '```' '[x](missing.md)' '```'
check "dead link inside fenced block ignored" 0 "doc-truth: OK"

new_repo
w .doc-contract 'LIVING README.md'
w README.md 'has `code span` here' 'and a real [dead](missing.md) link'
check "real dead link still caught alongside code spans" 1 "README.md:2 — dead-ref"

new_repo
w .doc-contract 'LIVING README.md' 'BANNED workgraph install'
w README.md 'run `workgraph install` to start'
check "banned still sees inline code spans" 1 "banned"

new_repo
w .doc-contract 'BANNED old-name'
check "repo with no tracked markdown runs clean" 0 "0 markdown files"

# ── Cycle 7 (#424): the bash 3.2 floor ─────────────────────────────
# The checker is vendored verbatim into other repos and has to run under the
# macOS system bash (3.2.57). These are static guards over its own source;
# full-line comments are stripped first so the file header may name the
# constructs it bans.

# Comment-only lines go first so the checker's header can name what it bans;
# backslash continuations are then joined, or `declare -r \` + `-A table`
# would hide a banned flag from a line-oriented grep.
checker_code() {
  grep -v '^[[:space:]]*#' "$CHECKER" | sed -e :a -e '/\\$/N; s/\\\n//; ta'
}

# guard <name> <grep -E pattern>  — fails if the pattern appears in the code
guard() {
  local name="$1" re="$2" hits
  hits="$(checker_code | grep -nE -- "$re")"
  if [[ -n "$hits" ]]; then
    echo "✖ $name"
    echo "$hits" | sed 's/^/    /'
    failed=$((failed + 1))
  else
    echo "✓ $name"
    pass=$((pass + 1))
  fi
}

guard "no bash-4 builtins (mapfile/readarray/coproc)" \
  '(^|[^[:alnum:]_.-])(mapfile|readarray|coproc)([^[:alnum:]_.-]|$)'
# -A associative (4.0), -g global (4.2), -n nameref (4.3). On 3.2.57 each is
# an "invalid option" that still leaves the assignment standing, so the script
# would run on with the wrong semantics rather than stop.
guard "no bash-4 declare flags (-A, -g, -n)" \
  '(declare|local|typeset)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*[Ang]'
# Single-character ${v^} and ${v,} are bash-4-only too and are `bad
# substitution` on 3.2.57, so the operators are matched one-or-twice.
guard 'no bash-4 case conversion (${v,} ${v,,} ${v^} ${v^^})' \
  '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,|\^)'
guard "no bash-4 redirections (|& and &>>)" \
  '\|&|&>>'
# Both ${a[-1]} and the bare a[-1]= assignment form; on 3.2.57 the latter is
# `bad array subscript`.
guard "no negative array subscripts" \
  '[A-Za-z_][A-Za-z0-9_]*\[[[:space:]]*-'
guard "no ;& or ;;& case fallthrough" \
  ';;?&'
# {fd}< and {fd}> allocate a descriptor (bash 4.1). The leading [^$] keeps a
# plain "${var}>out" redirection from matching.
guard "no {fd} descriptor redirections" \
  '(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
guard 'no ${v@Q} parameter transformations' \
  '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?@[A-Za-z]\}'
# `read -N` is an invalid option on 3.2.57; -r/-d/-a/-t/-u/-p/-s/-n are fine.
guard "no read -N" \
  '(^|[^[:alnum:]_.-])read([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*N'
# shopt names 3.2.57 rejects as "invalid shell option name".
guard "no bash-4 shopt options" \
  'shopt[[:space:]]+(-[a-z][[:space:]]+)*(globstar|lastpipe|dirspell|autocd|checkjobs|compat4[0-9]|globasciiranges|inherit_errexit|localvar_inherit|assoc_expand_once)'
# Under `set -u`, bash 3.2 calls ${arr[@]} unbound when arr is empty, so the
# checker iterates by index. Verified on a bash 3.2.57 build: ${!arr[@]}
# and ${#arr[@]} on an empty array are fine there; ${arr[@]} aborts the run.
guard 'no bare ${array[@]} value expansion (iterate by index)' \
  '\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}'

echo ""
echo "doc-truth tests: $pass passed, $failed failed"
[[ "$failed" -eq 0 ]] || exit 1
