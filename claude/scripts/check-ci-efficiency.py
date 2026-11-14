#!/usr/bin/env python3
"""check-ci-efficiency.py — report where a repo's CI config wastes hosted minutes.

The mechanical half of the CI cost standard: the full suite runs once per
merge, on the commit that lands, and every other run is cheap. Read-only and
offline — it parses the checkout's .github/ YAML and reads nothing else. Two
rules can be asserted from files alone:

  cancel   a workflow triggered by `pull_request` cancels the run a new push
           supersedes. Expressions are evaluated by GitHub at run time, so
           the check recognises a short list of forms and reports anything
           else as unconfirmed rather than guess: the workflow-level
           `concurrency`, or the `concurrency` of every job, must have a
           `group` that names the pull request's ref (github.ref,
           github.head_ref, github.ref_name or the pull request number) and
           a `cancel-in-progress` that is true or one of the expressions in
           CANCEL_EXPRESSIONS. `pull_request_target` is not judged: those
           workflows are privileged writers (labels, statuses), not test
           suites, and several must run to completion.
  groups   every `updates` entry in .github/dependabot.yml groups its routine
           version updates: a `groups` entry that is not limited to security
           updates, or membership of a `multi-ecosystem-group`. Grouped
           updates share one pull request, and one CI run.

The rest of the standard (path-selected jobs behind one aggregate check, no
repeat run on the default branch, merge queue for long suites) is a design
decision per repo and is not judged here, so a clean result is not the whole
standard.

A workflow that must not cancel, or that cancels in a form the check does not
recognise, carries a comment line of the form
  # ci-efficiency: no-cancel — <reason>
and is skipped; the marker without a reason is itself reported. Only a real
YAML comment counts: the same text inside a block scalar (a script) does not.

Usage:
  check-ci-efficiency.py [DIR]        one checkout (default: cwd)
  check-ci-efficiency.py --all DIR    every git checkout directly in DIR
Exit: 0 clean, 1 findings, 2 usage error, 3 PyYAML is not installed.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - environment dependent
    yaml = None

MARKER = re.compile(r"^\s*#\s*ci-efficiency:\s*no-cancel(.*)$")
HINT = "use a recognised form, or add a '# ci-efficiency: no-cancel — reason' line"
# Names that tie a concurrency group to one pull request, so that a new push
# lands in the same group as the run it supersedes.
GROUP_REFS = (
    "github.ref",  # also matches github.ref_name
    "github.head_ref",
    "github.event.pull_request.number",
    "github.event.number",
)
# `cancel-in-progress` expressions known to be true for a pull_request run,
# compared with all whitespace removed. Anything else is unconfirmed.
CANCEL_EXPRESSIONS = (
    "${{github.event_name=='pull_request'}}",
    "${{github.event_name!='push'}}",
    "${{startsWith(github.ref,'refs/pull/')}}",
)


def load(path: Path):
    """Parse one YAML file; return (document, error text or None)."""
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8")), None
    except (OSError, UnicodeDecodeError, yaml.YAMLError) as exc:
        return None, str(exc).splitlines()[0]


def triggers(doc: dict) -> set[str]:
    # YAML 1.1 reads a bare `on` key as boolean true; accept both spellings.
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {str(item) for item in on}
    if isinstance(on, dict):
        return {str(key) for key in on}
    return set()


def cancels(concurrency) -> bool:
    """True only when the block is a recognised form that cancels a superseded run."""
    if not isinstance(concurrency, dict):
        return False  # absent, or a bare group name: nothing is cancelled
    group = concurrency.get("group")
    if not isinstance(group, str) or not any(ref in group for ref in GROUP_REFS):
        return False  # a group per run (or a fixed one) never pairs two pushes
    value = concurrency.get("cancel-in-progress", False)
    if isinstance(value, str):
        compact = "".join(value.split())
        return compact.lower() == "true" or compact in CANCEL_EXPRESSIONS
    return value is True


def marker_reason(path: Path, text: str):
    """Return the reason text of a no-cancel comment, or None when there is none.

    A line inside a block scalar is script data, not a comment, so the YAML
    node tree is used to rule those lines out.
    """
    inside: set[int] = set()
    try:
        stack = [yaml.compose(text)]
    except yaml.YAMLError:
        return None
    while stack:
        node = stack.pop()
        if isinstance(node, yaml.ScalarNode):
            inside.update(range(node.start_mark.line, node.end_mark.line))
        elif isinstance(node, yaml.SequenceNode):
            stack.extend(node.value)
        elif isinstance(node, yaml.MappingNode):
            for key, value in node.value:
                stack.extend((key, value))
    for number, line in enumerate(text.splitlines()):
        match = MARKER.match(line)
        if match and number not in inside:
            return match.group(1)
    return None


def check_workflow(path: Path, name: str) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    doc, err = load(path)
    if err is not None:
        return [f"  parse   {name}: {err}"]
    if not isinstance(doc, dict) or "pull_request" not in triggers(doc):
        return []
    reason = marker_reason(path, text)
    if reason is not None:
        if not re.search(r"\w", reason):
            return [f"  cancel  {name}: no-cancel marker has no reason"]
        return []
    if cancels(doc.get("concurrency")):
        return []
    jobs = doc.get("jobs")
    if (
        isinstance(jobs, dict)
        and jobs
        and all(isinstance(job, dict) and cancels(job.get("concurrency")) for job in jobs.values())
    ):
        return []
    return [f"  cancel  {name}: cannot confirm a superseded pull_request run is cancelled ({HINT})"]


def routine_group(groups) -> bool:
    """True when some group covers version updates, not only security updates."""
    if not isinstance(groups, dict):
        return False
    return any(
        not (isinstance(group, dict) and group.get("applies-to") == "security-updates")
        for group in groups.values()
    )


def check_dependabot(path: Path, name: str) -> list[str]:
    doc, err = load(path)
    if err is not None:
        return [f"  parse   {name}: {err}"]
    updates = doc.get("updates") if isinstance(doc, dict) else None
    if not isinstance(updates, list):
        return []
    found = []
    for index, entry in enumerate(updates):
        if not isinstance(entry, dict):
            continue
        if entry.get("multi-ecosystem-group") or routine_group(entry.get("groups")):
            continue
        eco = entry.get("package-ecosystem", f"entry {index + 1}")
        directory = entry.get("directory", entry.get("directories", ""))
        found.append(f"  groups  {name}: '{eco}' updates for {directory!r} are not grouped")
    return found


def config_files(repo: Path) -> tuple[list[Path], list[Path]]:
    gh = repo / ".github"
    workflows = sorted(
        p for ext in ("*.yml", "*.yaml") for p in (gh / "workflows").glob(ext) if p.is_file()
    )
    dependabot = [p for p in (gh / "dependabot.yml", gh / "dependabot.yaml") if p.is_file()]
    return workflows, dependabot


def check_repo(repo: Path) -> tuple[list[str], bool]:
    """Return (findings, whether there was anything to judge)."""
    workflows, dependabot = config_files(repo)
    found: list[str] = []
    for path in workflows:
        found += check_workflow(path, f".github/workflows/{path.name}")
    for path in dependabot:
        found += check_dependabot(path, f".github/{path.name}")
    return found, bool(workflows or dependabot)


def usage() -> int:
    print(__doc__.split("Usage:", 1)[1].rstrip(), file=sys.stderr)
    return 2


def main(argv: list[str]) -> int:
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    bulk = bool(argv) and argv[0] == "--all"
    rest = argv[1:] if bulk else argv
    if len(rest) > 1 or (bulk and len(rest) != 1) or any(a.startswith("-") for a in rest):
        return usage()
    target = Path(rest[0]) if rest else Path(".")
    if not target.is_dir():
        print(f"not a directory: {target}", file=sys.stderr)
        return 2
    if yaml is None:
        print("ci-efficiency: PyYAML is not installed; nothing was checked", file=sys.stderr)
        return 3

    if not bulk:
        found, judged = check_repo(target)
        if found:
            print("\n".join(found))
            return 1
        print("ci-efficiency: OK" if judged else "ci-efficiency: no CI config to check")
        return 0

    checked = drift = 0
    for repo in sorted(p for p in target.iterdir() if p.is_dir() and (p / ".git").exists()):
        found, judged = check_repo(repo)
        if not judged:
            continue
        checked += 1
        if found:
            drift += 1
            print(repo.name)
            print("\n".join(found))
    print(f"ci-efficiency: {checked} checkout(s) with CI config, {drift} with findings")
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
