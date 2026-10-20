#!/usr/bin/env bash
# migrate-operator-queue.sh — move ~/.claude/operator-queue.md items to GitHub
# issues labelled `operator-action` in a private repo, so the queue can be read
# from a phone and from cloud sessions (OperatorQueueReminder.hook.sh lists them).
#
# Dry-run by default: prints one row per "## <slug>" block — slug, project
# label, and the target (an existing issue with the same title in any state
# and with any labels, or "new"). Nothing is written. --apply creates the
# missing labels and one issue per "new" row; rows that already have an issue
# are skipped, so a re-run after a partial apply only creates what is missing.
# A matched issue lacking `operator-action` (or the row's project label) gets
# it, since the hook lists only labelled issues; a failed relabel fails the run.
# A matched issue whose body lacks the block's `- action:` line (hand-filed)
# is reported "needs manual merge: #N" and left alone; an apply then fails.
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
# The repo defaults to OPERATOR_QUEUE_REPO, the hook's own setting, so the
# issues land where the hook reads them. --apply holds a per-repo flock(1)
# from the existing-title check to the last create, so two applies on this
# machine never both create one title; it refuses without flock. Two applies
# on different machines at once are not serialised — run it from one.
#
# This script never edits the queue file. Once the issues are checked, retire
# the file by adding the historical banner as its first line; the hook then
# switches to the issues.
#
# Usage: migrate-operator-queue.sh [--apply] [--repo [host/]owner/name] [--queue path]
# EXIT: 0 ok; 1 a gh call or relabel failed, an item needs a manual merge, the
#   repo is not private, or another apply
#   holds the lock (or flock is missing); 2 usage error.
# SELF-TEST: claude/scripts/tests/migrate-operator-queue.test.sh
set -euo pipefail

REPO="${OPERATOR_QUEUE_REPO:-github.com/jckeen/claude-memory}"
QUEUE="$HOME/.claude/operator-queue.md"
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --repo) REPO="${2:?--repo needs owner/name}"; shift ;;
    --queue) QUEUE="${2:?--queue needs a path}"; shift ;;
    -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -s "$QUEUE" ] || { echo "no queue at $QUEUE" >&2; exit 2; }
# Resolve the host exactly as OperatorQueueReminder.hook.sh does: a bare
# owner/name means github.com, never gh's GH_HOST or configured default, so
# the issues land where the hook will read them.
case "$REPO" in */*/*) ;; *) REPO="github.com/$REPO" ;; esac

read -r visibility canonical < <(gh repo view "$REPO" --json visibility,nameWithOwner \
  -q '"\(.visibility) \(.nameWithOwner)"') && [ -n "${canonical:-}" ] || {
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

if [ "$APPLY" -eq 1 ]; then
  command -v flock >/dev/null 2>&1 || {
    echo "refusing: --apply needs flock(1) to keep concurrent runs from duplicating issues" >&2; exit 1; }
  lockdir="${XDG_STATE_HOME:-$HOME/.local/state}/operator-queue"
  mkdir -p "$lockdir"
  # Keyed on GitHub's own name for the repo, lowercased: o/r, O/R and a
  # renamed repo's old name all reach one repo, so they must share one lock.
  key="$(printf '%s/%s' "${REPO%%/*}" "$canonical" | tr '[:upper:]' '[:lower:]' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } 2>/dev/null | cut -c1-64)" || key=""
  [ "${#key}" -eq 64 ] || { echo "refusing: --apply needs sha256sum or shasum to name its lock" >&2; exit 1; }
  exec 9>> "$lockdir/migrate-$key.lock"
  flock -n 9 || { echo "refusing: another --apply for $REPO is running" >&2; exit 1; }
fi

# Existing issues in any state and with any labels, by exact title: an
# issue whose operator-action label was removed (after a partial migration,
# or one filed by hand) still has the title, and gh's --label would hide it.
# TAB-separated typed records, so no label or line boundary is ever lost to
# a join (GitHub allows commas in label names):
#   T <title> <number> <has operator-action: true|false>  one per issue
#   L <number> <label>                                    one per label
#   A <number> <body line starting "- action:">           one per such line
# Membership in operator-action is decided in jq on the label array; the
# project label and the action line are exact whole-record matches below.
LIST_LIMIT=10000
gh issue list -R "$REPO" --state all --limit "$LIST_LIMIT" --json number,title,labels,body \
  -q '.[] | .number as $n
      | "T\t\(.title)\t\($n)\t\(any(.labels[]; .name == "operator-action"))",
        ("L\t\($n)\t\(.labels[].name)"),
        ((.body // "") | gsub("\r"; "") | split("\n")[] | select(startswith("- action:"))
          | gsub("\t"; " ") | "A\t\($n)\t\(.)")' \
  > "$work/existing.tsv"
# The dedup is only sound over the complete list: a full page could hide a
# title past the limit, and its block would be created twice.
if [ "$(grep -c '^T' "$work/existing.tsv" || true)" -ge "$LIST_LIMIT" ]; then
  echo "refusing: $REPO has $LIST_LIMIT+ issues; the existing-title check would be incomplete" >&2
  exit 1
fi

# Labels first, so no create below fails on a missing one.
if [ "$APPLY" -eq 1 ]; then
  gh label list -R "$REPO" --limit 1000 --json name -q '.[].name' > "$work/labels.txt"
  { echo "operator-action"; cut -f3 "$work/index.tsv" | { grep -vx -- "-" || true; } | sed 's/^/project:/'; } |
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

# has_rec <type> <number> <value> — an exact "<type> TAB <number> TAB <value>"
# record exists (ENVIRON, not -v, so backslashes stay literal).
has_rec() {
  k="$1" n="$2" v="$3" awk -F'\t' '
    $1 == ENVIRON["k"] && ($2 "") == (ENVIRON["n"] "") &&
    substr($0, length($1) + length($2) + 3) == ENVIRON["v"] { f = 1; exit }
    END { exit !f }' "$work/existing.tsv"
}

today="$(date +%Y-%m-%d)"
total=0; new=0; existing=0; relabel=0; relabel_failed=0; manual=0
printf '%-48s  %-24s  %s\n' "SLUG" "LABEL" "TARGET"
while IFS=$'\t' read -r n slug group; do
  total=$((total + 1))
  label="project:$group"; [ "$group" = "-" ] && label="(none)"
  # ENVIRON, not -v: awk -v would turn a backslash in the title into an escape.
  # The "" concatenations force a string comparison: awk would otherwise
  # compare numeric-looking titles as numbers ("1" == "001", "1e2" == "100").
  match="$(t="$slug" awk -F'\t' '$1 == "T" && ($2 "") == (ENVIRON["t"] "") { print $3 "\t" $4; exit }' "$work/existing.tsv")"
  num="${match%%$'\t'*}"
  if [ -n "$num" ]; then
    existing=$((existing + 1))
    # A same-title issue whose body lacks this block's action line (filed by
    # hand, or edited since) is not the migrated item; adopting it would
    # retire the block's action, deadline and dates. It is left for the
    # operator to merge, and an apply then fails.
    action_line="$(grep -m1 '^- action:' "$work/$n.body" 2>/dev/null || true)"
    if [ -n "$action_line" ] && ! has_rec A "$num" "$action_line"; then
      manual=$((manual + 1))
      printf '%-48s  %-24s  %s\n' "$slug" "$label" "needs manual merge: #$num (its body lacks this block's action line)"
      continue
    fi
    # The hook lists only operator-action issues: a matched issue lacking the
    # labels this migration would set drops out of the reminders once the
    # file is retired, so it gets them rather than counting as migrated.
    missing=""
    [ "${match#*$'\t'}" = true ] || missing="operator-action"
    if [ "$group" != "-" ] && ! has_rec L "$num" "$label"; then
      missing="${missing:+$missing,}$label"
    fi
    target="#$num (exists, skipped)"
    if [ -n "$missing" ]; then
      relabel=$((relabel + 1))
      if [ "$APPLY" -ne 1 ]; then
        target="#$num (exists, would relabel #$num: $missing)"
      elif gh issue edit "$num" -R "$REPO" --add-label "$missing" >/dev/null; then
        target="#$num (exists, relabelled #$num: $missing)"
      else
        relabel_failed=$((relabel_failed + 1))
        target="#$num (exists, could not relabel #$num: $missing)"
      fi
    fi
    printf '%-48s  %-24s  %s\n' "$slug" "$label" "$target"
    continue
  fi
  new=$((new + 1))
  printf '%-48s  %-24s  %s\n' "$slug" "$label" "new"
  [ "$APPLY" -eq 1 ] || continue
  printf '\nMigrated from ~/.claude/operator-queue.md on %s.\n' "$today" >> "$work/$n.body"
  args=(issue create -R "$REPO" --title "$slug" --label operator-action --body-file "$work/$n.body")
  [ "$group" = "-" ] || args+=(--label "$label")
  url="$(gh "${args[@]}")"
  # Record it, so a repeated title later in this same queue is skipped too.
  num="${url##*/}"
  {
    printf 'T\t%s\t%s\ttrue\n' "$slug" "$num"
    [ "$group" = "-" ] || printf 'L\t%s\t%s\n' "$num" "$label"
    grep '^- action:' "$work/$n.body" | while IFS= read -r l; do printf 'A\t%s\t%s\n' "$num" "$l"; done || true
  } >> "$work/existing.tsv"
done < "$work/index.tsv"

echo ""
if [ "$APPLY" -eq 1 ]; then
  echo "$total item(s): $new created, $existing already had an issue ($relabel relabelled, $manual need a manual merge)."
  if [ "$relabel_failed" -gt 0 ] || [ "$manual" -gt 0 ]; then
    [ "$relabel_failed" -eq 0 ] || echo "$relabel_failed relabel(s) failed; those issues lack operator-action or their project label, so the hook would not show them." >&2
    [ "$manual" -eq 0 ] || echo "$manual item(s) match an issue whose body lacks the block's action line; merge each block into its issue by hand." >&2
    echo "Not fully migrated: the queue file is still the source." >&2
    exit 1
  fi
  echo "Check: gh issue list -R $REPO --label operator-action --state open --limit 1000 | wc -l"
  echo "Then retire the file: put '> **Historical** — point-in-time record ($today). Do not act on this.' as its first line."
else
  echo "$total item(s): $new would be created, $existing already have an issue ($relabel would be relabelled, $manual need a manual merge). Dry run — re-run with --apply to create them."
fi
