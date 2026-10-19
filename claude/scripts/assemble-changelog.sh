#!/usr/bin/env bash
# assemble-changelog.sh — fold per-PR changelog fragments into CHANGELOG.md.
#
# Every PR used to prepend its entry to the head of CHANGELOG.md, so each merge
# to main made every other open PR conflict on the same lines and re-run the
# whole review gate (#626). Instead a PR adds one fragment:
#
#   changelog.d/<branch-slug>.md      branch name with every `/` turned to `-`
#
# holding one entry exactly as it will read in CHANGELOG.md — a
#   ## YYYY-MM-DD — <type>(<scope>)?!?: <summary>
# heading (types: the conventional set check-commit-format.sh enforces)
# followed by at least one bullet. Several `## ` entries in one fragment are
# allowed. Two PRs then never touch the same file.
#
# Assembly is a manual step (release or handoff time), not a bot push to main:
# main's required status checks refuse a commit that has not run them, and a
# GITHUB_TOKEN push would never trigger them. Until assembly, changelog.d/ IS
# the head of the changelog.
#
# Usage:
#   assemble-changelog.sh            fold every fragment into CHANGELOG.md
#                                    (newest date first; ties by filename, then
#                                    order within the file), inserted above the
#                                    first `## ` entry, then delete the
#                                    fragments. No fragments: a no-op.
#   assemble-changelog.sh --check    validate every fragment; write nothing
#     [--base REF [--branch NAME]]   also: REF...HEAD adds at most one
#                                    fragment, and it is named after NAME
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
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

CHECK=0
BASE=""
BRANCH=""
ROOT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --base)
      [ "$#" -ge 2 ] || die "--base needs a git ref" 2
      BASE="$2"
      shift
      ;;
    --branch)
      [ "$#" -ge 2 ] || die "--branch needs a branch name" 2
      BRANCH="$2"
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

if [ -n "$BRANCH" ] && [ -z "$BASE" ]; then
  die "--branch only applies with --base" 2
fi
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

if [ -d "$FRAG_DIR" ]; then
  # The three globs cover every name but `.` and `..`, dotfiles included.
  for f in "$FRAG_DIR"/* "$FRAG_DIR"/.[!.]* "$FRAG_DIR"/..?*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    name="${f#"$FRAG_DIR"/}"
    case "$name" in
      .gitkeep) continue ;;
    esac
    if [ -L "$f" ] || [ ! -f "$f" ]; then
      err "$f — not a regular file; $FRAG_DIR/ holds only <branch-slug>.md fragments"
      continue
    fi
    case "$name" in
      *.md) ;;
      *)
        err "$f — not a .md fragment; $FRAG_DIR/ holds only <branch-slug>.md fragments"
        continue
        ;;
    esac
    if ! printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*\.md$'; then
      err "$f — fragment name must be <branch-slug>.md (letters, digits, '.', '_', '-')"
      continue
    fi
    FRAGS+=("$f")
  done
elif [ -e "$FRAG_DIR" ]; then
  die "$FRAG_DIR exists but is not a directory"
fi

# ── Fence tracking, shared by every awk pass ───────────────────────
# A `#` or `## ` line inside a fenced code block is content, not a heading.
# CommonMark rules: a fence opens with 3+ backticks or tildes indented at most
# three spaces, and only a run of the SAME character at least as long, with
# nothing after it, closes it — so a ```` block may hold ``` lines. Sets
# `infence`; returns 1 when the line opened or closed a fence.
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
  entries = 0; seen_content = 0; bullets = 0; infence = 0
}
function close_entry() {
  if (entries > 0 && bullets == 0) printf "%d\tentry has no bullet (\"- ...\") under its heading\n", entry_line
}
/\r/ { printf "%d\tCRLF line ending; use LF\n", NR; next }
fence_step($0) { if (entries == 0 && !seen_content) { printf "%d\tcontent before the first ## heading\n", NR; seen_content = 1 }; next }
infence { next }
/^# / || /^#$/ { printf "%d\ttop-level \"# \" heading; a fragment holds only ## entries\n", NR; next }
/^## / {
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
  if ($0 ~ /^[[:space:]]*[-*] /) bullets++
}
END {
  if (infence) printf "%d\tunclosed code fence\n", NR
  close_entry()
  if (entries == 0) printf "0\tno \"## YYYY-MM-DD — <type>: <summary>\" entry\n"
}'

# awk runs in a command substitution, not a process substitution, so a failed
# read (an unreadable fragment) is an error rather than an empty, clean report.
for i in "${!FRAGS[@]}"; do
  f="${FRAGS[$i]}"
  if ! report="$(awk -v types="$TYPES" "$fence_awk $validate_awk" "$f")"; then
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
if [ -f "$CHANGELOG" ]; then
  for i in "${!FRAGS[@]}"; do
    f="${FRAGS[$i]}"
    if ! heads="$(awk "$fence_awk"' fence_step($0) { next } !infence && /^## / { print }' "$f")"; then
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
        err "$CHANGELOG — could not be read"
      fi
    done <<<"$heads"
  done
fi

# ── PR scope: at most one fragment added, named after the branch ───
if [ -n "$BASE" ]; then
  git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
    || die "--base '$BASE' is not a commit here (fetch it, or fetch-depth: 0 in CI)"
  added="$(git diff --name-only --diff-filter=A "$BASE...HEAD" -- "$FRAG_DIR/")" \
    || die "git diff $BASE...HEAD failed"
  n_added=0
  [ -z "$added" ] || n_added="$(printf '%s\n' "$added" | wc -l | tr -d ' ')"
  if [ "$n_added" -gt 1 ]; then
    err "this branch adds $n_added fragments; a PR adds exactly one $FRAG_DIR/<branch-slug>.md (several ## entries may share it):
$(printf '%s\n' "$added" | sed 's/^/    /')"
  elif [ "$n_added" -eq 1 ] && [ -n "$BRANCH" ]; then
    want="$FRAG_DIR/${BRANCH//\//-}.md"
    [ "$added" = "$want" ] \
      || err "fragment '$added' is not named after branch '$BRANCH'; expected '$want'"
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
  awk -v out="$TMP/e.$i." -v name="${f#"$FRAG_DIR"/}" "$fence_awk"'
    { fence_step($0) }
    !infence && /^## / { k++; file = out k; printf "%s\t%s\t%d\t%s\n", substr($0, 4, 10), name, k, file >> idx }
    k { print > file }
  ' idx="$TMP/index" "$f"
  n=$((n + 1))
done

# Newest date first; ties by fragment name, then position within the fragment.
sort -t "$tab" -k1,1r -k2,2 -k3,3n "$TMP/index" >"$TMP/sorted"

# Entry bodies with trailing blank lines trimmed, one blank line between.
: >"$TMP/block"
while IFS="$tab" read -r _ _ _ efile; do
  awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (j = 1; j <= last; j++) print lines[j] }' "$efile" >>"$TMP/block"
  echo >>"$TMP/block"
done <"$TMP/sorted"

# Insert above the first top-level `## ` entry (after the title and any
# preamble); a changelog with no entries gets the block appended.
first="$(awk "$fence_awk"' fence_step($0) { next } !infence && /^## / { print NR; exit }' "$CHANGELOG")"
{
  if [ -n "$first" ]; then
    head -n "$((first - 1))" "$CHANGELOG" \
      | awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (j = 1; j <= last; j++) print lines[j] }'
    echo
    cat "$TMP/block"
    tail -n "+$first" "$CHANGELOG"
  else
    awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (j = 1; j <= last; j++) print lines[j] }' "$CHANGELOG"
    echo
    # Drop the block's own trailing blank line at end of file.
    awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (j = 1; j <= last; j++) print lines[j] }' "$TMP/block"
  fi
} >"$TMP/CHANGELOG.new"

# Same-directory rename so a failure never leaves a half-written changelog.
cp "$TMP/CHANGELOG.new" "$CHANGELOG.assemble.tmp"
mv -f "$CHANGELOG.assemble.tmp" "$CHANGELOG"
for i in "${!FRAGS[@]}"; do
  rm -f -- "${FRAGS[$i]}"
done

entries="$(wc -l <"$TMP/sorted" | tr -d ' ')"
echo "assemble-changelog: folded $entries entr$([ "$entries" = 1 ] && echo y || echo ies) from $n fragment(s) into $CHANGELOG"
echo "  review with: git diff -- $CHANGELOG $FRAG_DIR/   then stage both"
