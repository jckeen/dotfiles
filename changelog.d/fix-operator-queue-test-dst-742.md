## 2026-11-05 — test(hooks): operator-queue fixture dates no longer drift a day after a DST change (#742)

- **The test anchors its relative dates at local midnight.** `day()` and
  `iso()` built fixture dates with `date -d "-N days"` from the wall-clock
  instant, which carries the DST shift of a crossed transition; in the last
  hour of each local day for the week after a change, every age the hook
  reported came out a day short of the fixture and 15 assertions failed. The
  hook does civil-date arithmetic on the calendar date and was right.
