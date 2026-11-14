#!/usr/bin/env python3
"""check-ci-efficiency.py — report where a repo's CI config wastes hosted minutes.

The mechanical half of the CI cost standard: the full suite runs once per
merge, on the commit that lands, and every other run is cheap. Read-only and
offline — it parses the checkout's .github/ YAML and reads nothing else. Two
rules can be asserted from files alone:

  cancel   a workflow triggered by `pull_request` cancels the run a new push
           supersedes: its workflow-level `concurrency`, or the `concurrency`
           of every one of its jobs, sets `cancel-in-progress` to something
           other than false. `pull_request_target` is not judged: those
           workflows are privileged writers (labels, statuses), not test
           suites, and several must run to completion.
  groups   every `updates` entry in .github/dependabot.yml has `groups`, so
           routine updates share one pull request, and one CI run.

The rest of the standard (path-selected jobs behind one aggregate check, no
repeat run on the default branch, merge queue for long suites) is a design
decision per repo and is not judged here, so a clean result is not the whole
standard.

A workflow that must not cancel carries a comment line of the form
  # ci-efficiency: no-cancel — <reason>
and is skipped; the marker without a reason is itself reported.

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

MARKER = re.compile(r"^\s*#\s*ci-efficiency:\s*no-cancel(.*)$", re.MULTILINE)
HINT = "add cancel-in-progress, or a '# ci-efficiency: no-cancel — reason' line"


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
    if not isinstance(concurrency, dict):
        return False  # absent, or a bare group name: nothing is cancelled
    value = concurrency.get("cancel-in-progress", False)
    if isinstance(value, str):
        return value.strip().lower() != "false"  # an expression decides per event
    return value is True


def check_workflow(path: Path, name: str) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    doc, err = load(path)
    if err is not None:
        return [f"  parse   {name}: {err}"]
    if not isinstance(doc, dict) or "pull_request" not in triggers(doc):
        return []
    marker = MARKER.search(text)
    if marker:
        if not re.search(r"\w", marker.group(1)):
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
    return [f"  cancel  {name}: a superseded pull_request run is never cancelled ({HINT})"]


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
        groups = entry.get("groups")
        if isinstance(groups, dict) and groups:
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
