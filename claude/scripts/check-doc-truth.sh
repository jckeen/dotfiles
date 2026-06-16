#!/usr/bin/env bash
# check-doc-truth.sh — portable doc-contract checker (ADR 0005).
#
# Asserts a repo's .doc-contract: every git-tracked *.md is declared in a
# tier, HISTORICAL docs carry a point-in-time marker, relative links in
# LIVING/GENERATED docs resolve, and BANNED patterns are absent from their
# scoped tiers. Dependency-free: bash + git + grep + coreutils.
#
# Contract lines (first tier match wins, like .gitignore):
#   LIVING|GENERATED|SOURCE|HISTORICAL  <bash glob, repo-relative>
#   BANNED[:TIER[,TIER]]                <grep -Ei regex>
#     (unscoped BANNED applies to LIVING,GENERATED,SOURCE)
#   # comments and blank lines ignored
#
# Usage: check-doc-truth.sh [contract-path]     (default: .doc-contract)
# Exit: 0 clean, 1 on any violation or malformed contract.
# Requires bash 4+ (mapfile).
#
# Canonical copy: dotfiles claude/scripts/check-doc-truth.sh. Other repos get
# a vendored copy via /drift-sweep bootstrap. DOC_TRUTH_VERSION=2

set -uo pipefail

CONTRACT="${1:-.doc-contract}"

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "✖ doc-truth: not inside a git repository" >&2
  exit 1
fi
cd "$REPO_ROOT" || exit 1

if [[ ! -f "$CONTRACT" ]]; then
  echo "✖ doc-truth: contract '$CONTRACT' not found in $REPO_ROOT" >&2
  exit 1
fi

violations=0
fail() {
  printf '✖ %s\n' "$1"
  violations=$((violations + 1))
}

# ── Parse the contract ─────────────────────────────────────────────
TIER_NAMES=()
TIER_GLOBS=()
BANNED_RES=()
BANNED_SCOPES=()

lineno=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
  lineno=$((lineno + 1))
  line="${raw%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  keyword="${line%%[[:space:]]*}"
  rest="${line#"$keyword"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  rest="${rest%"${rest##*[![:space:]]}"}"
  case "$keyword" in
    LIVING | GENERATED | SOURCE | HISTORICAL)
      if [[ -z "$rest" ]]; then
        fail "$CONTRACT:$lineno — contract — $keyword line has no path"
        continue
      fi
      TIER_NAMES+=("$keyword")
      TIER_GLOBS+=("$rest")
      ;;
    BANNED | BANNED:*)
      if [[ -z "$rest" ]]; then
        fail "$CONTRACT:$lineno — contract — BANNED line has no regex"
        continue
      fi
      printf '' | grep -qE -- "$rest" 2>/dev/null
      if [[ "$?" -ge 2 ]]; then
        fail "$CONTRACT:$lineno — contract — BANNED regex is invalid: /$rest/"
        continue
      fi
      scope="LIVING,GENERATED,SOURCE"
      if [[ "$keyword" == BANNED:* ]]; then
        scope="${keyword#BANNED:}"
        if [[ -z "$scope" ]]; then
          fail "$CONTRACT:$lineno — contract — BANNED scope list is empty"
          continue
        fi
        scope_ok=1
        for s in ${scope//,/ }; do
          case "$s" in
            LIVING | GENERATED | SOURCE | HISTORICAL) ;;
            *)
              fail "$CONTRACT:$lineno — contract — unknown BANNED scope '$s'"
              scope_ok=0
              ;;
          esac
        done
        [[ "$scope_ok" -eq 1 ]] || continue
      fi
      BANNED_RES+=("$rest")
      BANNED_SCOPES+=("$scope")
      ;;
    *)
      fail "$CONTRACT:$lineno — contract — unknown keyword '$keyword'"
      ;;
  esac
done < "$CONTRACT"

# ── Rule 1: coverage — every tracked markdown file has a tier ──────
tier_of() {
  local f="$1" i
  for i in "${!TIER_GLOBS[@]}"; do
    # shellcheck disable=SC2053  # RHS is intentionally a glob
    if [[ "$f" == ${TIER_GLOBS[$i]} ]]; then
      printf '%s' "${TIER_NAMES[$i]}"
      return 0
    fi
  done
  return 1
}

mapfile -t MD_FILES < <(git ls-files -- '*.md' '*.MD' '*.markdown')
FILES=()
TIERS=()
for f in "${MD_FILES[@]}"; do
  if tier="$(tier_of "$f")"; then
    FILES+=("$f")
    TIERS+=("$tier")
  else
    fail "$f — coverage — not declared in $CONTRACT (add a LIVING/GENERATED/SOURCE/HISTORICAL entry)"
  fi
done

# ── Rule 2: stale non-glob contract entries ────────────────────────
for i in "${!TIER_GLOBS[@]}"; do
  g="${TIER_GLOBS[$i]}"
  [[ "$g" == *[\*\?\[]* ]] && continue
  git ls-files --error-unmatch -- "$g" >/dev/null 2>&1 \
    || fail "$CONTRACT — stale-entry — '${TIER_NAMES[$i]} $g' matches no tracked file"
done

# ── Rule 3: HISTORICAL files carry a point-in-time marker ──────────
for i in "${!FILES[@]}"; do
  [[ "${TIERS[$i]}" == HISTORICAL ]] || continue
  f="${FILES[$i]}"
  head5="$(head -n 5 "$f")"
  if grep -qi 'historical' <<<"$head5" && grep -qi 'point-in-time' <<<"$head5"; then
    continue
  fi
  if grep -q '\*\*Status:\*\*' <<<"$head5" && grep -q '\*\*Date:\*\*' <<<"$head5"; then
    continue # ADR-style header is an accepted temporal marker
  fi
  fail "$f — banner — HISTORICAL doc needs the point-in-time banner (or ADR Status/Date header) in its first 5 lines"
done

# ── Rule 4: dead relative links in LIVING + GENERATED ──────────────
# Covers inline [text](target) and reference definitions [label]: target.
# CHANGELOG* exempt: append-only narrative; old links rot legitimately.
# Fenced code blocks and inline code spans are stripped first (regexes like
# `[a-z](?:...)` would otherwise parse as links); blanked lines keep numbering.
# BANNED (Rule 5) intentionally still sees code spans and fences.
strip_code() {
  awk '
    /^[[:space:]]*(```|~~~)/ { infence = !infence; print ""; next }
    infence                  { print ""; next }
                             { gsub(/`[^`]*`/, ""); print }
  '
}
check_link_target() { # file lineno raw-target dir
  local f="$1" ln="$2" target="$3" dir="$4"
  if [[ "$target" == \<* ]]; then
    target="${target#<}"
    target="${target%%>*}"
  else
    # strip markdown title forms: "title", 'title', (title)
    target="${target%% \"*}"
    target="${target%% \'*}"
    target="${target%% (*}"
  fi
  case "$target" in
    http://* | https://* | mailto:* | /* | "#"*) return 0 ;;
  esac
  target="${target%%#*}"
  [[ -z "$target" ]] && return 0
  target="${target//%20/ }"
  [[ -e "$dir/$target" ]] \
    || fail "$f:$ln — dead-ref — link target '$target' not found"
}

for i in "${!FILES[@]}"; do
  t="${TIERS[$i]}"
  [[ "$t" == LIVING || "$t" == GENERATED ]] || continue
  f="${FILES[$i]}"
  base="$(basename "$f")"
  [[ "$base" == CHANGELOG* ]] && continue
  dir="$(dirname "$f")"
  stripped="$(strip_code < "$f")"
  while IFS= read -r m; do
    ln="${m%%:*}"
    target="${m#*:}"
    target="${target#"]("}"
    target="${target%)}"
    check_link_target "$f" "$ln" "$target" "$dir"
  done < <(grep -onE '\]\([^)]+\)' <<<"$stripped" || true)
  while IFS= read -r m; do
    ln="${m%%:*}"
    rest="${m#*:}"
    target="${rest#*]:}"
    target="${target#"${target%%[![:space:]]*}"}"
    check_link_target "$f" "$ln" "$target" "$dir"
  done < <(grep -onE '^[[:space:]]{0,3}\[[^]^][^]]*\]:[[:space:]]*(<[^>]*>|[^[:space:]]+)' <<<"$stripped" || true)
done

# ── Rule 5: BANNED patterns absent from their scoped tiers ─────────
for b in "${!BANNED_RES[@]}"; do
  re="${BANNED_RES[$b]}"
  scope=",${BANNED_SCOPES[$b]},"
  for i in "${!FILES[@]}"; do
    [[ "${TIERS[$i]}" == HISTORICAL ]] && continue # always exempt per ADR
    [[ "$scope" == *",${TIERS[$i]},"* ]] || continue
    f="${FILES[$i]}"
    while IFS=: read -r ln _; do
      [[ -n "$ln" ]] || continue
      fail "$f:$ln — banned — matches /$re/ (scope: ${BANNED_SCOPES[$b]})"
    done < <(grep -inE -- "$re" "$f" || true)
  done
done

# ── Summary ────────────────────────────────────────────────────────
if [[ "$violations" -gt 0 ]]; then
  echo ""
  echo "doc-truth: FAILED — $violations violation(s). Fix the doc or update $CONTRACT."
  exit 1
fi
echo "doc-truth: OK — ${#MD_FILES[@]} markdown files conform to $CONTRACT"
