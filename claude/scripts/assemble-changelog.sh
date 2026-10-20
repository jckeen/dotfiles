#!/usr/bin/env bash
# assemble-changelog.sh — validate per-PR changelog fragments (check-only).
#
# The name is historical: this script once folded fragments into CHANGELOG.md
# itself. That mode was removed in #661; it now only checks, and never writes.
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
# digits, `.`, `_` and `-` ending in `.md` is valid, checked as a whole string
# (an embedded newline is refused), and no two names may differ only in case,
# since they collide on a case-insensitive checkout. Two PRs then never touch
# the same file.
#
# A fragment is a strict, line-oriented format. Every line is allowlisted by
# how it starts, so the parsed surface is finite: no Markdown construct that
# could reorder, hide or swallow an entry (fences, HTML blocks, comments,
# blockquotes, tables, setext underlines) has a line shape that passes.
# Each line is exactly one of:
#   - blank;
#   - an entry heading `## YYYY-MM-DD — TYPE(SCOPE)?!?: SUMMARY` at
#     column 0, single spaces, no tab (types: the conventional set
#     check-commit-format.sh enforces), its summary holding no [ ] & and at least one
#     letter or digit — each entry needs at least one bullet;
#   - a `### ` subsection at column 0;
#   - a bullet: `- ` or `* ` indented 0-3 spaces, then text;
#   - a continuation: 2+ spaces, then text.
# Bullet and continuation text may not start with < > | # =, neither as
# written nor after stripping every leading list prefix (whitespace,
# `- ` `* ` `+ ` and `1. ` `1) ` markers), so a `>` quote marker behind a
# nested list marker is refused too, and may not be only - * _ = : |
# characters (a thematic break, setext underline or table delimiter row).
# No line may contain, anywhere: <!--, -->, ``` or ~~~; `<` followed by a
# letter, `/`, `!` or `?` (inline HTML, which can hide text, even inside
# inline code); `]:` (a link reference definition, which renders as
# nothing); or a control byte other than tab. Inline `code` is otherwise
# fine. No CRLF.
# Above CHANGELOG.md's first `## ` line only blank lines, one `# ` title and
# the POINTER_1 / POINTER_2 lines below are allowed, verbatim.
#
# Folding is a reviewed manual step at release or handoff time, in a
# `docs: fold changelog fragments` PR: copy each fragment's entries above
# CHANGELOG.md's first `## ` entry, newest date first, then `git rm` the
# fragments. It is not a bot push to main: main's required status checks
# refuse a commit that has not run them, and a GITHUB_TOKEN push would never
# trigger them. Until folded, changelog.d/ is the head of the changelog.
#
# Usage:
#   assemble-changelog.sh --check    validate every fragment, and that
#                                    CHANGELOG.md is present with its title on
#                                    line 1 and an allowed preamble
#   --root DIR                       repo root (default: the current directory)
#   With no --check: print this usage and exit 2.
#
# A pure content validator: it reads changelog.d/*.md and the top of
# CHANGELOG.md from the working tree, runs no git and writes nothing. The PR
# scope rule (one added fragment, no edits to another PR's fragment, no direct
# CHANGELOG.md entry beside a fragment) needs the PR's diff, so it is not
# here. It is not enforced yet: reviewers check it by hand until the operator
# applies the CI patch that adds it as a workflow step.
#
# Exit: 0 clean, 1 on any problem, 2 on a usage error. Never writes.
# Bash 3.2-safe; no fd/rg.

set -euo pipefail
# Byte order for glob expansion and pattern matching, the same on every machine.
export LC_ALL=C

TYPES='feat|fix|refactor|chore|docs|test|style|perf|build|ci|revert'

# The only text allowed above CHANGELOG.md's first `## ` line, besides blank
# lines and its one `# ` title: these pointer lines, exactly.
# shellcheck disable=SC2016  # literal backticks, not command substitution
POINTER_1='Entries not yet folded in live one per PR in `changelog.d/`; they are'
# shellcheck disable=SC2016
POINTER_2='copied here by hand at release time (see `claude/scripts/README.md`).'

die() {
  printf '✖ assemble-changelog: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  sed -n '2,69p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

CHECK=0
ROOT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
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

if [ "$CHECK" -eq 0 ]; then
  usage >&2
  exit 2
fi

# No git: the root is the current directory unless --root names one. A wrong
# directory fails closed below, since CHANGELOG.md must be present.
[ -n "$ROOT" ] || ROOT="."
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

# A symlinked changelog.d would validate files outside the repo, and an
# unreadable one would expand no globs and pass as empty.
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
    # A case pattern matches the whole string; grep would accept a name
    # with an embedded newline whenever any one of its lines matched.
    case "$name" in
      [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
        err "$f — fragment name must be letters, digits, '.', '_' or '-', ending in .md"
        continue
        ;;
    esac
    FRAGS+=("$f")
  done
  # Names differing only in case collide on a case-insensitive filesystem
  # (macOS, Windows), where one fragment silently replaces the other.
  lowers=()
  for i in "${!FRAGS[@]}"; do
    lowers+=("$(printf '%s' "${FRAGS[$i]}" | tr '[:upper:]' '[:lower:]')")
    j=0
    while [ "$j" -lt "$i" ]; do
      if [ "${lowers[$j]}" = "${lowers[$i]}" ]; then
        err "${FRAGS[$i]} — differ only in case from ${FRAGS[$j]}; they collide on a case-insensitive checkout"
      fi
      j=$((j + 1))
    done
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
# as written nor after stripping every leading list prefix (whitespace,
# `- ` / `* ` / `+ ` markers, `1. ` / `1) ` markers), since a nested list puts
# any of those constructs back at the start of a block. A `>` is refused
# there, not stripped: a quote nested in a list is a blockquote. Text of
# only - * _ = : | characters is a thematic break, a setext underline or a
# GFM table delimiter row (a table needs one, outer pipes or not).
function bad_text(t,   prev) {
  if (t ~ /^[<>|#=]/) return 1
  if (t ~ /^[-*_=:| \t]+$/) return 1
  do {
    prev = t
    sub(/^[ \t]+/, "", t); sub(/^[-*+][ \t]/, "", t); sub(/^[0-9]+[.)][ \t]/, "", t)
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
  shapes = "a line must be blank, a \"## YYYY-MM-DD — <type>: <summary>\" heading, a \"### \" subsection, a bullet (\"- \" or \"* \" indented 0-3 spaces), or a continuation indented 2+ spaces; bullet and continuation text may not start with < > | # =, even after nested list markers, or be only - * _ ="
  entries = 0; seen_content = 0; bullets = 0
}
/\r/ { printf "%d\tCRLF line ending; use LF\n", NR; next }
# Comment and fence markers are refused anywhere on a line, whatever its shape.
index($0, "<!--") || index($0, "-->") || index($0, "```") || index($0, "~~~") {
  printf "%d\tcomment or fence marker (<!--, -->, ``` or ~~~); fragments hold none, anywhere on a line\n", NR; next
}
# Banned anywhere, whatever the line shape, so no parse of code spans is needed.
/<[A-Za-z\/!?]/ {
  printf "%d\tinline HTML (< followed by a letter, /, ! or ?); fragments hold none, anywhere on a line, inline code included\n", NR; next
}
index($0, "]:") {
  printf "%d\tlink reference definition marker ]: (it renders as nothing); fragments hold none, anywhere on a line\n", NR; next
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
    # The summary must render as text: markup alone (**, ###, `` ``) does not.
    summary = $0; sub(/^[^:]*: /, "", summary)
    # Letters inside a link destination or entity name render as nothing,
    # so a summary holds no [ ] & at all rather than having them parsed.
    if (summary ~ /[][&]/) printf "%d\theading summary may not hold [ ] or & (a link or entity can render as nothing)\n", NR
    else if (summary !~ /[A-Za-z0-9]/) printf "%d\theading must be \"## YYYY-MM-DD — TYPE: SUMMARY\" with a summary of at least one letter or digit\n", NR
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
  # Control bytes (tab, LF and CR aside; CR has its own CRLF message) are
  # counted outside awk, which not every implementation reads NUL through.
  if ! ctl="$(tr -d '\t\n\r\040-\176\200-\377' <"$f" | wc -c)"; then
    err "$f — could not be read"
    continue
  fi
  ctl=$((ctl))
  if [ "$ctl" -gt 0 ]; then
    err "$f — contains $ctl control byte(s); fragments hold printable text, tab and LF only"
  fi
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
# Folded entries go immediately above the first line starting `## `, so only
# the region above it is constrained, by an exact allowlist: blank lines,
# exactly one `# ` title line, and the POINTER_1 / POINTER_2 lines verbatim.
# Nothing below that line is parsed.
if [ -L "$CHANGELOG" ]; then
  die "$CHANGELOG is a symlink; refusing to read it"
fi
# The fold's preconditions: CHANGELOG.md present, title on line 1.
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
        err "$f — entry '$h' is already in $CHANGELOG (already folded? remove the fragment)"
      elif [ "$rc" -ne 1 ]; then
        err "$CHANGELOG could not be read"
      fi
    done <<<"$heads"
  done
fi

# Two pending entries with one heading would fold into indistinguishable
# sections (and defeat the already-folded check above).
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

if [ "$errors" -gt 0 ]; then
  printf '\nassemble-changelog: FAILED — %d problem(s).\n' "$errors" >&2
  exit 1
fi
echo "assemble-changelog: OK — ${#FRAGS[@]} fragment(s) well-formed"
