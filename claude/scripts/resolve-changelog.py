#!/usr/bin/env python3
"""resolve-changelog.py — resolve a head-of-file CHANGELOG.md merge conflict.

Two PRs that each prepend a dated `## ` section to CHANGELOG.md conflict at the
top of the file whenever one merges first (#561). This is the standard fix for
that DIRTY state: after `git merge origin/main` stops on CHANGELOG.md, run

    python3 claude/scripts/resolve-changelog.py            # resolve in place
    python3 claude/scripts/resolve-changelog.py --check    # dry run, no write

and it keeps BOTH sides' sections, "theirs" (origin/main, merged first) on top
of "ours" (this branch), separated by a blank line. Entry text is never edited.

It refuses (exit 1, file untouched) unless the conflict is exactly the shape
two prepends produce:
  - one conflict block, and no `## ` section heading above it (top of file);
  - each side is empty or whole sections — its first non-blank line is `## `;
  - a diff3 base part, if present, is blank (neither side edited shared text).
Anything else is a real conflict to resolve by hand.

The sides assume a merge (ours = HEAD = your branch). In a rebase git swaps
them, so merge rather than rebase when using this.

Exit status: 0 resolved (or nothing to resolve — re-running is a no-op),
1 refused, 2 usage error (missing file). Default path: ./CHANGELOG.md.
"""

import argparse
from pathlib import Path
import sys

START, BASE, MID, END = "<<<<<<<", "|||||||", "=======", ">>>>>>>"


class Refused(Exception):
    pass


def is_marker(line, marker):
    # Git writes 7 marker chars, then a space + label (or nothing, for =======).
    return line == marker or line.startswith(marker + " ")


def whole_sections(side):
    """True when a side is empty or starts (after blank lines) with a heading."""
    content = [line for line in side if line.strip()]
    return not content or content[0].startswith("## ")


def resolve(text):
    """Return the resolved text, or None when there is no conflict."""
    lines = text.splitlines(keepends=True)
    bare = [line.rstrip("\r\n") for line in lines]
    starts = [i for i, line in enumerate(bare) if is_marker(line, START)]
    if not starts:
        leftovers = [i + 1 for i, line in enumerate(bare) if is_marker(line, END)]
        if leftovers:
            raise Refused(f"stray conflict marker at line {leftovers[0]}")
        return None
    if len(starts) > 1:
        raise Refused(f"{len(starts)} conflict blocks; only one at the head is handled")
    start = starts[0]
    above = [i + 1 for i in range(start) if bare[i].startswith("## ")]
    if above:
        raise Refused(
            f"conflict at line {start + 1} is below the section at line {above[0]} "
            "(not the top-of-file prepend region)"
        )

    base = mid = end = None
    for i in range(start + 1, len(bare)):
        if is_marker(bare[i], BASE) and base is None and mid is None:
            base = i
        elif is_marker(bare[i], MID) and mid is None:
            mid = i
        elif is_marker(bare[i], END):
            end = i
            break
    if mid is None or end is None:
        raise Refused(f"unterminated conflict block starting at line {start + 1}")

    ours = lines[start + 1 : base if base is not None else mid]
    shared = lines[base + 1 : mid] if base is not None else []
    theirs = lines[mid + 1 : end]
    if any(line.strip() for line in shared):
        raise Refused("the diff3 base is not empty: a side edited existing text")
    for name, side in (("ours", ours), ("theirs", theirs)):
        if not whole_sections(side):
            raise Refused(f"{name} side does not start with a `## ` section heading")

    top = list(theirs)
    if top and ours and top[-1].strip():
        top.append("\n")
    resolved = "".join(lines[:start] + top + ours + lines[end + 1 :])
    for line in resolved.splitlines():
        if any(is_marker(line, m) for m in (START, BASE, END)):
            raise Refused("conflict markers remain after resolution")
    return resolved


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("path", nargs="?", default="CHANGELOG.md")
    parser.add_argument("--check", action="store_true", help="report only; never write")
    args = parser.parse_args(argv)

    path = Path(args.path)
    if not path.is_file():
        print(f"resolve-changelog: {path}: no such file", file=sys.stderr)
        return 2
    try:
        resolved = resolve(path.read_text())
    except Refused as err:
        print(f"resolve-changelog: refusing: {path}: {err}", file=sys.stderr)
        return 1
    if resolved is None:
        print(f"resolve-changelog: {path}: no conflict, nothing to do")
        return 0
    headings = [line for line in resolved.splitlines() if line.startswith("## ")][:3]
    if args.check:
        print(f"resolve-changelog: {path}: resolvable; the head would read:")
    else:
        path.write_text(resolved)
        print(f"resolve-changelog: {path}: resolved; `git add {path}` to continue. Head:")
    for heading in headings:
        print(f"  {heading}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
