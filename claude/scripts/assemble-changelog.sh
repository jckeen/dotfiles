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
# A fragment is a strict, line-oriented format, deliberately smaller than
# Markdown so that what the validator accepts is exactly what assembly splits:
#   - entries, each a `## YYYY-MM-DD — <type>(<scope>)?!?: <summary>` heading
#     at column 0 with single spaces (types: the conventional set
#     check-commit-format.sh enforces), followed by at least one bullet
#     (`- ` or `* ` indented at most three spaces);
#   - optional `### ` subsections at column 0; inline `code` is fine;
#   - no other line whose first non-blank character is `#`, no code fences
#     (``` or ~~~), no tab in a heading line, no CRLF.
#
# Assembly is a manual step (release or handoff time), not a bot push to main:
# main's required status checks refuse a commit that has not run them, and a
# GITHUB_TOKEN push would never trigger them. Until assembly, changelog.d/ IS
# the head of the changelog.
#
# Usage:
#   assemble-changelog.sh            fold every fragment into CHANGELOG.md,
#                                    then delete the fragments. Each entry goes
#                                    above the first existing entry dated on or
#                                    before it, so newest-first order holds;
#                                    entries sharing a date order by filename,
#                                    then position in the file. No fragments:
#                                    a no-op.
#   assemble-changelog.sh --check    validate every fragment; write nothing
#     [--base REF]                   also: REF...HEAD adds at most one fragment
#   --root DIR                       repo root (default: git toplevel of cwd)
#
# Exit: 0 clean, 1 on any malformed fragment or refused assembly (nothing is
# written then), 2 on a usage error. Bash 3.2-safe; no fd/rg.

set -euo pipefail
# Byte order for glob expansion and sort, so the filename tie-break is the same
# on every machine.
export LC_ALL=C

TYPES='feat|fix|refactor|chore|docs|test|style|perf|build|ci|revert'

die() {
  printf '✖ assemble-changelog: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# ── Fence tracking, for CHANGELOG.md only ──────────────────────────
# Fragments have no fences (the validator refuses them), but CHANGELOG.md's
# older entries may, and a `## ` line inside one is not an entry heading. So
# fences matter only when locating CHANGELOG.md's insertion points. CommonMark
# rules: a fence opens with 3+ backticks or tildes indented at most three
# spaces, and only a run of the SAME character at least as long, with nothing
# after it, closes it. Sets `infence`; returns 1 when the line opened or
# closed a fence.
# shellcheck disable=SC2016  # awk source: $ and backticks are awk's
fence_awk='
function fence_step(line,   s, ch, n, rest) {
  if (!match(line, /^ ? ? ?(```+|~~~+)/)) return 0
  s = substr(line, RSTART, RLENGTH); sub(/^ +/, "", s)
  ch = substr(s, 1, 1); n = length(s); rest = substr(line, RSTART + RLENGTH)
  if (!infence) {
    if (ch == "`" && rest ~ /`/) return 0
    infence = 1; fch = ch; flen = n
    return 1
  }
  if (ch == fch && n >= flen && rest ~ /^[[:space:]]*$/) { infence = 0; return 1 }
  return 0
}'

# ── Validate each fragment's shape ─────────────────────────────────
# Emits "<line>\t<message>" per problem.
# shellcheck disable=SC2016  # an awk program: $0 etc. are awk's, not the shell's
validate_awk='
function days_in(y, m) {
  if (m == 2) return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28
  return (m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31
}
BEGIN {
  head_re = "^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] — (" types ")(\\([a-z0-9._/-]+\\))?!?: [^[:space:]]"
  entries = 0; seen_content = 0; bullets = 0
}
function close_entry() {
  if (entries > 0 && bullets == 0) printf "%d\tentry has no bullet (\"- ...\") under its heading\n", entry_line
}
/\r/ { printf "%d\tCRLF line ending; use LF\n", NR; next }
/^ ? ? ?(```|~~~)/ { printf "%d\tcode fence; fragments hold no code blocks (inline `code` is fine)\n", NR; next }
/^[ \t]*#/ {
  if ($0 ~ /\t/) { printf "%d\ttab in a heading line; use single spaces\n", NR; next }
  if ($0 ~ /^### /) {
    if (entries == 0 && !seen_content) { printf "%d\tcontent before the first ## heading\n", NR; seen_content = 1 }
    next
  }
  if ($0 !~ /^## /) {
    printf "%d\ta line starting with # must be a \"## YYYY-MM-DD — <type>: <summary>\" entry heading or a \"### \" subsection, at column 0\n", NR
    next
  }
  close_entry()
  entries++; entry_line = NR; bullets = 0
  if ($0 !~ head_re) {
    printf "%d\theading must be \"## YYYY-MM-DD — <type>(<scope>)?: <summary>\" (type: %s)\n", NR, types
  } else {
    y = substr($0, 4, 4) + 0; m = substr($0, 9, 2) + 0; d = substr($0, 12, 2) + 0
    if (m < 1 || m > 12 || d < 1 || d > days_in(y, m)) printf "%d\tinvalid date %s\n", NR, substr($0, 4, 10)
  }
  next
}
/^[[:space:]]*$/ { next }
{
  if (entries == 0) {
    if (!seen_content) printf "%d\tcontent before the first ## heading\n", NR
    seen_content = 1
    next
  }
  # A list item starts within three spaces; four or more would be code.
  if ($0 ~ /^ ? ? ?[-*][ \t]/) bullets++
}
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

# A fragment heading already present in CHANGELOG.md means it was folded once
# and the fragment survived (an interrupted run, or a revert) — folding it again
# would duplicate the entry.
# Compared against CHANGELOG.md's own unfenced entry headings, so a heading
# quoted inside a fenced example there is not mistaken for a folded entry.
if [ -L "$CHANGELOG" ]; then
  die "$CHANGELOG is a symlink; refusing to read or replace it"
fi
# CHANGELOG.md is refused, in --check and assembly alike, when it ends inside
# an open fence (appended entries would render as code) or has a heading line
# with a tab (`##<TAB>…` renders as a heading but is no insertion point).
if [ -e "$CHANGELOG" ]; then
  scan="$(awk "$fence_awk"'
    fence_step($0) { next }
    infence { next }
    /^ ? ? ?#+[ \t]/ && /\t/ { printf "E\t%d\n", NR; next }
    /^## / { print "H\t" $0 }
    END { if (infence) print "F\t" NR }' "$CHANGELOG")" \
    || die "$CHANGELOG could not be read"
  existing=""
  while IFS="$(printf '\t')" read -r kind rest; do
    case "$kind" in
      H) existing="$existing$rest
" ;;
      E) err "$CHANGELOG:$rest — tab in a heading line; use single spaces" ;;
      F) err "$CHANGELOG — ends inside an open code fence (opened before line $rest); close it" ;;
    esac
  done <<<"$scan"
  for i in "${!FRAGS[@]}"; do
    f="${FRAGS[$i]}"
    if ! heads="$(awk '/^## / { print }' "$f")"; then
      err "$f — could not be read"
      continue
    fi
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      # Here-string, not a pipe: grep -q exits at the first match, and under
      # pipefail the writer's SIGPIPE would turn that hit into a miss.
      if grep -qxF -- "$h" <<<"$existing"; then
        err "$f — entry '$h' is already in $CHANGELOG (already assembled? delete the fragment)"
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

# ── PR scope: at most one fragment added ───────────────────────────
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
[ -f "$CHANGELOG" ] || die "$CHANGELOG not found in $ROOT"
head -n 1 "$CHANGELOG" | grep -q '^# ' \
  || die "$CHANGELOG must start with a '# ' title line"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/assemble-changelog.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

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

# Merge by date: before each existing unfenced `## YYYY-MM-DD` entry, emit
# every pending entry dated on or after it (pending entries are newer than any
# existing one of the same date). What is left goes at the end. Each entry's
# trailing blank lines are trimmed; entries are separated by one blank line.
# A failed read of an entry file exits non-zero rather than dropping it.
awk -v list="$TMP/sorted" "$fence_awk"'
function emit(file,   n, l, a, j, last, r) {
  n = 0
  while ((r = (getline l < file)) > 0) a[++n] = l
  if (r < 0) { printf "cannot read %s\n", file > "/dev/stderr"; exit 2 }
  close(file)
  last = n; while (last > 0 && a[last] ~ /^[[:space:]]*$/) last--
  if (!lastblank) print ""
  for (j = 1; j <= last; j++) print a[j]
  print ""; lastblank = 1
}
BEGIN {
  while ((r = (getline l < list)) > 0) { split(l, f, "\t"); np++; pd[np] = f[1]; pf[np] = f[4] }
  if (r < 0) { printf "cannot read %s\n", list > "/dev/stderr"; exit 2 }
  close(list); p = 1; lastblank = 1
}
{ isf = fence_step($0) }
!isf && !infence && /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
  d = substr($0, 4, 10)
  while (p <= np && pd[p] >= d) emit(pf[p++])
}
{ print; lastblank = ($0 ~ /^[[:space:]]*$/) }
END {
  # Entries older than every existing one; the trim after this awk drops the
  # blank line the last one leaves at end of file.
  while (p <= np) emit(pf[p++])
}' "$CHANGELOG" | awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (j = 1; j <= last; j++) print lines[j] }' >"$TMP/CHANGELOG.new"

# Same-directory rename so a failure never leaves a half-written changelog.
# mktemp creates the staging file exclusively, so a pre-planted name (say, a
# symlink to some other file) can never be written through.
stage="$(mktemp "$CHANGELOG.assemble.XXXXXX")" || die "cannot create a staging file beside $CHANGELOG"
# mktemp makes it 0600; CHANGELOG.md is a tracked non-executable file (0644).
if ! cat "$TMP/CHANGELOG.new" >"$stage" || ! chmod 644 "$stage" || ! mv -f "$stage" "$CHANGELOG"; then
  rm -f -- "$stage"
  die "could not replace $CHANGELOG; fragments were left in place"
fi
for i in "${!FRAGS[@]}"; do
  rm -f -- "${FRAGS[$i]}"
done

entries="$(wc -l <"$TMP/sorted" | tr -d ' ')"
echo "assemble-changelog: folded $entries entr$([ "$entries" = 1 ] && echo y || echo ies) from $n fragment(s) into $CHANGELOG"
echo "  review with: git diff -- $CHANGELOG $FRAG_DIR/   then stage both"
