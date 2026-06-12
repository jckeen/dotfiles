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

# check <name> <expected-exit> [<required output fragment>]
check() {
  local name="$1" want="$2" frag="${3:-}"
  git -C "$R" add -A >/dev/null 2>&1
  local out rc
  out="$(cd "$R" && "$CHECKER" 2>&1)"
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
w .doc-contract 'SOURCE s.md' 'BANNED:LIVING,GENERATED ^\s*[-*] \[ \]'
w s.md '- [ ] template checkbox'
check "scoped banned skips source" 0 "doc-truth: OK"

new_repo
w .doc-contract 'LIVING t.md' 'BANNED:LIVING,GENERATED ^\s*[-*] \[ \]'
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

echo ""
echo "doc-truth tests: $pass passed, $failed failed"
[[ "$failed" -eq 0 ]] || exit 1
