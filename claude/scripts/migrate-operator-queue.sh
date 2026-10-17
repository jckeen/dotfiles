#!/usr/bin/env bash
# migrate-operator-queue.sh — move ~/.claude/operator-queue.md items to GitHub
# issues labelled `operator-action` in a private repo, so the queue can be read
# from a phone and from cloud sessions (OperatorQueueReminder.hook.sh lists them).
#
# Dry-run by default: prints one row per "## <slug>" block — slug, project
# label, and the target (an existing issue with the same title in any state, or
# "new"). Nothing is written. --apply creates the missing labels and one issue
# per "new" row; rows that already have an issue are skipped, so a re-run after
# a partial apply only creates what is missing.
#
# Each issue's title is the slug and its body is the block's own field lines
# verbatim (`- added:`, `- verified:`, `- project:`, `- deadline:`, `- action:`),
# so the hook keeps each item's real age and freshness rather than the
# migration date. Labels: `operator-action` plus `project:<first word of the
# project value, lowercased>` (the word the hook groups by).
#
# The queue names credentials, providers and pending decisions, so the target
# repo must be private: the script refuses, in both modes, when GitHub does not
# report the repo's visibility as PRIVATE.
#
# This script never edits the queue file. Once the issues are checked, retire
# the file by adding the historical banner as its first line; the hook then
# switches to the issues.
#
# Usage: migrate-operator-queue.sh [--apply] [--repo owner/name] [--queue path]
# EXIT: 0 ok; 1 a gh call failed or the repo is not private; 2 usage error.
# SELF-TEST: claude/scripts/tests/migrate-operator-queue.test.sh
set -euo pipefail

REPO="jckeen/claude-memory"
QUEUE="$HOME/.claude/operator-queue.md"
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --repo) REPO="${2:?--repo needs owner/name}"; shift ;;
    --queue) QUEUE="${2:?--queue needs a path}"; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -s "$QUEUE" ] || { echo "no queue at $QUEUE" >&2; exit 2; }

visibility="$(gh repo view "$REPO" --json visibility -q .visibility)" || {
  echo "could not read $REPO's visibility" >&2; exit 1; }
if [ "$visibility" != "PRIVATE" ]; then
  echo "refusing: $REPO is $visibility — operator items must go to a private repo" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Split the queue: one file per block holding its field lines, plus an index of
# "<n> TAB <slug> TAB <label>". "-" stands in for a missing project so no TSV
# field is ever empty (an empty field would collapse under a tab-IFS read).
LC_ALL=C awk -v dir="$work" '
  function flush() {
    if (slug == "") return
    group = (match(project, /[A-Za-z0-9._-]+/)) ? tolower(substr(project, RSTART, RLENGTH)) : "-"
    printf "%03d\t%s\t%s\n", n, slug, group > (dir "/index.tsv")
    close(file)
  }
  { sub(/\r$/, ""); gsub(/\t/, " ") }
  /^## / { flush(); n++; slug = substr($0, 4); project = ""; file = sprintf("%s/%03d.body", dir, n); next }
  slug != "" && /^- (added|verified|project|deadline|action):/ {
    print > file
    if ($0 ~ /^- project:/) { project = $0; sub(/^- project:[ ]*/, "", project) }
  }
  END { flush() }
' "$QUEUE"
[ -s "$work/index.tsv" ] || { echo "no \"## <slug>\" blocks in $QUEUE" >&2; exit 2; }

# Existing operator-action issues in any state, by exact title.
gh issue list -R "$REPO" --label operator-action --state all --limit 1000 \
  --json number,title -q '.[] | "\(.title)\t\(.number)"' > "$work/existing.tsv"

# Labels first, so no create below fails on a missing one.
if [ "$APPLY" -eq 1 ]; then
  gh label list -R "$REPO" --limit 1000 --json name -q '.[].name' > "$work/labels.txt"
  { echo "operator-action"; cut -f3 "$work/index.tsv" | grep -vx -- '-' | sed 's/^/project:/'; } |
    sort -u > "$work/wanted.txt"
  while read -r l; do
    grep -qxF -- "$l" "$work/labels.txt" && continue
    if [ "$l" = "operator-action" ]; then
      gh label create "$l" -R "$REPO" --color B60205 --description "Only the operator can do this" >/dev/null
    else
      gh label create "$l" -R "$REPO" --color C5DEF5 >/dev/null
    fi
  done < "$work/wanted.txt"
fi

today="$(date +%Y-%m-%d)"
total=0; new=0; existing=0
printf '%-48s  %-24s  %s\n' "SLUG" "LABEL" "TARGET"
while IFS=$'\t' read -r n slug group; do
  total=$((total + 1))
  label="project:$group"; [ "$group" = "-" ] && label="(none)"
  num="$(awk -F'\t' -v t="$slug" '$1 == t { print $2; exit }' "$work/existing.tsv")"
  if [ -n "$num" ]; then
    existing=$((existing + 1))
    printf '%-48s  %-24s  %s\n' "$slug" "$label" "#$num (exists, skipped)"
    continue
  fi
  new=$((new + 1))
  printf '%-48s  %-24s  %s\n' "$slug" "$label" "new"
  [ "$APPLY" -eq 1 ] || continue
  printf '\nMigrated from ~/.claude/operator-queue.md on %s.\n' "$today" >> "$work/$n.body"
  args=(issue create -R "$REPO" --title "$slug" --label operator-action --body-file "$work/$n.body")
  [ "$group" = "-" ] || args+=(--label "$label")
  gh "${args[@]}" >/dev/null
done < "$work/index.tsv"

echo ""
if [ "$APPLY" -eq 1 ]; then
  echo "$total item(s): $new created, $existing already had an issue."
  echo "Check: gh issue list -R $REPO --label operator-action --state open --limit 1000 | wc -l"
  echo "Then retire the file: put '> **Historical** — point-in-time record ($today). Do not act on this.' as its first line."
else
  echo "$total item(s): $new would be created, $existing already have an issue. Dry run — re-run with --apply to create them."
fi
