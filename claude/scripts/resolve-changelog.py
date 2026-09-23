#!/usr/bin/env python3
"""resolve-changelog.py — resolve a head-of-file CHANGELOG.md merge conflict.

Two PRs that each prepend a dated `## ` section to CHANGELOG.md conflict at the
top of the file whenever one merges first (#561). This is the standard fix for
that DIRTY state: after `git merge origin/main` stops on CHANGELOG.md, run

    python3 claude/scripts/resolve-changelog.py            # resolve in place
    python3 claude/scripts/resolve-changelog.py --check    # dry run, no write

and it keeps BOTH sides' new sections, "theirs" (origin/main, merged first) on
top of "ours" (this branch), separated by a blank line. Entry text is never
edited.

Git's conflict hunks are not trusted to fall on section boundaries: a shared
body line can sit outside the block, or the new entries can split into several
blocks. So the resolver works on each side's whole file: the index stages git
records for an unmerged path (:1: base, :2: ours, :3: theirs), or, outside a
merge, a file rebuilt from diff3 markers. It splits the three versions into
`## ` sections and takes the longest identical run of trailing sections of
ours and theirs as the shared history; what each side has above that run is
its new sections. It refuses (exit 1, file untouched) unless that is provably
a prepend:
  - a merge base is available (index stage 1, or diff3 base parts), and it is
    exactly the shared history, with the same text above the first `## `;
  - no heading appears in both sides' new sections, or in a new section and
    the shared history.
Plain two-way markers outside a merge carry no base, so they are refused:
without one, disjoint new headings could be two renames of one old section.
Anything else is a real conflict to resolve by hand. When the index stages are
used, the working file is rebuilt from them, so hand edits made to the
conflicted file before running this are discarded.

The sides assume a merge (ours = HEAD = your branch). In a rebase git swaps
them, so merge rather than rebase when using this.

Exit status: 0 resolved (or nothing to resolve — re-running is a no-op),
1 refused, 2 usage error (missing file). Default path: ./CHANGELOG.md.
"""

import argparse
from pathlib import Path
import subprocess
import sys

START, BASE, MID, END = "<<<<<<<", "|||||||", "=======", ">>>>>>>"


class Refused(Exception):
    pass


def is_marker(line, marker):
    # Git writes 7 marker chars, then a space + label (or nothing, for =======).
    return line == marker or line.startswith(marker + " ")


def sides(lines):
    """Rebuild (ours, base, theirs) whole-file line lists from conflict markers.

    base is None unless every block carries a diff3 base part. Returns None
    when the text has no conflict block.
    """
    ours, base, theirs = [], [], []
    has_base, blocks = True, 0
    state = None  # None outside a block, else "ours" / "base" / "theirs"
    for n, line in enumerate(lines, 1):
        bare = line.rstrip("\r\n")
        if state is None:
            if is_marker(bare, START):
                state, blocks, seen_base = "ours", blocks + 1, False
            elif any(is_marker(bare, m) for m in (BASE, MID, END)):
                raise Refused(f"stray conflict marker at line {n}")
            else:
                ours.append(line)
                base.append(line)
                theirs.append(line)
        elif state == "ours" and is_marker(bare, BASE):
            state, seen_base = "base", True
        elif state in ("ours", "base") and is_marker(bare, MID):
            state, has_base = "theirs", has_base and seen_base
        elif state == "theirs" and is_marker(bare, END):
            state = None
        elif is_marker(bare, START) or is_marker(bare, END):
            raise Refused(f"unexpected conflict marker at line {n}")
        else:
            {"ours": ours, "base": base, "theirs": theirs}[state].append(line)
    if state is not None:
        raise Refused("unterminated conflict block")
    if not blocks:
        return None
    return ours, (base if has_base else None), theirs


def split(lines):
    """(preamble, [section, ...]); each section is the lines from one `## ` heading."""
    preamble, sections = [], []
    for line in lines:
        if line.startswith("## "):
            sections.append([line])
        elif sections:
            sections[-1].append(line)
        else:
            preamble.append(line)
    return preamble, sections


def heading(section):
    return section[0].rstrip("\r\n")


def index_stages(path):
    """(ours, base, theirs) line lists from git's index for an unmerged path,
    in the same order sides() returns.

    None when the path is not unmerged in a git repository (not in a merge, or
    no git). A missing stage (e.g. no common ancestor) comes back as None.
    """
    path = path.resolve()

    def show(stage):
        r = subprocess.run(
            ["git", "-C", str(path.parent), "show", f":{stage}:./{path.name}"],
            capture_output=True,
            text=True,
            check=False,
        )
        return r.stdout.splitlines(keepends=True) if r.returncode == 0 else None

    ours, theirs = show(2), show(3)
    if ours is None or theirs is None:
        return None
    return ours, show(1), theirs


def resolve(text, stages=None):
    """Return the resolved text, or None when there is no conflict.

    stages: (ours, base, theirs) from index_stages(), preferred over markers.
    """
    rebuilt = sides(text.splitlines(keepends=True))
    if rebuilt is None:
        return None
    ours_lines, base_lines, theirs_lines = stages if stages is not None else rebuilt
    if base_lines is None:
        raise Refused(
            "no merge base: run it on a path git reports unmerged, or with diff3 "
            "markers (git config merge.conflictStyle diff3); two-way markers "
            "cannot prove a prepend"
        )
    ours_pre, ours = split(ours_lines)
    theirs_pre, theirs = split(theirs_lines)
    if ours_pre != theirs_pre:
        raise Refused("the sides differ above the first `## ` section (not a prepend)")

    shared = 0
    while (
        shared < min(len(ours), len(theirs))
        and ours[len(ours) - 1 - shared] == theirs[len(theirs) - 1 - shared]
    ):
        shared += 1
    history = ours[len(ours) - shared :]
    ours_new = ours[: len(ours) - shared]
    theirs_new = theirs[: len(theirs) - shared]

    history_heads = {heading(s) for s in history}
    ours_heads = {heading(s) for s in ours_new}
    theirs_heads = {heading(s) for s in theirs_new}
    clash = (ours_heads & theirs_heads) | ((ours_heads | theirs_heads) & history_heads)
    if clash:
        raise Refused(
            f"section {sorted(clash)[0]!r} differs between the sides: an existing "
            "section was edited, not just prepended to"
        )
    if split(base_lines) != (ours_pre, history):
        raise Refused("the merge base is not the shared history: a side edited existing text")

    out = list(ours_pre)
    new = theirs_new + ours_new
    for i, section in enumerate(new):
        out.extend(section)
        followed = i + 1 < len(new) or history
        if followed and section[-1].strip():
            out.append("\n")
    for section in history:
        out.extend(section)
    resolved = "".join(out)
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
        resolved = resolve(path.read_text(), index_stages(path))
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
