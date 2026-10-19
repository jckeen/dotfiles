#!/usr/bin/env bash
# assemble-changelog.sh — fold per-PR changelog fragments into CHANGELOG.md.
#
# Every PR used to prepend its entry to the head of CHANGELOG.md, so each merge
# to main made every other open PR conflict on the same lines and re-run the
# whole review gate (#626). Instead a PR adds one fragment:
#
#   changelog.d/<branch-slug>.md      by convention, the branch name with
#                                     every `/` turned to `-`
#
# The name is a convention only: two branches can share a slug (feat/a-b and
# feat-a/b), so nothing derives a filename from a branch. Any name of letters,
# digits, `.`, `_` and `-` ending in `.md` is valid. Two PRs then never touch
# the same file.
#
# A fragment is a strict, line-oriented format. Every line is allowlisted by
# how it starts, so the parsed surface is finite: no Markdown construct that
# could reorder, hide or swallow an entry (fences, HTML blocks, comments,
# blockquotes, tables, setext underlines) has a line shape that passes.
# Each line is exactly one of:
#   - blank;
#   - an entry heading `## YYYY-MM-DD — <type>(<scope>)?!?: <summary>` at
#     column 0, single spaces, no tab (types: the conventional set
#     check-commit-format.sh enforces) — each entry needs at least one bullet;
#   - a `### ` subsection at column 0;
#   - a bullet: `- ` or `* ` indented 0-3 spaces, then text;
#   - a continuation: 2+ spaces, then text.
# Bullet and continuation text may not start with < > | # =, neither as
# written nor after stripping every leading container prefix (whitespace,
# `- ` `* ` `+ ` and `1. ` `1) ` list markers, `>`), and may not be only
# - * _ = : | characters (a thematic break, setext underline or table
# delimiter row). No line may
# contain <!--, -->, ``` or ~~~ anywhere. Inline `code` is fine. No CRLF.
# Above CHANGELOG.md's first `## ` line only blank lines, one `# ` title and
# the POINTER_1 / POINTER_2 lines below are allowed, verbatim.
#
# Assembly is a manual step (release or handoff time), not a bot push to main:
# main's required status checks refuse a commit that has not run them, and a
# GITHUB_TOKEN push would never trigger them. Until assembly, changelog.d/ IS
# the head of the changelog.
#
# Usage:
#   assemble-changelog.sh            fold every fragment into CHANGELOG.md
#                                    immediately above its first line starting
#                                    `## `, then delete the fragments. Entries
#                                    appear in assembly order: within one
#                                    assembly, newest date first, ties by
#                                    filename, then position in the file. No
#                                    fragments: a no-op.
#   assemble-changelog.sh --check    validate every fragment; write nothing
#     [--base REF]                   also: REF...HEAD adds at most one fragment,
#                                    modifies or renames none on the base, and
#                                    adds no `## ` entry to CHANGELOG.md while
#                                    adding one. --check also checks assembly's
#                                    preconditions (CHANGELOG.md present, title
#                                    on line 1).
#   --root DIR                       repo root (default: git toplevel of cwd)
#
# Exit: 0 clean, 1 on any malformed fragment or refused assembly (nothing is
# written then), 2 on a usage error. Bash 3.2-safe; no fd/rg.

set -euo pipefail
# Byte order for glob expansion and sort, so the filename tie-break is the same
# on every machine.
export LC_ALL=C

TYPES='feat|fix|refactor|chore|docs|test|style|perf|build|ci|revert'

# The only text allowed above CHANGELOG.md's first `## ` line, besides blank
# lines and its one `# ` title: these pointer lines, exactly.
# shellcheck disable=SC2016  # literal backticks, not command substitution
POINTER_1='Entries not yet assembled live one per PR in `changelog.d/`, and'
# shellcheck disable=SC2016
POINTER_2='the script `claude/scripts/assemble-changelog.sh` inserts them here in assembly order.'

die() {
  printf '✖ assemble-changelog: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

CHECK=0
BASE=""
ROOT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --base)
      [ "$#" -ge 2 ] || die "--base needs a git ref" 2
      BASE="$2"
      shift
      ;;
    --root)
      [ "$#" -ge 2 ] || die "--root needs a directory" 2
      ROOT="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" 2 ;;
  esac
  shift
done

if [ -n "$BASE" ] && [ "$CHECK" -eq 0 ]; then
  die "--base only applies with --check" 2
fi

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repository (pass --root DIR)"
fi
[ -d "$ROOT" ] || die "root '$ROOT' is not a directory"
cd "$ROOT"

FRAG_DIR="changelog.d"
CHANGELOG="CHANGELOG.md"

# ── Collect fragments ──────────────────────────────────────────────
FRAGS=()
errors=0
err() {
  printf '✖ %s\n' "$1" >&2
  errors=$((errors + 1))
}

# A symlinked changelog.d would make assembly delete files outside the root,
# and an unreadable one would expand no globs and pass as empty.
if [ -L "$FRAG_DIR" ]; then
  die "$FRAG_DIR is a symlink; it must be a real directory in the repo"
fi
if [ -d "$FRAG_DIR" ]; then
  [ -r "$FRAG_DIR" ] && [ -x "$FRAG_DIR" ] \
    || die "$FRAG_DIR is not readable; cannot list its fragments"
  # The three globs cover every name but `.` and `..`, dotfiles included.
  for f in "$FRAG_DIR"/* "$FRAG_DIR"/.[!.]* "$FRAG_DIR"/..?*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    name="${f#"$FRAG_DIR"/}"
    case "$name" in
      .gitkeep) continue ;;
    esac
    if [ -L "$f" ] || [ ! -f "$f" ]; then
      err "$f — not a regular file; $FRAG_DIR/ holds only .md fragments"
      continue
    fi
    case "$name" in
      *.md) ;;
      *)
        err "$f — not a .md fragment; $FRAG_DIR/ holds only .md fragments"
        continue
        ;;
    esac
    if ! printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*\.md$'; then
      err "$f — fragment name must be letters, digits, '.', '_' or '-', ending in .md"
      continue
    fi
    FRAGS+=("$f")
  done
elif [ -e "$FRAG_DIR" ]; then
  die "$FRAG_DIR exists but is not a directory"
fi

# ── Validate each fragment, line by line ───────────────────────────
# Emits "<line>\t<message>" per problem.
# shellcheck disable=SC2016  # an awk program: $0 etc. are awk's, not the shell's
validate_awk='
function days_in(y, m) {
  if (m == 2) return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28
  return (m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31
}
# Text after a bullet marker or continuation indent: must not open a block
# construct (HTML, blockquote, table, heading, setext) or be a rule — neither
# as written nor after stripping every leading container prefix (whitespace,
# `- ` / `* ` / `+ ` markers, `1. ` / `1) ` markers, `>`), since a nested list
# or quote puts any of those constructs back at the start of a block. Text of
# only - * _ = : | characters is a thematic break, a setext underline or a
# GFM table delimiter row (a table needs one, outer pipes or not).
function bad_text(t,   prev) {
  if (t ~ /^[<>|#=]/) return 1
  if (t ~ /^[-*_=:| \t]+$/) return 1
  do {
    prev = t
    sub(/^[ \t]+/, "", t); sub(/^[-*+][ \t]/, "", t); sub(/^[0-9]+[.)][ \t]/, "", t); sub(/^>/, "", t)
  } while (t != prev)
  if (t == "" || t ~ /^[<>|#=]/ || t ~ /^[-*_=:| \t]+$/) return 1
  return 0
}
function before_entry() {
  if (entries == 0 && !seen_content) { printf "%d\tcontent before the first ## heading\n", NR; seen_content = 1 }
}
function close_entry() {
  if (entries > 0 && bullets == 0) printf "%d\tentry has no bullet (\"- ...\") under its heading\n", entry_line
}
BEGIN {
  head_re = "^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] — (" types ")(\\([a-z0-9._/-]+\\))?!?: [^[:space:]]"
  shapes = "a line must be blank, a \"## YYYY-MM-DD — <type>: <summary>\" heading, a \"### \" subsection, a bullet (\"- \" or \"* \" indented 0-3 spaces), or a continuation indented 2+ spaces; bullet and continuation text may not start with < > | # =, even after nested list or quote markers, or be only - * _ ="
  entries = 0; seen_content = 0; bullets = 0
}
/\r/ { printf "%d\tCRLF line ending; use LF\n", NR; next }
# Comment and fence markers are refused anywhere on a line, whatever its shape.
index($0, "<!--") || index($0, "-->") || index($0, "```") || index($0, "~~~") {
  printf "%d\tcomment or fence marker (<!--, -->, ``` or ~~~); fragments hold none, anywhere on a line\n", NR; next
}
/^[ \t]*$/ { next }
/^## / {
  close_entry()
  entries++; entry_line = NR; bullets = 0
  if ($0 ~ /\t/) { printf "%d\ttab in a heading line; use single spaces\n", NR; next }
  if ($0 !~ head_re) {
    printf "%d\theading must be \"## YYYY-MM-DD — <type>(<scope>)?: <summary>\" (type: %s)\n", NR, types
  } else {
    y = substr($0, 4, 4) + 0; m = substr($0, 9, 2) + 0; d = substr($0, 12, 2) + 0
    if (m < 1 || m > 12 || d < 1 || d > days_in(y, m)) printf "%d\tinvalid date %s\n", NR, substr($0, 4, 10)
  }
  next
}
/^### [^ \t]/ {
  if ($0 ~ /\t/) { printf "%d\ttab in a heading line; use single spaces\n", NR; next }
  before_entry(); next
}
/^ ? ? ?[-*] / {
  t = $0; sub(/^ ? ? ?[-*] +/, "", t)
  if (t == "" || bad_text(t)) { printf "%d\t%s\n", NR, shapes; next }
  before_entry(); bullets++; next
}
/^  / {
  t = $0; sub(/^ +/, "", t)
  if (bad_text(t)) { printf "%d\t%s\n", NR, shapes; next }
  before_entry(); next
}
{ printf "%d\t%s\n", NR, shapes }
END {
  close_entry()
  if (entries == 0) printf "0\tno \"## YYYY-MM-DD — <type>: <summary>\" entry\n"
}'

# awk runs in a command substitution, not a process substitution, so a failed
# read (an unreadable fragment) is an error rather than an empty, clean report.
for i in "${!FRAGS[@]}"; do
  f="${FRAGS[$i]}"
  if ! report="$(awk -v types="$TYPES" "$validate_awk" "$f")"; then
    err "$f — could not be read"
    continue
  fi
  while IFS="$(printf '\t')" read -r ln msg; do
    [ -n "$ln" ] || continue
    if [ "$ln" = 0 ]; then err "$f — $msg"; else err "$f:$ln — $msg"; fi
  done <<<"$report"
done

# ── CHANGELOG.md: read as plain lines, not Markdown ────────────────
# Entries are inserted immediately above the first line starting `## `, so
# only the region above it is constrained, by an exact allowlist: blank lines,
# exactly one `# ` title line, and the POINTER_1 / POINTER_2 lines verbatim.
# Nothing below that line is parsed.
if [ -L "$CHANGELOG" ]; then
  die "$CHANGELOG is a symlink; refusing to read or replace it"
fi
# Assembly's own preconditions are checked here, in --check too, so a passing
# --check means assembly can start.
if [ ! -e "$CHANGELOG" ]; then
  err "$CHANGELOG not found in $ROOT"
elif [ ! -f "$CHANGELOG" ]; then
  err "$CHANGELOG is not a regular file"
else
  if ! head -n 1 "$CHANGELOG" | grep -q '^# '; then
    err "$CHANGELOG must start with a '# ' title line"
  fi
  head_report="$(awk -v p1="$POINTER_1" -v p2="$POINTER_2" '
    /^## / { exit }
    /^$/ { next }
    /^# [^ \t]/ { if (++titles > 1) print NR; next }
    $0 == p1 || $0 == p2 { next }
    { print NR }
    END { if (titles == 0) print 0 }' "$CHANGELOG")" \
    || die "$CHANGELOG could not be read"
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    if [ "$ln" = 0 ]; then
      err "$CHANGELOG — above the first ## entry there must be exactly one \"# \" title line"
    else
      err "$CHANGELOG:$ln — above the first ## entry only blank lines, exactly one \"# \" title and the script's pointer lines are allowed"
    fi
  done <<<"$head_report"

  # A fragment heading already present anywhere in CHANGELOG.md, as an exact
  # line, means it was folded once and the fragment survived (an interrupted
  # run, or a revert). A false match only refuses, which is safe.
  for i in "${!FRAGS[@]}"; do
    f="${FRAGS[$i]}"
    if ! heads="$(awk '/^## / { print }' "$f")"; then
      err "$f — could not be read"
      continue
    fi
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      rc=0
      grep -qxF -- "$h" "$CHANGELOG" || rc=$?
      if [ "$rc" -eq 0 ]; then
        err "$f — entry '$h' is already in $CHANGELOG (already assembled? delete the fragment)"
      elif [ "$rc" -ne 1 ]; then
        err "$CHANGELOG could not be read"
      fi
    done <<<"$heads"
  done
fi

# Two pending entries with one heading would fold into indistinguishable
# sections (and defeat the already-assembled check above).
if [ "${#FRAGS[@]}" -gt 0 ]; then
  dups="$(awk '
    /^## / {
      if ($0 in seen) {
        if (seen[$0] == FILENAME) printf "%s:%d\theading repeated in this fragment: %s\n", FILENAME, FNR, $0
        else printf "%s:%d\theading also in %s: %s\n", FILENAME, FNR, seen[$0], $0
      } else seen[$0] = FILENAME
    }' "${FRAGS[@]}")" || err "could not read every fragment to compare headings"
  while IFS="$(printf '\t')" read -r where msg; do
    [ -n "$where" ] || continue
    err "$where — $msg"
  done <<<"$dups"
fi

# ── PR scope: one fragment added, nothing else in the changelog ────
# A PR adds at most one fragment, modifies or renames no fragment already on
# the base (another PR's record), and, when it adds one, adds no `## ` entry
# to CHANGELOG.md. Deleting fragments while adding entries is the assembly
# PR's shape, and stays allowed.
if [ -n "$BASE" ]; then
  git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
    || die "--base '$BASE' is not a commit here (fetch it, or fetch-depth: 0 in CI)"
  added="$(git diff --name-only --diff-filter=A "$BASE...HEAD" -- "$FRAG_DIR/")" \
    || die "git diff $BASE...HEAD failed"
  n_added=0
  [ -z "$added" ] || n_added="$(printf '%s\n' "$added" | wc -l | tr -d ' ')"
  if [ "$n_added" -gt 1 ]; then
    err "this branch adds $n_added fragments; a PR adds one fragment file (several ## entries may share it):
$(printf '%s\n' "$added" | sed 's/^/    /')"
  fi
  touched="$(git diff -M --name-only --diff-filter=MR "$BASE...HEAD" -- "$FRAG_DIR/")" \
    || die "git diff $BASE...HEAD failed"
  if [ -n "$touched" ]; then
    err "this branch modifies or renames pending fragment(s) from the base; a PR adds its own fragment and leaves others alone:
$(printf '%s\n' "$touched" | sed 's/^/    /')"
  fi
  if [ "$n_added" -gt 0 ]; then
    cl_diff="$(git diff "$BASE...HEAD" -- "$CHANGELOG")" || die "git diff $BASE...HEAD failed"
    # Here-string, not a pipe: grep -q exits early, and pipefail would read the
    # writer's SIGPIPE as a miss.
    if grep -q '^+## ' <<<"$cl_diff"; then
      err "this branch adds a fragment and also adds an entry to $CHANGELOG; put the entry in the fragment only"
    fi
  fi
fi

if [ "$errors" -gt 0 ]; then
  printf '\nassemble-changelog: FAILED — %d problem(s). Nothing was written.\n' "$errors" >&2
  exit 1
fi

if [ "$CHECK" -eq 1 ]; then
  echo "assemble-changelog: OK — ${#FRAGS[@]} fragment(s) well-formed"
  exit 0
fi

if [ "${#FRAGS[@]}" -eq 0 ]; then
  echo "assemble-changelog: no fragments in $FRAG_DIR/ — nothing to assemble"
  exit 0
fi

# ── Assemble ───────────────────────────────────────────────────────
# Unlinking a fragment needs write access to its directory; check before any
# write so a failure cannot leave the entries folded and the fragments behind.
[ -w "$FRAG_DIR" ] || die "cannot delete fragments: $FRAG_DIR is not writable; nothing was written"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/assemble-changelog.XXXXXX")"
HELD=""
# Scratch files go; a holding directory that still has fragments in it (a
# failed restore, or an interruption mid-move) is never deleted, and its path
# is printed so they can be moved back by hand.
cleanup() {
  rm -rf "$TMP"
  [ -n "$HELD" ] && [ -d "$HELD" ] || return 0
  if rmdir "$HELD" 2>/dev/null; then return 0; fi
  printf '✖ assemble-changelog: fragments are preserved in %s; move them back into %s/\n' "$HELD" "$FRAG_DIR" >&2
}
trap cleanup EXIT

# Split every fragment into one file per entry plus a sort key:
#   <date> TAB <fragment name> TAB <index in file> TAB <entry file>
tab="$(printf '\t')"
: >"$TMP/index"
n=0
for i in "${!FRAGS[@]}"; do
  f="${FRAGS[$i]}"
  awk -v out="$TMP/e.$i." -v name="${f#"$FRAG_DIR"/}" '
    /^## / { k++; file = out k; printf "%s\t%s\t%d\t%s\n", substr($0, 4, 10), name, k, file >> idx }
    k { print > file }
  ' idx="$TMP/index" "$f"
  n=$((n + 1))
done

# Newest date first; ties by fragment name, then position within the fragment.
sort -t "$tab" -k1,1r -k2,2 -k3,3n "$TMP/index" >"$TMP/sorted"

# Entry bodies with trailing blank lines trimmed, one blank line between.
trim() { awk '{ l[NR] = $0 } END { n = NR; while (n > 0 && l[n] ~ /^[[:space:]]*$/) n--; for (j = 1; j <= n; j++) print l[j] }' "$@"; }
: >"$TMP/block"
while IFS="$tab" read -r _ _ _ efile; do
  trim "$efile" >>"$TMP/block"
  echo >>"$TMP/block"
done <"$TMP/sorted"

# Insert immediately above the first line starting `## `; with none, append.
first="$(awk '/^## / { print NR; exit }' "$CHANGELOG")"
{
  if [ -n "$first" ]; then
    head -n "$((first - 1))" "$CHANGELOG" | trim
    echo
    cat "$TMP/block"
    tail -n "+$first" "$CHANGELOG"
  else
    trim "$CHANGELOG"
    echo
    trim "$TMP/block"
  fi
} >"$TMP/CHANGELOG.new"

# Same-directory rename so a failure never leaves a half-written changelog.
# mktemp creates the staging file exclusively, so a pre-planted name (say, a
# symlink to some other file) can never be written through.
stage="$(mktemp "$CHANGELOG.assemble.XXXXXX")" || die "cannot create a staging file beside $CHANGELOG"
# mktemp makes it 0600; CHANGELOG.md is a tracked non-executable file (0644).
if ! cat "$TMP/CHANGELOG.new" >"$stage" || ! chmod 644 "$stage"; then
  rm -f -- "$stage"
  die "could not stage the new $CHANGELOG; nothing was changed"
fi
# Move the fragments aside first, then replace CHANGELOG.md: either step
# failing puts every fragment back, so the result is all or nothing. The
# holding directory sits in the repo root (same filesystem, so each move is a
# rename) and outlives the run whenever it is not empty — see cleanup().
HELD="$(mktemp -d ".assemble-held.XXXXXX")" || die "cannot create a holding directory; nothing was changed"
restore() { # returns 1 if any fragment could not be put back
  local g ok=0
  for g in "$HELD"/*; do
    [ -e "$g" ] || continue
    mv -- "$g" "$FRAG_DIR/" || ok=1
  done
  rm -f -- "$stage"
  return "$ok"
}
fail_after_hold() { # <what failed>
  if restore; then
    die "$1; every fragment was restored and $CHANGELOG is unchanged"
  fi
  die "$1; some fragments could not be restored (they are kept in $HELD)"
}
for i in "${!FRAGS[@]}"; do
  mv -- "${FRAGS[$i]}" "$HELD/" || fail_after_hold "cannot delete ${FRAGS[$i]}"
done
mv -f -- "$stage" "$CHANGELOG" || fail_after_hold "could not replace $CHANGELOG"
rm -rf -- "$HELD"

entries="$(wc -l <"$TMP/sorted" | tr -d ' ')"
echo "assemble-changelog: folded $entries entr$([ "$entries" = 1 ] && echo y || echo ies) from $n fragment(s) into $CHANGELOG"
echo "  review with: git diff -- $CHANGELOG $FRAG_DIR/   then stage both"
