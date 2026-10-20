## 2026-10-19 — fix(hooks): operator-queue reminder bounds its snapshot, cleans refresh temporaries, prints status only

- **`claude/hooks/OperatorQueueReminder.hook.sh`** (#654): the SessionStart
  snapshot of the issue cache is now cut at one byte over the 64 KiB render
  limit, so an oversized cache no longer gets copied whole into the temp
  dir before the size guard refuses it. The cache is opened once on a file
  descriptor. The bytes and the mtime both come from that one file, so the
  one-snapshot property holds even if a refresh renames a new cache over it
  mid-copy. An oversized snapshot is never read as "no open issues".
- Same hook (#654): a refresh shell sent TERM, INT or HUP removes its
  `.raw.*`/`.new.*` temporaries on the way out. A refresh that recovers a
  killed predecessor's in-flight marker removes that predecessor's
  temporaries: only this cache's own mktemp names in the state dir, only
  files owned by the user. This is safe under the lock, because every fetch
  worker inherits the lock's descriptor. The flock serialisation, the
  in-flight/failure markers and their ordering are unchanged.
- Same hook (#652): the output is descriptive status only. The closing line
  that told the session to re-check items, comment on or close issues, or
  bump `verified:` dates is replaced by one saying what the items are and
  where their verified date comes from. The warning lines now name the `gh`
  command that lists the issues, without telling anyone to run it. The rule
  for how a session acts on an item moves to the handoff skill through the
  operator lane.
- **`claude/scripts/migrate-operator-queue.sh`** (#654): the existing-title
  check now lists issues with any labels (still in every state), so an issue
  whose `operator-action` label was removed still blocks a duplicate create
  and reruns stay safe. The check covers up to 10000 issues and refuses at
  that limit rather than dedupe over a partial list. A matched issue that
  lacks `operator-action` or the row's `project:` label gets the missing
  labels on `--apply` (`gh issue edit --add-label`, pinned host). The hook
  lists only labelled issues, so without the labels the item would vanish
  once the file is retired. The dry run reports "would relabel #N". A failed
  relabel fails the run and suppresses the retire-the-file message. Label
  membership is decided in jq on the label array, never on a comma-joined
  string, so a label named `team,operator-action` doesn't count. A matched
  issue whose body lacks the block's `- action:` line (hand-filed, or a
  repeated queue title with a different action) is reported as "needs
  manual merge: #N" and left unmigrated. The apply then exits 1 without the
  retire-the-file message.
- Tests: fixture cases for the bounded snapshot (an `rm` wrapper measures
  it), recovery cleanup of only pattern-matching files, TERM cleanup,
  unlabelled same-title dedupe, and the status-only trailer. The `cp`-wrapper
  race case now wraps `head`, the snapshot's new reader.
