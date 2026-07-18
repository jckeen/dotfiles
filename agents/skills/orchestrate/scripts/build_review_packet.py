#!/usr/bin/env python3
"""Build a fresh-context review packet from tracked Git evidence."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys

DEFAULT_MAX_BYTES = 200_000


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ValueError(detail or f"git {' '.join(args)} failed")
    return result.stdout


def git_diff(repo: Path, base: str, paths: list[Path], max_bytes: int) -> str:
    process = subprocess.Popen(
        [
            "git",
            "-C",
            str(repo),
            "--literal-pathspecs",
            "diff",
            "--binary",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "--find-renames",
            base,
            "--",
            *(str(path) for path in paths),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    payload = process.stdout.read(max_bytes + 1)
    if len(payload) > max_bytes:
        process.kill()
        process.communicate()
        raise ValueError(f"tracked diff exceeds --max-bytes ({max_bytes})")
    _, stderr = process.communicate()
    if process.returncode != 0:
        detail = stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(detail or "git diff failed")
    return payload.decode("utf-8", errors="replace")


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def nonblank(value: str) -> str:
    if not value.strip():
        raise argparse.ArgumentTypeError("must not be blank")
    return value


def fenced(content: str, language: str) -> str:
    longest = max(
        (len(match.group(0)) for match in re.finditer(r"`+", content)),
        default=0,
    )
    marker = "`" * max(3, longest + 1)
    closing_gap = "" if content.endswith("\n") else "\n"
    return f"{marker}{language}\n{content}{closing_gap}{marker}"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a bounded raw-evidence packet for adversarial review."
    )
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base", required=True)
    parser.add_argument("--claim", required=True, type=nonblank)
    parser.add_argument("--repro", required=True, type=nonblank)
    parser.add_argument("--verify", action="append", default=[], type=nonblank)
    parser.add_argument("--path", action="append", default=[])
    parser.add_argument("--max-bytes", type=positive_int, default=DEFAULT_MAX_BYTES)
    return parser.parse_args(argv)


def build_packet(args: argparse.Namespace) -> str:
    repo = Path(git(args.repo, "rev-parse", "--show-toplevel").strip())
    base = git(repo, "rev-parse", "--verify", f"{args.base}^{{commit}}").strip()
    paths = [Path(value) for value in args.path]
    if any(path.is_absolute() or ".." in path.parts for path in paths):
        raise ValueError("--path values must stay inside the repository")
    diff = git_diff(repo, base, paths, args.max_bytes)
    if not diff:
        raise ValueError("tracked diff is empty")
    scope = (
        fenced("\n".join(str(path) for path in paths), "text")
        if paths
        else "All tracked changes from base."
    )
    verification = "\n\n".join(fenced(command, "text") for command in args.verify)
    if not verification:
        verification = "- None supplied."
    return (
        "# Adversarial Review Packet\n\n"
        f"Repository: `{repo.name}`\n\n"
        f"Base commit: `{base}`\n\n"
        "## Path scope\n\n"
        f"{scope}\n\n"
        "## Claim to disprove\n\n"
        f"{args.claim}\n\n"
        "## Exact repro\n\n"
        f"{fenced(args.repro, 'text')}\n\n"
        "## Verification commands\n\n"
        f"{verification}\n\n"
        "## Tracked diff\n\n"
        f"{fenced(diff, 'diff')}\n"
    )


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        sys.stdout.write(build_packet(args))
    except (OSError, ValueError) as error:
        print(f"build-review-packet: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
