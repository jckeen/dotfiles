#!/usr/bin/env python3
"""Bind local gate results to Git objects and raw workspace state; fail closed.

Receipts are local evidence, not signatures against a malicious filesystem owner.
No Git worktree diff is used: clean filters can execute even with --no-textconv.
"""

import argparse
from collections import deque
import contextlib
from datetime import datetime, timedelta, timezone
import difflib
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import uuid

LANES = ("codex", "antigravity")
GIT_ROUTING_ENV_VARS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_NAMESPACE",
    "GIT_ATTR_SOURCE",
    "GIT_CEILING_DIRECTORIES",
)
# ADR-0008. `any < antigravity < codex`: a receipt ships a diff when its lane
# ranks at or above the lane the diff requires. "any" is not a reviewer — it is
# the requirement a tier-1 exemption places on whichever lane recorded it.
LANE_RANK = {"any": 0, "antigravity": 1, "codex": 2}
# review-and-push.sh stamps this prefix on the ledger note when an Antigravity
# gate that could not run (exit 3) handed the diff to Codex. `stats` counts it.
DEGRADED_NOTE_PREFIX = "antigravity-degraded"
# Tier-1 ceilings, both captured into every receipt's policy so the two lanes and
# `check` share one answer (#494). The byte ceiling exists because the line
# ceiling alone is not a size limit: one 200,000-byte line is a 1-line diff. The
# Antigravity lane's measured input window is 185,000 bytes for the WHOLE agy
# print-mode message — preamble, fence markers and diff (#409,
# antigravity-review-gate.sh) — so a diff the valve waves through must sit far
# enough below that to still be dispatchable there if a caller forces the full
# pass. 64 KiB is that, with room for the scaffolding, and is still ~3x the
# largest plausible docs diff inside TIER1_MAX_LINES lines.
TIER1_MAX_LINES = "200"
TIER1_MAX_BYTES = "65536"
AGENT_NAMESPACES = (
    "codex",
    ".codex",
    "antigravity",
    ".antigravity",
    ".agents",
    ".claude",
    ".gemini",
)
EXCLUDED = (
    "*-lock.yaml",
    "*-lock.json",
    "package-lock.json",
    "*.lock",
    "bun.lockb",
    "*.png",
    "*.jpg",
    "*.jpeg",
    "*.gif",
    "*.ico",
    "*.pdf",
    "*.min.css",
    "*.map",
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":")).encode()


def physical_lines(text):
    # Git's hunk coordinates count LF, not Unicode or other control separators.
    parts = text.split("\n")
    return [line + "\n" for line in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


def quote_git_path(path):
    data = path.encode("utf-8")
    if all(32 < byte < 127 and byte not in (34, 92) for byte in data):
        return path
    escapes = {
        7: r"\a",
        8: r"\b",
        9: r"\t",
        10: r"\n",
        11: r"\v",
        12: r"\f",
        13: r"\r",
        34: r"\"",
        92: r"\\",
    }
    # Git C quoting uses octal bytes, not JSON's Unicode escape sequences.
    return (
        '"'
        + "".join(
            escapes.get(byte, chr(byte) if 32 <= byte < 127 else f"\\{byte:03o}") for byte in data
        )
        + '"'
    )


def _git_env(extra=None):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_REPLACE_OBJECTS="1")
    # The helper supplies its own literal pathspecs and `-C <repo>` routing;
    # inherited pathspec switches and Git routing overrides must never divert
    # index, object, worktree, or attribute lookups.
    for name in (
        "GIT_LITERAL_PATHSPECS",
        "GIT_GLOB_PATHSPECS",
        "GIT_NOGLOB_PATHSPECS",
        "GIT_ICASE_PATHSPECS",
        *GIT_ROUTING_ENV_VARS,
    ):
        env.pop(name, None)
    if extra:
        env.update(extra)
    return env


def _reject_git_routing_overrides():
    routing_set = set(GIT_ROUTING_ENV_VARS) | {
        "GIT_CONFIG",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
    }
    found = [
        name
        for name in os.environ
        if name in routing_set or name.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"))
    ]
    if found:
        raise ValueError(
            "Git environment overrides are unsupported here; unset: " + ", ".join(sorted(found))
        )


def git(repo, *args, extra_env=None):
    return subprocess.check_output(
        [
            "git",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-C",
            str(repo),
            *args,
        ],
        env=_git_env(extra_env),
        stderr=subprocess.PIPE,
    )


def oid(repo, ref):
    return (
        git(repo, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()
    )


def own_worktrees(repo):
    """Real paths of this repository's own worktrees, main checkout included.

    `git ls-files --others` reports any directory it refuses to descend into as a
    single entry with a trailing slash, and a directory only has to *look* like a
    repository to qualify (a `.git` holding HEAD, objects and refs). Dropping such
    an entry is safe only for this repo's own worktrees (#474); every other
    boundary fails closed — an ignored one in inspect_boundary(), a visible one in
    file_bytes() — so a fabricated `.git` cannot hide a dirty instruction file
    behind it (#496).

    `-z` because git prints worktree paths raw: a path holding a newline would
    otherwise split into two entries, truncating the real one and synthesizing a
    line that was never a worktree.
    """
    return {
        os.path.realpath(os.fsdecode(line[len(b"worktree ") :]))
        for line in git(repo, "worktree", "list", "--porcelain", "-z").split(b"\0")
        if line.startswith(b"worktree ")
    }


def primary_worktree(repo):
    """Real path of this repository's non-bare primary worktree, or None."""
    records = git(repo, "worktree", "list", "--porcelain", "-z").split(b"\0\0")
    if not records or not records[0]:
        return None
    lines = records[0].split(b"\0")
    if not lines or not lines[0].startswith(b"worktree ") or b"bare" in lines[1:]:
        return None
    return os.path.realpath(os.fsdecode(lines[0][len(b"worktree ") :]))


def worktree_gitdir(directory):
    """Realpath of the gitdir named by a linked worktree's `.git` pointer file.

    A `.git` file is not proof of ownership on its own — `git init
    --separate-git-dir` plants one that points at a foreign repository, and git
    stops at that directory all the same — so the caller checks the target against
    this repository's worktree store. None when the pointer is absent, unreadable
    or malformed, which the caller treats as a foreign boundary (#474).

    Parsed as Git's read_gitfile does: the whole file must start with exactly
    `gitdir: `, and only trailing CR/LF bytes are removed. Any other byte belongs
    to the path, so stripping whitespace named a different gitdir (#641, the
    class #541 fixed).
    """
    try:
        pointer = (directory / ".git").read_bytes()
    except OSError:
        return None
    if not pointer.startswith(b"gitdir: "):
        return None
    target = pointer[len(b"gitdir: ") :].rstrip(b"\r\n")
    if not target:
        return None
    return os.path.realpath(os.path.join(directory, os.fsdecode(target)))


def registered_worktree(gitdir):
    """The `.git` path a worktree store entry registers, or None if unreadable.

    Git writes `<path>/.git` plus a newline; only trailing CR/LF bytes are its
    delimiters, as in its own prune check (#641).
    """
    try:
        return os.fsdecode((Path(gitdir) / "gitdir").read_bytes().rstrip(b"\r\n"))
    except OSError:
        return None


def boundary_listing(directory):
    """Every (mode, path) a foreign repository boundary lists, tracked and untracked.

    `git ls-files` stops at any directory that merely LOOKS like a repository — a
    `.git` holding HEAD, objects and refs is enough, no `git init` required — so
    "git stopped here" is no evidence that anything ever looked inside (#496).
    This is that look.

    Two calls, because the formats differ and each is then unambiguous: the index
    with `--stage` (`<mode> <object> <stage>\\t<path>`, so a gitlink's mode 160000
    is visible) and the untracked files as bare paths. `mode` is None for an
    untracked entry.

    The index half matters because a populated tracked submodule is printed as ONE
    bare path with no trailing slash and its contents are never enumerated, so a
    listing alone cannot tell it from an ordinary file — the caller refuses on the
    mode instead.

    Deliberately WITHOUT `--exclude-standard`: the boundary's own `.gitignore`
    must not decide what this repository's instruction sweep is allowed to see,
    and with no exclude option git applies no patterns at all, so every untracked
    file is listed. Returns None when the directory is not a usable repository,
    which the caller treats as a refusal rather than as an empty listing.

    For the same reason the boundary's own config must not decide WHERE or HOW
    git looks (#641). `--work-tree` pins the listing to this directory: a
    `core.worktree` in the boundary's config otherwise lists another directory,
    and `-c core.worktree=` does not override it (checked on git 2.43).
    `core.ignoreCase` is forced off so a tracked `claude.md` cannot mask an
    untracked `CLAUDE.md` on a case-sensitive filesystem.
    """
    entries = []
    pinned = ("--work-tree", str(directory), "-c", "core.ignoreCase=false")
    try:
        staged = git(directory, *pinned, "ls-files", "-z", "--cached", "--stage")
        others = git(directory, *pinned, "ls-files", "-z", "--others")
    except (subprocess.SubprocessError, OSError):
        return None
    for record in staged.split(b"\0"):
        if not record:
            continue
        # Everything after the FIRST tab is the path, which may itself hold tabs.
        metadata, separator, path = record.partition(b"\t")
        if not separator:
            return None
        fields = metadata.split()
        if len(fields) != 3:
            return None
        entries.append((fields[0].decode(), os.fsdecode(path)))
    for path in others.split(b"\0"):
        if path:
            entries.append((None, os.fsdecode(path)))
    return entries


def named_instruction(path):
    name = Path(path).name
    # .codex-review-ignore steers what the Codex reviewer reports, so it is an
    # instruction surface: a dirty copy blocks a committed review and an edit
    # to it is never a tier-1 change.
    return re.search(
        r"(AGENTS|CLAUDE|GEMINI|FABLE|MULTI-AGENT).*\.md$", name
    ) is not None or name in ("SKILL.md", ".codex-review-ignore")


def source_instruction(path):
    parts = Path(path).parts
    layouts = (
        ("agents", "skills"),
        ("agents", "canon"),
        ("claude", "skills"),
        ("claude", "agents"),
    )
    # Bundles include references/support files, not just their SKILL.md entrypoint.
    # Bare source ancestors can redirect installed links to different inputs.
    return (
        any(pair in layouts for pair in zip(parts, parts[1:]))
        or parts[-1] in ("agents", "claude")
        or parts[-2:] == ("claude", "scripts")
        or parts[-2:]
        in (
            ("claude", "AgentPack.md"),
            ("claude", "AGENTPACK.yaml"),
            ("claude", "agentpack-meta.json"),
        )
    )


def modes_differ(mode1, mode2, file_mode=True):
    if mode1 == mode2:
        return False
    if not file_mode and {mode1, mode2} <= {"100644", "100755"}:
        return False
    return True


def instruction(path):
    parts = Path(path).parts
    name = parts[-1]
    # Where the hook tree starts, so the vendored test below can fire only *below*
    # it: a dependency that vendors a githooks/ directory must not thereby hide its
    # own AGENTS.md from the sweep.
    hook_at = next(
        (
            index
            for index, p in enumerate(parts)
            if p in ("githooks", ".githooks")
            or (
                p in ("claude", ".claude", ".codex", ".gemini")
                and parts[index + 1 : index + 2] == ("hooks",)
            )
        ),
        None,
    )
    # A dependency's own CLAUDE.md is not this repo's instruction surface, so the
    # vendored test short-circuits the whole predicate rather than clearing just
    # the hook term — named_instruction() matches on basename alone and would win
    # over it (#439).
    if hook_at is not None and (
        any(p in ("node_modules", ".bun", "dist", "__pycache__") for p in parts[hook_at + 1 :])
        or name
        in (
            "bun.lock",
            "bun.lockb",
            "package.json",
            "package-lock.json",
            "yarn.lock",
            "pnpm-lock.yaml",
        )
    ):
        return False
    return (
        any(p in AGENT_NAMESPACES for p in parts)
        or source_instruction(path)
        or hook_at is not None
        or named_instruction(path)
        or name
        in (
            "gate-lib.sh",
            "review-receipt.py",
            "review-multipart.py",
            "codex-review-gate.sh",
            "antigravity-review-gate.sh",
            "codex-review-schema.json",
        )
    )


def vendored_dependency(repo, path, trees=None):
    """An ignored path inside an installed dependency tree of a skill, scripts dir or root.

    The #439 hook-tree exemption, extended to `claude/skills/<name>/node_modules`
    and `claude/scripts/node_modules` (#514) and to the repository root's own
    `node_modules`, which every installed bun/npm project has (#651). It is
    deliberately narrower: a dependency tree is exactly where a planted
    instruction file would hide, so the exemption holds only where installation
    is the evident explanation. The caller passes only entries `ls-files
    --ignored` reported, but that proves only the ENTRY is ignored: excluding one
    planted `AGENTS.md` by name would pass as a vendored tree. So the
    `node_modules` directory itself — a real directory, never a symlink — must be
    ignored too, and the directory that owns it must hold a lockfile, checked on
    disk as a regular file (never a symlink). Everything else — another layout
    (a nested package's `node_modules` included), no lockfile, a tree that is not
    ignored — stays an instruction surface and fails closed.

    `trees` memoizes the per-tree verdict for one capture: every file under a
    qualifying tree would otherwise repeat the same lstat and `check-ignore`
    subprocess, tens of thousands of times for a real dependency tree, some of
    them under the receipt transition lock. The verdict depends only on the
    owner directory, so one capture checks each tree once.
    """
    parts = Path(path).parts
    if parts[:2] == ("claude", "skills") and len(parts) > 4 and parts[3] == "node_modules":
        owner = parts[:3]
    elif parts[:2] == ("claude", "scripts") and len(parts) > 3 and parts[2] == "node_modules":
        owner = parts[:2]
    elif len(parts) > 1 and parts[0] == "node_modules":
        # The root itself owns the tree: its lockfile sits beside `node_modules`.
        owner = ()
    else:
        return False
    if trees is None:
        return vendored_tree(repo, owner)
    if owner not in trees:
        trees[owner] = vendored_tree(repo, owner)
    return trees[owner]


def vendored_tree(repo, owner):
    locked = False
    for lockfile in ("bun.lock", "bun.lockb", "package-lock.json"):
        try:
            locked = locked or stat.S_ISREG((repo / Path(*owner) / lockfile).lstat().st_mode)
        except OSError:
            continue
    if not locked:
        return False
    return ignored_directory(repo, Path(*owner, "node_modules"))


def ignored_directory(repo, tree):
    """Whether `tree` is a real directory (not a symlink) that git itself ignores."""
    try:
        if not stat.S_ISDIR((repo / tree).lstat().st_mode):
            return False
    except OSError:
        return False
    try:
        # No trailing slash: with one, `node_modules/*` matches the appended
        # slash and reports a directory ignored whose children can be re-included
        # (`!node_modules/keep.js`). Git stats the bare path itself, so a
        # directory-only `node_modules/` pattern still matches it.
        git(repo, "check-ignore", "-q", "--", str(tree))
    except subprocess.CalledProcessError as exc:
        if exc.returncode == 1:
            return False
        raise
    return True


def private_agent_data(path):
    parts = Path(path).parts
    name = parts[-1]
    if (
        any(part in AGENT_NAMESPACES for part in parts[:-1]) or source_instruction(path)
    ) and name in (
        "auth.json",
        ".credentials.json",
        "credentials.json",
        "oauth_creds.json",
        "google_accounts.json",
    ):
        return True
    if named_instruction(path):
        return False
    state_directories = {
        ".codex": ("sessions", "log", "logs", "cache", "tmp", "shell_snapshots"),
        ".claude": (
            "sessions",
            "projects",
            "session-env",
            "debug",
            "cache",
            "tmp",
            "telemetry",
            "statsig",
        ),
        ".gemini": ("tmp", "cache"),
    }
    for index, part in enumerate(parts[:-1]):
        if part not in state_directories:
            continue
        relative = parts[index + 1 :]
        if relative[0] in state_directories[part] or name == "history.jsonl":
            return True
        if part == ".codex" and fnmatch.fnmatchcase(name, "state*.sqlite*"):
            return True
        if (
            part == ".gemini"
            and len(relative) > 1
            and relative[:2]
            in (
                ("antigravity-cli", "conversations"),
                ("antigravity-cli", "brain"),
                ("antigravity-cli", "logs"),
            )
        ):
            return True
    return False


def risk(path):
    lower = path.lower()
    risk_patterns = (
        "*AGENTPACK*",
        ".github/*",
        "*/.github/*",
        "*hooks/*",
        "*.githooks*",
        "*scripts/*",
    )
    return (
        instruction(path)
        or any(fnmatch.fnmatchcase(path, pattern) for pattern in risk_patterns)
        or any(
            word in lower
            for word in (
                "auth",
                "token",
                "secret",
                "credential",
                "password",
                "session",
                "sso",
                "crypt",
                "hash",
                "host",
                "schema",
                "migration",
            )
        )
    )


def passive_modes(modes):
    # Both sides matter: deletion, chmod, or replacement must not hide active files.
    return all(mode in ("missing", "100644") for mode in modes)


def excluded(path, modes):
    return (
        not risk(path)
        and passive_modes(modes)
        and any(fnmatch.fnmatchcase(Path(path).name, pattern) for pattern in EXCLUDED)
    )


def docsafe(path):
    return not risk(path) and (
        path.endswith((".md", ".markdown", ".rst")) or Path(path).name in ("LICENSE", "LICENSE.txt")
    )


def file_bytes(repo, path, directory_is_missing=False):
    parent = repo
    for component in Path(path).parts[:-1]:
        parent = parent / component
        try:
            mode = parent.lstat().st_mode
        except (FileNotFoundError, NotADirectoryError):
            return "missing", b""
        if stat.S_ISLNK(mode):
            raise ValueError("cannot snapshot through symlink ancestor: " + path)
        if not stat.S_ISDIR(mode):
            return "missing", b""
    file = repo / path
    try:
        info = file.lstat()
    except (FileNotFoundError, NotADirectoryError):
        return "missing", b""
    if stat.S_ISLNK(info.st_mode):
        return "120000", os.fsencode(os.readlink(file))
    if stat.S_ISDIR(info.st_mode) and directory_is_missing:
        return "missing", b""
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("cannot snapshot non-file: " + path)
    return ("100755" if info.st_mode & 0o111 else "100644"), file.read_bytes()


def repo_root(repo):
    # `lane` and `stats` are read-only; resolving the work tree root here keeps
    # them from provisioning the receipt directory that layout() creates.
    return Path(
        os.fsdecode(git(repo, "rev-parse", "--show-toplevel").removesuffix(b"\n"))
    ).resolve()


def receipts_dir(repo):
    # Resolve the receipt directory WITHOUT creating it, so the read-only
    # subcommands (`lane`, `stats`) provision nothing. Takes an already-resolved
    # work tree root. Remove only Git's output delimiter: trailing whitespace
    # belongs to paths.
    receipts = Path(
        os.fsdecode(git(repo, "rev-parse", "--git-path", "review-receipts").removesuffix(b"\n"))
    )
    if not receipts.is_absolute():
        receipts = repo / receipts
    receipts = receipts.absolute()
    if receipts.is_symlink():
        raise ValueError("receipt directory must not be a symlink")
    return receipts


def common_dir(repo):
    return Path(
        os.fsdecode(
            git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").removesuffix(b"\n")
        )
    ).resolve()


def git_dir(repo):
    return Path(
        os.fsdecode(git(repo, "rev-parse", "--absolute-git-dir").removesuffix(b"\n"))
    ).resolve()


def is_clean_worktree(record):
    if "clean_worktree" not in record:
        return False
    if record["clean_worktree"] is True:
        return True
    raise ValueError("malformed clean_worktree flag")


class _RealFS:
    """Thin filesystem adapter so containment checks can be tested against virtual case-insensitive views."""

    def lstat(self, path):
        return os.lstat(path)

    def stat(self, path):
        return os.stat(path)

    def readlink(self, path):
        return os.readlink(path)

    def scandir(self, path):
        return os.scandir(path)

    def realpath(self, path):
        return os.path.realpath(path)

    def getcwd(self):
        return os.getcwd()

    def samefile(self, a, b):
        return os.path.samefile(a, b)


_REAL_FS = _RealFS()


def _fold_component(seg):
    return unicodedata.normalize("NFC", seg).casefold()


def _fold_path(path_str):
    return "/".join(_fold_component(seg) for seg in path_str.split("/") if seg)


def _same_existing_path(a, b, fs=_REAL_FS):
    try:
        return bool(fs.samefile(a, b))
    except OSError:
        return False


def _dir_identity(path, label, fs=_REAL_FS):
    try:
        st = fs.stat(path)
    except OSError as exc:
        raise ValueError(f"cannot inspect {label}: {os.fspath(path)}") from exc
    if not stat.S_ISDIR(st.st_mode):
        raise ValueError(f"cannot inspect {label}: {os.fspath(path)}")
    return (st.st_dev, st.st_ino)


def _canonical_rel_in_repo(repo_real, rel_parts, fs=_REAL_FS):
    if not rel_parts:
        return Path(".")
    cur = repo_real
    out = []
    for idx, seg in enumerate(rel_parts):
        probe = cur / seg
        try:
            target_st = fs.lstat(probe)
        except (FileNotFoundError, NotADirectoryError):
            out.extend(rel_parts[idx:])
            break
        except OSError as exc:
            raise ValueError(
                "cannot inspect live reviewer or gate surface: " + os.fspath(probe)
            ) from exc
        target_id = (target_st.st_dev, target_st.st_ino)
        try:
            with fs.scandir(cur) as it:
                dir_entries = list(it)
        except OSError as exc:
            raise ValueError(
                "cannot inspect live reviewer or gate surface: " + os.fspath(cur)
            ) from exc
        exact = None
        folded_match = None
        inode_match = None
        seg_folded = _fold_component(seg)
        for entry in dir_entries:
            if entry.name == seg:
                exact = entry.name
                break
            try:
                est = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            if (est.st_dev, est.st_ino) == target_id:
                if _fold_component(entry.name) == seg_folded:
                    folded_match = entry.name
                elif inode_match is None:
                    inode_match = entry.name
        matched_name = exact or folded_match or inode_match
        if matched_name is None:
            raise ValueError(
                "cannot resolve live reviewer or gate surface alias: " + os.fspath(probe)
            )
        out.append(matched_name)
        cur = cur / matched_name
    return Path(*out) if out else Path(".")


def assert_owned_worktree(candidate, common, worktrees, primary=None, allow_separate_primary=False):
    store = os.path.realpath(os.path.join(os.path.realpath(common), "worktrees"))
    try:
        dotgit_mode = (candidate / ".git").lstat().st_mode
    except OSError as exc:
        raise ValueError("worktree is missing .git metadata") from exc
    if stat.S_ISDIR(dotgit_mode):
        if not any(
            _same_existing_path(candidate, wt) for wt in worktrees
        ) or not _same_existing_path(candidate / ".git", common):
            raise ValueError("worktree is not owned by the receipt repository")
        return
    if not stat.S_ISREG(dotgit_mode):
        raise ValueError("worktree is not owned by the receipt repository")
    gitdir = worktree_gitdir(candidate)
    if gitdir is None:
        raise ValueError("worktree is not owned by the receipt repository")
    if _same_existing_path(gitdir, common):
        if (
            allow_separate_primary
            and primary is not None
            and (_same_existing_path(candidate, primary) or _same_existing_path(primary, common))
        ):
            return
        raise ValueError("worktree is not owned by the receipt repository")
    if not any(_same_existing_path(candidate, wt) for wt in worktrees) or not _same_existing_path(
        os.path.dirname(gitdir), store
    ):
        raise ValueError("worktree is not owned by the receipt repository")
    registered = registered_worktree(gitdir)
    if registered is None or not _same_existing_path(registered, candidate / ".git"):
        raise ValueError("worktree is not owned by the receipt repository")


def verify_clean_worktree_pair(source_repo, receipt_repo):
    source_root = repo_root(source_repo)
    receipt_root = repo_root(receipt_repo)
    if _same_existing_path(source_root, receipt_root):
        raise ValueError("--receipt-repo must name a different worktree than --repo")
    source_common = common_dir(source_root)
    receipt_common = common_dir(receipt_root)
    if not _same_existing_path(source_common, receipt_common):
        raise ValueError(
            "receipt repository does not share a Git common directory with the reviewed worktree"
        )
    worktrees = own_worktrees(receipt_root)
    primary = primary_worktree(receipt_root)
    assert_owned_worktree(
        source_root, receipt_common, worktrees, primary=primary, allow_separate_primary=False
    )
    assert_owned_worktree(
        receipt_root, receipt_common, worktrees, primary=primary, allow_separate_primary=True
    )
    if oid(source_root, "HEAD") != oid(receipt_root, "HEAD"):
        raise ValueError("reviewed worktree HEAD does not match receipt repository HEAD")
    return source_root, receipt_root


def parse_index_stage(repo):
    index = git(repo, "ls-files", "--stage", "-t", "-z")
    staged, skipped = {}, set()
    for entry in index.split(b"\0"):
        if not entry:
            continue
        metadata, path_bytes = entry.split(b"\t", 1)
        tag, mode, obj, stage = metadata.decode().split()
        path = os.fsdecode(path_bytes)
        if mode == "160000":
            raise ValueError("submodule snapshots are unsupported; review separately")
        if stage != "0":
            raise ValueError("unmerged index cannot be reviewed")
        staged[path] = (mode, obj)
        if tag == "S":
            skipped.add(path)
    return index, staged, skipped


def _assert_tree_symlinks_confined(entries, blob_lookup):
    symlink_targets = {
        path: os.fsdecode(blob_lookup(obj))
        for path, (mode, obj) in entries.items()
        if mode == "120000"
    }
    if not symlink_targets:
        return
    folded_symlinks = {}
    for path, target in symlink_targets.items():
        folded_symlinks.setdefault(_fold_path(path), []).append((path, target))
    for path in sorted(entries):
        parent = Path(path).parent
        prefix_parts = list(parent.parts) if parent != Path(".") else []
        for idx in range(len(prefix_parts)):
            anc = "/".join(prefix_parts[: idx + 1])
            if anc in symlink_targets or _fold_path(anc) in folded_symlinks:
                raise ValueError("escaping symlink ancestor in clean worktree: " + path)
    for path, target in sorted(symlink_targets.items()):
        if not target or target.startswith("/") or "\0" in target:
            raise ValueError("escaping symlink in clean worktree: " + path)
        parent = Path(path).parent
        prefix_parts = list(parent.parts) if parent != Path(".") else []
        work = deque([(list(prefix_parts), deque(_split_components(target)), 1)])
        expansions = 0
        while work:
            resolved, queue, hops = work.popleft()
            while queue:
                seg = queue.popleft()
                if seg == "..":
                    if not resolved:
                        raise ValueError("escaping symlink in clean worktree: " + path)
                    resolved.pop()
                    continue
                if _fold_component(seg).rstrip(". ") in (".git", "git~1"):
                    raise ValueError("symlink targets .git in clean worktree: " + path)
                resolved.append(seg)
                matches = folded_symlinks.get(_fold_path("/".join(resolved)))
                if matches:
                    next_hops = hops + 1
                    expansions += len(matches)
                    if next_hops > 40 or expansions > 256:
                        raise ValueError("symlink loop in clean worktree: " + path)
                    base_resolved = resolved[:-1]
                    rem = list(queue)
                    for _m_path, next_target in matches:
                        if not next_target or next_target.startswith("/") or "\0" in next_target:
                            raise ValueError("escaping symlink in clean worktree: " + path)
                        new_q = deque(_split_components(next_target))
                        new_q.extend(rem)
                        work.append((list(base_resolved), new_q, next_hops))
                    break


def _assert_disk_symlinks_confined(root, symlink_paths, fs=_REAL_FS):
    if not symlink_paths:
        return
    root_real = Path(fs.realpath(root))
    root_id = _dir_identity(root_real, "clean worktree root", fs=fs)
    dotgit_id = None
    try:
        dotgit_st = fs.lstat(root_real / ".git")
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise ValueError("cannot inspect clean worktree .git metadata") from exc
    else:
        dotgit_id = (dotgit_st.st_dev, dotgit_st.st_ino)

    def _has_root_ancestor(path_obj):
        cur = path_obj
        while True:
            try:
                st = fs.lstat(cur)
            except (FileNotFoundError, NotADirectoryError):
                pass
            except OSError as exc:
                raise ValueError(
                    "cannot verify symlink in clean worktree: " + os.fspath(path_obj)
                ) from exc
            else:
                if stat.S_ISDIR(st.st_mode) and (st.st_dev, st.st_ino) == root_id:
                    return True
            parent = cur.parent
            if parent == cur:
                return False
            cur = parent

    root_parts = _split_components(os.fspath(root_real))
    root_depth = len(root_parts)
    for rel_path in sorted(symlink_paths):
        resolved = list(root_parts)
        queue = deque(_split_components(rel_path))
        hops = 0
        last_is_dir = True
        while queue:
            seg = queue.popleft()
            if seg == "..":
                if not last_is_dir or len(resolved) <= root_depth:
                    raise ValueError("escaping symlink in clean worktree: " + rel_path)
                resolved.pop()
                last_is_dir = True
                continue
            if _fold_component(seg).rstrip(". ") in (".git", "git~1"):
                raise ValueError("symlink targets .git in clean worktree: " + rel_path)
            resolved.append(seg)
            acc = Path("/", *resolved)
            try:
                st = fs.lstat(acc)
            except (FileNotFoundError, NotADirectoryError):
                depth = len(resolved)
                for rem_seg in queue:
                    if rem_seg == "..":
                        depth -= 1
                        if depth < root_depth:
                            raise ValueError(
                                "escaping symlink in clean worktree: " + rel_path
                            ) from None
                        continue
                    if _fold_component(rem_seg).rstrip(". ") in (".git", "git~1"):
                        raise ValueError(
                            "symlink targets .git in clean worktree: " + rel_path
                        ) from None
                    depth += 1
                break
            except OSError as exc:
                raise ValueError("cannot verify symlink in clean worktree: " + rel_path) from exc
            if dotgit_id is not None and (st.st_dev, st.st_ino) == dotgit_id:
                raise ValueError("symlink targets .git in clean worktree: " + rel_path)
            if stat.S_ISLNK(st.st_mode):
                hops += 1
                if hops > 40:
                    raise ValueError("symlink loop in clean worktree: " + rel_path)
                try:
                    target = fs.readlink(acc)
                except OSError as exc:
                    raise ValueError(
                        "cannot verify symlink in clean worktree: " + rel_path
                    ) from exc
                if not target or os.path.isabs(target) or "\0" in target:
                    raise ValueError("escaping symlink in clean worktree: " + rel_path)
                resolved.pop()
                if len(resolved) < root_depth:
                    raise ValueError("escaping symlink in clean worktree: " + rel_path)
                last_is_dir = True
                for target_seg in reversed(_split_components(target)):
                    queue.appendleft(target_seg)
            else:
                last_is_dir = stat.S_ISDIR(st.st_mode)
        if not _has_root_ancestor(Path("/", *resolved)):
            raise ValueError("escaping symlink in clean worktree: " + rel_path)
        try:
            phys_final = Path(fs.realpath(root_real / rel_path))
        except OSError as exc:
            raise ValueError("cannot verify symlink in clean worktree: " + rel_path) from exc
        if not _has_root_ancestor(phys_final):
            raise ValueError("escaping symlink in clean worktree: " + rel_path)
        if dotgit_id is not None:
            try:
                fin_st = fs.lstat(phys_final)
            except (FileNotFoundError, NotADirectoryError):
                pass
            except OSError as exc:
                raise ValueError("cannot verify symlink in clean worktree: " + rel_path) from exc
            else:
                if (fin_st.st_dev, fin_st.st_ino) == dotgit_id:
                    raise ValueError("symlink targets .git in clean worktree: " + rel_path)


def assert_worktree_clean(repo):
    if (
        git(
            repo,
            "--work-tree",
            str(repo),
            "-c",
            "core.ignoreCase=false",
            "ls-files",
            "--others",
            "-z",
        )
        != b""
    ):
        raise ValueError("clean worktree has untracked or ignored files")
    _, staged, skipped = parse_index_stage(repo)
    if skipped:
        raise ValueError("sparse checkout cannot be used as a clean worktree")
    head = oid(repo, "HEAD")
    entries = tree_files(repo, head)
    if staged != entries:
        raise ValueError("clean worktree index differs from HEAD")
    file_mode = (
        git(repo, "config", "--type=bool", "--default", "true", "--get", "core.fileMode").strip()
        == b"true"
    )
    crlf_paths = None
    blobs = {}
    for path, (orig_mode, obj) in entries.items():
        mode, content = file_bytes(repo, path, True)
        if modes_differ(mode, orig_mode, file_mode):
            raise ValueError("clean worktree differs from HEAD: " + path)
        if b"\r\n" in content and crlf_paths is None:
            crlf_paths = crlf_normalized_paths(repo)
        if obj not in blobs:
            blobs[obj] = git(repo, "cat-file", "blob", obj)
        if not same_content(path, mode, blobs[obj], content, crlf_paths or set()):
            raise ValueError("clean worktree differs from HEAD: " + path)
    _assert_tree_symlinks_confined(entries, lambda obj: blobs[obj])
    _assert_disk_symlinks_confined(
        repo, [path for path, (mode, _) in entries.items() if mode == "120000"]
    )


def _split_components(path_str):
    return [part for part in path_str.split("/") if part and part != "."]


def _paths_within_repo(candidate, repo, fs=_REAL_FS):
    raw = os.fspath(candidate)
    repo_real = Path(fs.realpath(repo))
    repo_id = _dir_identity(repo_real, "receipt repository", fs=fs)

    def _find_repo_depth(parts):
        for idx in range(len(parts) + 1):
            cur = Path("/", *parts[:idx])
            try:
                st = fs.lstat(cur)
            except (FileNotFoundError, NotADirectoryError):
                return None
            except OSError as exc:
                raise ValueError("cannot inspect live reviewer or gate surface: " + raw) from exc
            if stat.S_ISDIR(st.st_mode) and (st.st_dev, st.st_ino) == repo_id:
                return idx
        return None

    if os.path.isabs(raw):
        resolved = []
    else:
        resolved = _split_components(fs.realpath(fs.getcwd()))
    repo_depth = _find_repo_depth(resolved)
    queue = deque(_split_components(raw))
    found = []
    entered_repo_via_symlink = False
    symlink_hops = 0
    last_is_dir = True
    while queue:
        part = queue.popleft()
        if part == "..":
            if not last_is_dir:
                if repo_depth is not None and len(resolved) > repo_depth:
                    rel = _canonical_rel_in_repo(repo_real, resolved[repo_depth:], fs=fs)
                    if rel not in found:
                        found.append(rel)
                elif entered_repo_via_symlink and repo_depth is None:
                    raise ValueError(
                        "dirty live reviewer or gate surface escapes receipt repository via symlink: "
                        + raw
                    )
                return found
            if resolved:
                resolved.pop()
                if repo_depth is not None and len(resolved) < repo_depth:
                    repo_depth = None
            last_is_dir = True
            continue
        resolved.append(part)
        acc = Path("/", *resolved)
        try:
            st = fs.lstat(acc)
        except (FileNotFoundError, NotADirectoryError) as exc:
            if repo_depth is not None:
                rel = (
                    _canonical_rel_in_repo(repo_real, resolved[repo_depth:], fs=fs)
                    if len(resolved) > repo_depth
                    else Path(".")
                )
                if rel not in found:
                    found.append(rel)
                return found
            if entered_repo_via_symlink:
                raise ValueError(
                    "dirty live reviewer or gate surface escapes receipt repository via symlink: "
                    + raw
                ) from exc
            return found
        except OSError as exc:
            raise ValueError("cannot inspect live reviewer or gate surface: " + raw) from exc
        is_link = stat.S_ISLNK(st.st_mode)
        if not is_link and stat.S_ISDIR(st.st_mode) and (st.st_dev, st.st_ino) == repo_id:
            if repo_depth is None:
                repo_depth = len(resolved)
        if repo_depth is not None and len(resolved) > repo_depth:
            if is_link:
                entered_repo_via_symlink = True
                rel = _canonical_rel_in_repo(repo_real, resolved[repo_depth:], fs=fs)
                if rel not in found:
                    found.append(rel)
            elif not queue:
                rel = _canonical_rel_in_repo(repo_real, resolved[repo_depth:], fs=fs)
                if rel not in found:
                    found.append(rel)
        if is_link:
            symlink_hops += 1
            if symlink_hops > 40:
                raise ValueError("symlink loop in live reviewer or gate surface: " + raw)
            try:
                target = fs.readlink(acc)
            except OSError as exc:
                raise ValueError("cannot inspect live reviewer or gate surface: " + raw) from exc
            target_parts = _split_components(target)
            if os.path.isabs(target):
                resolved = []
                repo_depth = _find_repo_depth(resolved)
            else:
                resolved.pop()
                if repo_depth is not None and len(resolved) < repo_depth:
                    repo_depth = None
            last_is_dir = True
            for target_part in reversed(target_parts):
                queue.appendleft(target_part)
        else:
            last_is_dir = stat.S_ISDIR(st.st_mode)
    if repo_depth is not None:
        if len(resolved) == repo_depth:
            if Path(".") not in found:
                found.append(Path("."))
        else:
            rel = _canonical_rel_in_repo(repo_real, resolved[repo_depth:], fs=fs)
            if rel not in found:
                found.append(rel)
    elif entered_repo_via_symlink:
        raise ValueError(
            "dirty live reviewer or gate surface escapes receipt repository via symlink: " + raw
        )
    return found


def _env_path_preserving_traversal(name, fs=_REAL_FS):
    value = os.environ.get(name)
    if not value:
        return None
    if os.path.isabs(value):
        return Path(value)
    return Path(os.path.join(fs.realpath(fs.getcwd()), value))


def _live_runtime_roots(fs=_REAL_FS):
    codex_homes = []
    claude_homes = []
    seen_codex = set()
    seen_claude = set()
    codex_env = _env_path_preserving_traversal("CODEX_HOME", fs=fs)
    if codex_env is not None:
        codex_homes.append(codex_env)
        seen_codex.add(os.fspath(codex_env))
    claude_env = _env_path_preserving_traversal("CLAUDE_CONFIG_DIR", fs=fs)
    if claude_env is not None:
        claude_homes.append(claude_env)
        seen_claude.add(os.fspath(claude_env))
    home = _env_path_preserving_traversal("HOME", fs=fs)
    if home is not None:
        default_codex = home / ".codex"
        if os.fspath(default_codex) not in seen_codex:
            codex_homes.append(default_codex)
        default_claude = home / ".claude"
        if os.fspath(default_claude) not in seen_claude:
            claude_homes.append(default_claude)
    roots = []
    for ch in codex_homes:
        roots.extend(
            (
                ch / "AGENTS.override.md",
                ch / "AGENTS.md",
                ch / "AGENTS.local.md",
                ch / "instructions.md",
                ch / "config.toml",
                ch / "skills",
                ch / "rules",
                ch / "packages/standalone/current/bin/codex",
                ch / "packages/standalone/current/codex",
            )
        )
    if home is not None:
        roots.extend(
            (
                home / ".agents/AGENTS.override.md",
                home / ".agents/AGENTS.md",
                home / ".agents/skills",
                home / ".gemini/GEMINI.md",
                home / ".gemini/config/GEMINI.md",
                home / ".gemini/config/GEMINI.local.md",
                home / ".gemini/config/skills",
                home / ".gemini/antigravity-cli/settings.json",
            )
        )
    for clh in claude_homes:
        roots.extend(
            (
                clh / "CLAUDE.md",
                clh / "CLAUDE.local.md",
                clh / "settings.json",
                clh / "settings.local.json",
                clh / "scripts",
                clh / "skills",
                clh / "agents",
                clh / "hooks",
            )
        )
    return roots, codex_homes, claude_homes


def _is_vendored_path(receipt_repo, rel_str, vendored_trees):
    if not rel_str or rel_str == ".":
        return False
    return vendored_dependency(receipt_repo, rel_str, vendored_trees) or vendored_dependency(
        receipt_repo, rel_str + "/_", vendored_trees
    )


def _record_live_rel(rel_paths, rel_allow_vendored, rel, allow_vendored):
    key = rel.as_posix()
    if key not in rel_allow_vendored:
        rel_allow_vendored[key] = allow_vendored
        rel_paths.append(rel)
    elif not allow_vendored:
        rel_allow_vendored[key] = False


def _walk_live_root(root, receipt_repo, rel_paths, rel_allow_vendored, vendored_trees, fs=_REAL_FS):
    def record(path, is_dir_target=False):
        rels = _paths_within_repo(path, receipt_repo, fs=fs)
        for rel in rels:
            allow_vendored = is_dir_target and not _is_vendored_path(
                receipt_repo, rel.as_posix(), vendored_trees
            )
            _record_live_rel(rel_paths, rel_allow_vendored, rel, allow_vendored)
        return rels

    try:
        root_lstat = fs.lstat(root)
        root_st = fs.stat(root) if stat.S_ISLNK(root_lstat.st_mode) else root_lstat
    except (FileNotFoundError, NotADirectoryError):
        record(root, is_dir_target=False)
        return
    except OSError as exc:
        raise ValueError(
            "cannot inspect live reviewer or gate surface: " + os.fspath(root)
        ) from exc
    root_is_dir = stat.S_ISDIR(root_st.st_mode)
    root_rels = record(root, is_dir_target=root_is_dir)
    if not root_is_dir:
        return
    repo_id = _dir_identity(Path(fs.realpath(receipt_repo)), "receipt repository", fs=fs)
    if (root_st.st_dev, root_st.st_ino) == repo_id:
        return
    root_covered = bool(root_rels) and all(
        not _is_vendored_path(receipt_repo, rel.as_posix(), vendored_trees) for rel in root_rels
    )
    visited_dirs = {(root_st.st_dev, root_st.st_ino)}
    stack = [(root, root_covered)]
    while stack:
        current, covered_by_repo_dir = stack.pop()
        try:
            with fs.scandir(current) as it:
                entries = sorted(it, key=lambda entry: entry.name)
        except OSError as exc:
            raise ValueError(
                "cannot traverse live reviewer or gate surface: " + os.fspath(current)
            ) from exc
        for entry in entries:
            child = Path(entry.path)
            try:
                child_lstat = fs.lstat(child)
            except (FileNotFoundError, NotADirectoryError):
                if not covered_by_repo_dir:
                    record(child, is_dir_target=False)
                continue
            except OSError as exc:
                raise ValueError(
                    "cannot inspect live reviewer or gate surface: " + os.fspath(child)
                ) from exc
            if stat.S_ISLNK(child_lstat.st_mode):
                try:
                    child_st = fs.stat(child)
                except (FileNotFoundError, NotADirectoryError):
                    record(child, is_dir_target=False)
                    continue
                except OSError as exc:
                    raise ValueError(
                        "cannot inspect live reviewer or gate surface: " + os.fspath(child)
                    ) from exc
                child_is_dir = stat.S_ISDIR(child_st.st_mode)
                child_rels = record(child, is_dir_target=child_is_dir)
                if child_is_dir:
                    dir_id = (child_st.st_dev, child_st.st_ino)
                    if dir_id == repo_id or dir_id in visited_dirs:
                        continue
                    visited_dirs.add(dir_id)
                    child_covered = bool(child_rels) and all(
                        not _is_vendored_path(receipt_repo, rel.as_posix(), vendored_trees)
                        for rel in child_rels
                    )
                    stack.append((child, child_covered))
                continue
            child_is_dir = stat.S_ISDIR(child_lstat.st_mode)
            if covered_by_repo_dir:
                if not child_is_dir:
                    continue
                dir_id = (child_lstat.st_dev, child_lstat.st_ino)
                if dir_id == repo_id or dir_id in visited_dirs:
                    continue
                if _fold_component(entry.name) == "node_modules" and any(
                    _is_vendored_path(receipt_repo, rel.as_posix(), vendored_trees)
                    for rel in _paths_within_repo(child, receipt_repo, fs=fs)
                ):
                    continue
                visited_dirs.add(dir_id)
                stack.append((child, True))
                continue
            child_rels = record(child, is_dir_target=child_is_dir)
            if child_is_dir:
                dir_id = (child_lstat.st_dev, child_lstat.st_ino)
                if dir_id == repo_id or dir_id in visited_dirs:
                    continue
                visited_dirs.add(dir_id)
                child_covered = bool(child_rels) and all(
                    not _is_vendored_path(receipt_repo, rel.as_posix(), vendored_trees)
                    for rel in child_rels
                )
                stack.append((child, child_covered))


def _executable_candidates(executable, launcher=None, reviewer=None, fs=_REAL_FS):
    candidates = []
    seen = set()
    values = []
    if executable:
        values.append(executable)
    if launcher:
        values.append(launcher)
    if reviewer in (None, "codex"):
        codex_bin = os.environ.get("CODEX_GATE_BIN")
        if codex_bin:
            values.append(codex_bin)
        elif not launcher:
            values.append("codex")
    elif reviewer == "antigravity" and not launcher:
        values.append("agy")
    for raw_val in values:
        if "/" in raw_val or (os.sep != "/" and os.sep in raw_val):
            cand = (
                Path(raw_val)
                if os.path.isabs(raw_val)
                else Path(os.path.join(fs.realpath(fs.getcwd()), raw_val))
            )
        else:
            found = shutil.which(raw_val)
            if not found:
                continue
            cand = Path(found)
        key = os.fspath(cand)
        if key not in seen:
            seen.add(key)
            candidates.append(cand)
    return candidates


def assert_live_runtime_clean(
    receipt_repo, executable=None, launcher=None, reviewer=None, fs=_REAL_FS
):
    rel_paths = []
    rel_allow_vendored = {}
    vendored_trees = {}
    fixed_candidates = [Path(__file__)]
    fixed_candidates.extend(
        _executable_candidates(executable, launcher=launcher, reviewer=reviewer, fs=fs)
    )
    for base_candidate in fixed_candidates:
        for rel in _paths_within_repo(base_candidate, receipt_repo, fs=fs):
            _record_live_rel(rel_paths, rel_allow_vendored, rel, allow_vendored=False)
    seen_walked_roots = set()
    helper_dirs = [Path(__file__).parent]
    real_helper_dir = Path(fs.realpath(__file__)).parent
    if not _same_existing_path(real_helper_dir, helper_dirs[0], fs=fs):
        helper_dirs.append(real_helper_dir)
    for helper_dir in helper_dirs:
        raw_helper_dir = os.fspath(helper_dir)
        if raw_helper_dir not in seen_walked_roots:
            seen_walked_roots.add(raw_helper_dir)
            _walk_live_root(
                helper_dir, receipt_repo, rel_paths, rel_allow_vendored, vendored_trees, fs=fs
            )
    roots, codex_roots, claude_roots = _live_runtime_roots(fs=fs)
    for ch in codex_roots + claude_roots:
        for rel in _paths_within_repo(ch, receipt_repo, fs=fs):
            if rel != Path("."):
                raw_ch = os.fspath(ch)
                if raw_ch not in seen_walked_roots:
                    seen_walked_roots.add(raw_ch)
                    _walk_live_root(
                        ch, receipt_repo, rel_paths, rel_allow_vendored, vendored_trees, fs=fs
                    )
                break
    for root in roots:
        raw_root = os.fspath(root)
        if raw_root not in seen_walked_roots:
            seen_walked_roots.add(raw_root)
            _walk_live_root(
                root, receipt_repo, rel_paths, rel_allow_vendored, vendored_trees, fs=fs
            )
    if not rel_paths:
        return
    head = oid(receipt_repo, "HEAD")
    head_entries = tree_files(receipt_repo, head)
    _, staged, skipped = parse_index_stage(receipt_repo)
    file_mode = (
        git(
            receipt_repo,
            "config",
            "--type=bool",
            "--default",
            "true",
            "--get",
            "core.fileMode",
        ).strip()
        == b"true"
    )
    crlf_paths = None
    blobs = {}
    all_tracked = set(head_entries) | set(staged)
    pinned = ("--work-tree", str(receipt_repo), "-c", "core.ignoreCase=false")

    def _fold_alias_matches(a_rel, b_rel, label):
        def _lstat_rel(rel_p):
            try:
                return fs.lstat(receipt_repo / rel_p)
            except (FileNotFoundError, NotADirectoryError):
                return None
            except OSError as exc:
                raise ValueError("cannot inspect live reviewer or gate surface: " + label) from exc

        st_a = _lstat_rel(a_rel)
        st_b = _lstat_rel(b_rel)
        if st_a is not None and st_b is not None:
            return (st_a.st_dev, st_a.st_ino) == (st_b.st_dev, st_b.st_ino)
        return st_a is None and st_b is None

    for rel in rel_paths:
        rel_str = rel.as_posix()
        allow_vendored = rel_allow_vendored[rel_str]
        if not rel.parts:
            matching = set(all_tracked)
            others_args = (*pinned, "ls-files", "--others", "-z")
        else:
            matching = {
                p
                for p in all_tracked
                if p == rel_str or p.startswith(rel_str + "/") or rel_str.startswith(p + "/")
            }
            rel_fold = _fold_path(rel_str)
            rel_parts = rel.parts
            for p in all_tracked:
                if p in matching:
                    continue
                p_fold = _fold_path(p)
                if p_fold == rel_fold:
                    if _fold_alias_matches(rel_str, p, rel_str):
                        matching.add(p)
                elif p_fold.startswith(rel_fold + "/"):
                    if _fold_alias_matches(
                        rel_str, "/".join(p.split("/")[: len(rel_parts)]), rel_str
                    ):
                        matching.add(p)
                elif rel_fold.startswith(p_fold + "/"):
                    p_parts = p.split("/")
                    if _fold_alias_matches("/".join(rel_parts[: len(p_parts)]), p, rel_str):
                        matching.add(p)

            for idx in range(1, len(rel_parts) + 1):
                prefix_str = "/".join(rel_parts[:idx])
                try:
                    fs.lstat(receipt_repo / prefix_str / ".git")
                except (FileNotFoundError, NotADirectoryError):
                    pass
                except OSError as exc:
                    raise ValueError(
                        "cannot inspect live reviewer or gate surface: " + rel_str
                    ) from exc
                else:
                    if not (
                        allow_vendored
                        and vendored_dependency(receipt_repo, rel_str, vendored_trees)
                    ):
                        raise ValueError(
                            "dirty live reviewer or gate surface in receipt repository: " + rel_str
                        )

            try:
                rel_st = fs.lstat(receipt_repo / rel_str)
            except (FileNotFoundError, NotADirectoryError):
                rel_st = None
            except OSError as exc:
                raise ValueError(
                    "cannot inspect live reviewer or gate surface: " + rel_str
                ) from exc
            if (
                rel_st is not None
                and not stat.S_ISDIR(rel_st.st_mode)
                and not matching
                and not (
                    allow_vendored and vendored_dependency(receipt_repo, rel_str, vendored_trees)
                )
            ):
                raise ValueError(
                    "dirty live reviewer or gate surface in receipt repository: " + rel_str
                )

            others_args = (*pinned, "ls-files", "--others", "-z", "--", ":(literal)" + rel_str)
        for raw in git(receipt_repo, *others_args).split(b"\0"):
            if not raw:
                continue
            other = os.fsdecode(raw)
            if not (allow_vendored and vendored_dependency(receipt_repo, other, vendored_trees)):
                raise ValueError(
                    "dirty live reviewer or gate surface in receipt repository: " + other
                )
        for path in sorted(matching):
            if path in skipped or staged.get(path) != head_entries.get(path):
                raise ValueError(
                    "dirty live reviewer or gate surface in receipt repository: " + path
                )
            orig_mode, obj = head_entries[path]
            mode, content = file_bytes(receipt_repo, path, True)
            if modes_differ(mode, orig_mode, file_mode):
                raise ValueError(
                    "dirty live reviewer or gate surface in receipt repository: " + path
                )
            if b"\r\n" in content and crlf_paths is None:
                crlf_paths = crlf_normalized_paths(receipt_repo)
            if obj not in blobs:
                blobs[obj] = git(receipt_repo, "cat-file", "blob", obj)
            if not same_content(path, mode, blobs[obj], content, crlf_paths or set()):
                raise ValueError(
                    "dirty live reviewer or gate surface in receipt repository: " + path
                )


def committed_instruction_links(entries, base_entries, blob):
    bindings = {}
    dir_prefixes = set()
    symlink_paths = set()
    for path, (mode, _) in entries.items():
        if mode == "120000":
            symlink_paths.add(path)
        parent = Path(path).parent
        while parent != Path("."):
            dir_prefixes.add(parent.as_posix())
            parent = parent.parent
    links = {path for path, (mode, _) in entries.items() if mode == "120000" and instruction(path)}
    for path in sorted(links):

        def unsupported(reason, path=path):
            raise ValueError("unsupported instruction symlink: " + path + " (" + reason + ")")

        if entries.get(path) != base_entries.get(path):
            unsupported("changed link needs separate instruction review")
        _, obj = entries[path]
        content = blob(obj)
        link_text = os.fsdecode(content)
        if (
            not link_text
            or link_text.startswith("/")
            or link_text.endswith("/")
            or "\0" in link_text
        ):
            unsupported("target must be relative and stay within the repository")
        raw_parts = link_text.split("/")
        if "" in raw_parts or raw_parts[-1] == ".":
            unsupported("target must resolve to the captured instruction file")
        parts = list(Path(path).parent.parts)
        for segment in raw_parts:
            if parts:
                prefix = "/".join(parts)
                if prefix in symlink_paths:
                    unsupported("target must not traverse a symlink ancestor")
                if prefix not in dir_prefixes:
                    unsupported("target must resolve through existing directories")
            if segment == ".":
                continue
            if segment == "..":
                if not parts:
                    unsupported("target must stay within the repository")
                parts.pop()
            else:
                parts.append(segment)
        if not parts:
            unsupported("target must be a recognized instruction file")
        target = "/".join(parts)
        if not instruction(target) or private_agent_data(target):
            unsupported("target must be a recognized instruction file")
        target_mode, target_obj = entries.get(target, ("missing", None))
        if target_mode not in ("100644", "100755"):
            unsupported("target must be a regular instruction file in HEAD and index")
        if entries.get(target) != base_entries.get(target):
            unsupported("changed target needs separate instruction review")
        bindings[path] = {
            "target": target,
            "link_object": obj,
            "link_sha256": digest(content),
            "target_object": target_obj,
            "target_mode": target_mode,
            "target_sha256": digest(blob(target_obj)),
        }
    return bindings


def capture_committed_objects(repo, base, base_commit=None):
    head = oid(repo, "HEAD")
    if base_commit is None:
        if not base:
            raise ValueError("base could not be resolved")
        base_commit = oid(repo, base)
    else:
        base_commit = oid(repo, base_commit)
    merge = git(repo, "merge-base", base_commit, head).decode().strip()
    tree = git(repo, "rev-parse", head + "^{tree}").decode().strip()
    entries = tree_files(repo, head)
    base_entries = tree_files(repo, merge)
    diff_args = (
        "--attr-source=" + head,
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--no-renames",
        "--no-color",
        "--ignore-submodules=none",
    )
    paths = [
        os.fsdecode(p)
        for p in git(repo, *diff_args, "--name-only", "-z", merge, head, "--").split(b"\0")
        if p
    ]
    private_inputs = [path for path in set(entries) | set(paths) if private_agent_data(path)]
    if private_inputs:
        raise ValueError(
            "private agent runtime data cannot be sent for review: "
            + ", ".join(sorted(private_inputs))
        )
    blobs = {}

    def blob(obj):
        if obj is None:
            return b""
        if obj not in blobs:
            blobs[obj] = git(repo, "cat-file", "blob", obj)
        return blobs[obj]

    links = committed_instruction_links(entries, base_entries, blob)
    changed_modes = {
        path: [
            base_entries.get(path, ("missing", None))[0],
            entries.get(path, ("missing", None))[0],
        ]
        for path in paths
    }
    full = git(repo, *diff_args, "--binary", merge, head, "--")
    review_paths = [path for path in paths if not excluded(path, changed_modes[path])]
    patch = (
        git(
            repo,
            *diff_args,
            "--text",
            merge,
            head,
            "--",
            *(":(literal)" + path for path in review_paths),
        )
        if review_paths
        else b""
    )
    if b"\0" in patch:
        raise ValueError("binary content cannot be delivered in a fenced text review")
    patch.decode("utf-8")
    artifact = {
        "head": head,
        "tree": tree,
        "base": {"ref": base, "commit": base_commit, "merge_base": merge},
        "scope": "committed",
        "diff_sha256": digest(full),
        "review_diff_sha256": digest(patch),
        "changed_paths": paths,
        "changed_modes": changed_modes,
        "instruction_links": links,
    }
    return artifact, patch


def stable_committed_objects(repo, base, base_commit=None):
    if base_commit is None:
        if not base:
            raise ValueError("base could not be resolved")
        base_commit = oid(repo, base)
    else:
        base_commit = oid(repo, base_commit)
    first, patch = capture_committed_objects(repo, base, base_commit)
    second, patch2 = capture_committed_objects(repo, base, base_commit)
    if first != second or patch != patch2:
        raise ValueError("repository changed during review snapshot")
    return first, patch


def layout(repo):
    repo = repo_root(repo)
    directory = git_dir(repo)
    receipts = receipts_dir(repo)
    receipts.mkdir(mode=0o700, exist_ok=True)
    os.chmod(receipts, 0o700)
    return repo, directory, receipts


def tree_files(repo, ref):
    entries = {}
    for entry in git(repo, "ls-tree", "-rz", "--full-tree", ref).split(b"\0"):
        if entry:
            meta, path = entry.split(b"\t", 1)
            mode, kind, obj = meta.decode().split()
            if kind != "blob":
                raise ValueError("submodule snapshots are unsupported; review separately")
            entries[os.fsdecode(path)] = (mode, obj)
    return entries


def crlf_normalized_paths(repo):
    autocrlf = (
        git(repo, "config", "--default", "false", "--get", "core.autocrlf").decode().strip().lower()
    )
    if autocrlf != "input":
        autocrlf = (
            git(repo, "config", "--type=bool", "--default", "false", "--get", "core.autocrlf")
            .decode()
            .strip()
        )
    paths = set()
    # Native EOL metadata applies attributes without invoking clean filters.
    for entry in git(repo, "ls-files", "--eol", "-z").split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        info, _, attribute = metadata.partition(b"attr/")
        attrs, eol = attribute.split(), info.split()
        automatic = b"text=auto" in attrs or not attrs and autocrlf in ("true", "input")
        forced = (
            b"text" in attrs
            or not automatic
            and any(value in attrs for value in (b"eol=lf", b"eol=crlf"))
        )
        # Automatic conversion obeys Git's content classification and normalized
        # index; forced text can deliberately override native binary detection.
        native_text = b"i/lf" in eol and any(value in eol for value in (b"w/crlf", b"w/mixed"))
        if b"-text" not in attrs and (forced or automatic and native_text):
            paths.add(os.fsdecode(path))
    return paths


def same_content(path, mode, original, content, crlf_paths):
    return (
        content == original
        or mode in ("100644", "100755")
        and path in crlf_paths
        and b"\r" not in original
        and b"\0" not in original
        and content.replace(b"\r\n", b"\n") == original
    )


def instruction_links(
    repo, entries, staged, workspace, base_entries, blob, crlf_paths, file_mode=True
):
    bindings = {}
    links = {
        path
        for state in (entries, staged, workspace)
        for path, (mode, _) in state.items()
        if mode == "120000" and instruction(path)
    }
    for path in sorted(links):

        def unsupported(reason, path=path):
            raise ValueError("unsupported instruction symlink: " + path + " (" + reason + ")")

        mode, content = workspace.get(path, ("missing", b""))
        original_mode, obj = entries.get(path, ("missing", None))
        if (
            mode != "120000"
            or original_mode != mode
            or staged.get(path) != entries.get(path)
            or content != blob(obj)
        ):
            unsupported("link must match HEAD, index, and worktree")
        if entries.get(path) != base_entries.get(path):
            unsupported("changed link needs separate instruction review")
        link_text = os.fsdecode(content)
        if not link_text or os.path.isabs(link_text):
            unsupported("target must be relative and stay within the repository")
        parts = list(Path(path).parent.parts)
        for part in Path(link_text).parts:
            if part == "..":
                if not parts:
                    unsupported("target must stay within the repository")
                parts.pop()
            else:
                parts.append(part)
        target = str(Path(*parts))
        # Arbitrary target names would evade the gates' existing instruction
        # classification (including passive-file exclusions and self-review).
        # Keep this exception to one hop into an already recognized surface.
        if not parts or not instruction(target) or private_agent_data(target):
            unsupported("target must be a recognized instruction file")
        target_mode, target_obj = entries.get(target, ("missing", None))
        if target_mode not in ("100644", "100755") or staged.get(target) != entries.get(target):
            unsupported("target must be a regular instruction file in HEAD and index")
        # A changed CLAUDE.md target is also a changed AGENTS.md instruction,
        # but the Codex gate's static self-review guard cannot follow aliases.
        if entries.get(target) != base_entries.get(target):
            unsupported("changed target needs separate instruction review")
        # Inspect the uncollapsed path so missing/../ or a symlink ancestor
        # cannot acquire the identity of a different, normalized Git path.
        actual_mode, actual_bytes = file_bytes(repo, str(Path(path).parent / link_text))
        if (
            (actual_mode, actual_bytes) != workspace.get(target)
            or modes_differ(actual_mode, target_mode, file_mode)
            or not same_content(target, target_mode, blob(target_obj), actual_bytes, crlf_paths)
        ):
            unsupported("target must match HEAD, index, and worktree")
        # Path normalizes trailing / and /. even when those make a live link
        # dangling. Confirm the link actually reaches the captured file.
        try:
            resolves = os.path.samefile(repo / path, repo / target)
        except OSError:
            resolves = False
        if not resolves:
            unsupported("link must resolve to the captured instruction file")
        bindings[path] = {
            "target": target,
            "link_object": obj,
            "link_sha256": digest(content),
            "target_object": target_obj,
            "target_mode": target_mode,
            "target_sha256": digest(actual_bytes),
        }
    return bindings


def capture(repo, base, scope, base_commit=None):
    head = oid(repo, "HEAD")
    if base_commit is None and base:
        base_commit = oid(repo, base)
    if scope == "committed" and base_commit is None:
        raise ValueError("base could not be resolved")
    merge = (
        git(repo, "merge-base", base_commit, head).decode().strip()
        if scope == "committed"
        else None
    )
    tree = git(repo, "rev-parse", head + "^{tree}").decode().strip()
    index = git(repo, "ls-files", "--stage", "-t", "-z")
    staged, skipped = {}, set()
    for entry in index.split(b"\0"):
        if not entry:
            continue
        metadata, path_bytes = entry.split(b"\t", 1)
        tag, mode, obj, stage = metadata.decode().split()
        path = os.fsdecode(path_bytes)
        if mode == "160000":
            raise ValueError("submodule snapshots are unsupported; review separately")
        if stage != "0":
            raise ValueError("unmerged index cannot be reviewed")
        staged[path] = (mode, obj)
        if tag == "S":
            skipped.add(path)
    sparse = (
        git(
            repo, "config", "--type=bool", "--default", "false", "--get", "core.sparseCheckout"
        ).strip()
        == b"true"
    )
    file_mode = (
        git(repo, "config", "--type=bool", "--default", "true", "--get", "core.fileMode").strip()
        == b"true"
    )
    entries = tree_files(repo, head)
    base_entries = tree_files(repo, merge) if scope == "committed" else entries
    tracked = set(staged)
    tracked_files = {
        path for path, (mode, _) in staged.items() if mode in ("100644", "100755", "120000")
    }
    worktrees = own_worktrees(repo)
    # Remove only Git's output delimiter, as layout() does: a trailing whitespace
    # byte belongs to the path, and stripping it named a different store that no
    # real worktree's pointer could match (#541).
    common = os.fsdecode(
        git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").removesuffix(b"\n")
    )
    store = os.path.realpath(os.path.join(common, "worktrees"))
    common = os.path.realpath(common)

    def own_boundary(path):
        # Git stops at any directory that looks like a repository, so an entry is
        # dropped only when it is one of *this* repo's worktrees: the registered
        # path matches, and the directory's `.git` pointer names a gitdir in this
        # repo's worktree store that points back at that same pointer file.
        # Neither half suffices alone. Git keeps listing a registration whose
        # directory was removed, and stops calling it prunable once anything
        # occupies the path again; and a `.git` file proves nothing about
        # ownership, since `git init --separate-git-dir` writes one that points at
        # a foreign repository (#474).
        if not path.endswith("/"):
            return False
        directory = repo / path.rstrip("/")
        if os.path.realpath(directory) not in worktrees:
            return False
        # The primary checkout is registered too, and can sit beneath a linked
        # worktree, but it holds the common Git directory itself rather than a
        # pointer file (#540). A real directory (never a symlink to one) whose
        # realpath IS this repository's common directory is that checkout.
        try:
            primary = stat.S_ISDIR((directory / ".git").lstat().st_mode)
        except OSError:
            primary = False
        if primary:
            return os.path.realpath(directory / ".git") == common
        gitdir = worktree_gitdir(directory)
        if gitdir is None or os.path.dirname(gitdir) != store:
            return False
        registered = registered_worktree(gitdir)
        if registered is None:
            return False
        return os.path.realpath(registered) == os.path.realpath(directory / ".git")

    untracked = {
        os.fsdecode(p)
        for p in git(
            repo, "-c", "core.ignoreCase=false", "ls-files", "--others", "--exclude-standard", "-z"
        ).split(b"\0")
        if p and not own_boundary(os.fsdecode(p))
    }
    paths = []
    if scope == "committed":
        args = (
            "--attr-source=" + head,
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "--no-color",
            "--ignore-submodules=none",
        )
        paths = [
            os.fsdecode(p)
            for p in git(repo, *args, "--name-only", "-z", merge, head, "--").split(b"\0")
            if p
        ]
    private_inputs = [
        path for path in set(entries) | tracked | untracked | set(paths) if private_agent_data(path)
    ]
    if private_inputs:
        raise ValueError(
            "private agent runtime data cannot be sent for review: "
            + ", ".join(sorted(private_inputs))
        )

    def inspect_boundary(entry):
        """Refuse a foreign boundary that could be hiding an instruction file.

        `ls-files` collapses a directory it will not descend into to one
        trailing-slash entry, and a hand-made `.git` earns that. This used to be
        decided by `instruction(entry)`, so a boundary whose own path was not an
        instruction path — `vendor/nested/` — was dropped and the instruction file
        beneath it was never seen, leaving the receipt's "no dirty instruction
        surface" claim false (#496). Every boundary is inspected now, whatever its
        own name: a real repository with no instruction file behind it is allowed,
        and everything else refuses — a boundary that is not a usable repository,
        one holding an instruction file, or one holding a further boundary, which
        this deliberately does not descend into.
        """
        prefix = entry.rstrip("/")
        listing = boundary_listing(repo / prefix)
        if listing is None:
            raise ValueError("cannot inspect repository boundary: " + entry)
        for mode, name in listing:
            path = prefix + "/" + name
            if name.endswith("/"):
                raise ValueError("repository boundary nested behind a boundary: " + path)
            # A gitlink is a whole tree behind one bare path: `ls-files` neither
            # marks it with a trailing slash nor enumerates what it holds, so an
            # ordinary submodule name passed every other check while an instruction
            # file sat underneath it. Refuse whether or not it is populated —
            # unenumerable is unenumerable.
            if mode == "160000":
                raise ValueError("submodule behind repository boundary is uninspectable: " + path)
            # Backstop for any listing that disagrees with the working tree: a path
            # listed as a file while the disk holds a directory was not enumerated
            # either.
            try:
                if stat.S_ISDIR((repo / prefix / name).lstat().st_mode):
                    raise ValueError(
                        "listed path behind repository boundary is a directory: " + path
                    )
            except (FileNotFoundError, NotADirectoryError):
                pass
            if instruction(path):
                raise ValueError("instruction surface hidden behind repository boundary: " + path)

    ignored_instructions = set()
    vendored_trees = {}
    for raw in git(
        repo,
        "-c",
        "core.ignoreCase=false",
        "ls-files",
        "--others",
        "--ignored",
        "--exclude-standard",
        "-z",
    ).split(b"\0"):
        if not raw:
            continue
        entry = os.fsdecode(raw)
        # own_boundary: one of this repo's own worktrees, listed as a directory
        # entry git will not descend into. Nothing behind that boundary is an
        # instruction surface of this repo, and untracked_sha256 must not bind to
        # the entry (#474). private_agent_data: ignored agent runtime state is
        # dropped from the sweep rather than blocking a review, as it has been
        # since that data stopped being sent for review — including when it is
        # itself a boundary, whose contents this never captures either way.
        if (
            own_boundary(entry)
            or private_agent_data(entry)
            or vendored_dependency(repo, entry, vendored_trees)
        ):
            continue
        if entry.endswith("/"):
            inspect_boundary(entry)
            continue
        if instruction(entry):
            ignored_instructions.add(entry)
    files, workspace, omitted, blobs = {}, {}, set(), {}

    def blob(obj):
        if obj is None:
            return b""
        if obj not in blobs:
            blobs[obj] = git(repo, "cat-file", "blob", obj)
        return blobs[obj]

    dirty_instructions = [p for p in entries if instruction(p) and p not in tracked]
    for path in sorted(set(entries) | tracked | untracked | ignored_instructions):
        mode, content = file_bytes(repo, path, path in entries or path in tracked_files)
        files[path] = (mode, digest(content))
        workspace[path] = (mode, content)
        if mode == "missing" and sparse and path in skipped:
            omitted.add(path)
    # Keep semantic cleanliness separate from the raw bytes bound above.
    crlf_paths = (
        crlf_normalized_paths(repo)
        if any(b"\r\n" in data for mode, data in workspace.values())
        else set()
    )
    links = instruction_links(
        repo, entries, staged, workspace, base_entries, blob, crlf_paths, file_mode
    )
    for path, (mode, content) in workspace.items():
        if instruction(path):
            original_mode, obj = entries.get(path, ("missing", None))
            if path not in omitted and (
                modes_differ(mode, original_mode, file_mode)
                or not same_content(path, mode, blob(obj), content, crlf_paths)
            ):
                dirty_instructions.append(path)
            if path in staged and entries.get(path) != staged[path]:
                dirty_instructions.append(path)
    if scope == "committed" and dirty_instructions:
        raise ValueError(
            "dirty instruction surface outside committed target: "
            + ", ".join(sorted(set(dirty_instructions)))
        )
    changed_modes = {}
    if scope == "committed":
        changed_modes = {
            path: [
                base_entries.get(path, ("missing", None))[0],
                entries.get(path, ("missing", None))[0],
            ]
            for path in paths
        }
        full = git(repo, *args, "--binary", merge, head, "--")
        # --text keeps executable text covered even when attributes call it binary.
        review_paths = [path for path in paths if not excluded(path, changed_modes[path])]
        patch = (
            git(
                repo,
                *args,
                "--text",
                merge,
                head,
                "--",
                *(":(literal)" + path for path in review_paths),
            )
            if review_paths
            else b""
        )
    else:
        chunks, paths = [], []
        for path in sorted(workspace):
            original_mode, obj = entries.get(path, ("missing", None))
            staged_mode, staged_obj = staged.get(path, ("missing", None))
            if path in omitted and (original_mode, obj) == (staged_mode, staged_obj):
                continue
            original, staged_content = blob(obj), blob(staged_obj)
            mode, content = (staged_mode, staged_content) if path in omitted else workspace[path]
            staged_changed = (original_mode, obj) != (staged_mode, staged_obj)
            worktree_mode_changed = modes_differ(mode, staged_mode, file_mode)
            worktree_changed = worktree_mode_changed or not same_content(
                path, mode, staged_content, content, crlf_paths
            )
            if not staged_changed and not worktree_changed:
                continue
            effective_mode = staged_mode if not worktree_mode_changed else mode
            paths.append(path)
            changed_modes[path] = [original_mode, staged_mode, effective_mode]
            if excluded(path, changed_modes[path]):
                continue
            for label, changed, before_mode, before_bytes, after_mode, after_bytes in (
                ("staged", staged_changed, original_mode, original, staged_mode, staged_content),
                (
                    "worktree",
                    worktree_changed,
                    staged_mode,
                    staged_content,
                    effective_mode,
                    content,
                ),
            ):
                if not changed:
                    continue
                before, after = before_bytes.decode("utf-8"), after_bytes.decode("utf-8")
                before_path, after_path = quote_git_path("a/" + path), quote_git_path("b/" + path)
                header = f"diff --git {before_path} {after_path}\nreview state {label}\nold mode {before_mode}\nnew mode {after_mode}\n"
                lines = difflib.unified_diff(
                    physical_lines(before),
                    physical_lines(after),
                    fromfile=before_path,
                    tofile=after_path,
                )
                body = "".join(
                    line if line.endswith("\n") else line + "\n\\ No newline at end of file\n"
                    for line in lines
                )
                chunks.append((header + body).encode())
        patch = b"\n".join(chunks)
        full = encoded({"head": head, "files": files, "index": digest(index)})
    if b"\0" in patch:
        raise ValueError("binary content cannot be delivered in a fenced text review")
    patch.decode("utf-8")
    artifact = {
        "head": head,
        "tree": tree,
        "base": {"ref": base, "commit": base_commit, "merge_base": merge},
        "scope": scope,
        "index_sha256": digest(index),
        "worktree_sha256": digest(encoded(files)),
        "untracked_sha256": digest(encoded(sorted(untracked | ignored_instructions))),
        "diff_sha256": digest(full),
        "review_diff_sha256": digest(patch),
        "changed_paths": paths,
        "changed_modes": changed_modes,
        "instruction_links": links,
    }
    return artifact, patch


def stable_capture(repo, base, scope, base_commit=None):
    """Two identical captures of the artifact against ONE resolved base commit.

    The base ref is resolved once, here, or taken pinned from the snapshot being
    verified. `origin/main` is shared by every worktree, so a sibling's fetch
    moving it mid-run used to look like this branch changing and voided a whole
    review (#680). The branch's own HEAD, tree, index and files still have to
    match exactly; only the base tip is no longer re-read.
    """
    if base_commit is None and base:
        base_commit = oid(repo, base)
    first, patch = capture(repo, base, scope, base_commit)
    second, patch2 = capture(repo, base, scope, base_commit)
    if first != second or patch != patch2:
        raise ValueError("repository changed during review snapshot")
    return first, patch


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".receipt-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded(value) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("missing or unsafe receipt: " + str(path))
    return json.loads(path.read_bytes())


def invalidate(receipts, lane, sequence=None, clean_worktree=False):
    attempt = uuid.uuid4().hex
    marker = {"attempt": attempt}
    if sequence is not None:
        # Bound to the attempt, so a receipt whose captured_sequence was edited
        # no longer matches its live attempt (#573).
        marker["sequence"] = sequence
    if clean_worktree:
        marker["clean_worktree"] = True
    atomic_json(receipts / (lane + ".attempt.json"), marker)
    (receipts / (lane + ".json")).unlink(missing_ok=True)
    return attempt


@contextlib.contextmanager
def attempt_lock(receipts):
    """Hold the receipt directory's exclusive lock for one attempt transition.

    `supersede` is several file operations, and two gates claiming at once could
    interleave them: each retired the OTHER lane before either marked its own
    attempt, so both tokens ended up live and a blocking verdict in one lane was
    again bypassable by the other lane's approval. Every writer of the shared
    attempt and receipt state runs inside this lock, so no run ever observes a
    half-finished transition.

    flock, not a lock directory: the
    kernel releases it when the holder dies, so a killed or cancelled gate cannot
    wedge the next one. Acquired only by the outermost callers (`capture`,
    `claim`, `complete`, `check`'s final assertion, the `invalidate` subcommand)
    — an flock is held per open file description, so a nested acquisition in the
    same process would deadlock. `check` holds it only for its deciding
    assertion, never across its artifact capture: a long check must not block a
    gate (#533).
    """
    # O_NOFOLLOW for the reason read_json refuses a symlink: nothing in the
    # receipt directory may redirect writes outside it. The file holds no data.
    descriptor = os.open(
        receipts / ".lock",
        os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
    )
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def supersede(receipts, record):
    """Retire every OTHER lane's evidence for this artifact and mark `record` claimed.

    A review that reaches a verdict in one lane must not leave another lane's
    older approval standing: both gates exit 2 on blocking findings WITHOUT
    recording a receipt, so the only trace of a blocked review is the claim it
    made. githooks/pre-push calls `check` with no `--reviewer`, which accepts
    either lane's receipt, so a surviving competing approval would ship the diff
    the newest verdict rejected. Bumping the competing attempt token as well
    supersedes a review already in flight there, so the only receipt that can
    exist is the one this attempt records. Re-running a lane and approving ships
    as before — this closes a bypass, not a lane.

    This runs at `claim`, not at capture (#499): a gate claims only once its
    feasibility checks have passed, so a lane that degrades (exit 3) — reviewer
    missing, a size cap, an unverifiable model pin — retires nothing but its own
    lane, and a degraded lane stays what MULTI-AGENT.md says it is: not a verdict.

    The attempt must still be live: a claim racing another lane's claim, or a
    newer capture in its own lane, refuses rather than reviving a superseded run,
    and it retires every lane, its own included, before refusing (fail closed).
    The competing lanes go first: an interruption must never leave a lane OTHER
    than this one holding evidence the new review is overriding. Callers hold
    `attempt_lock`, which is what makes the whole transition atomic against a
    concurrent gate rather than merely ordered.
    """
    lane = record["reviewer"]["name"]
    if lane not in LANES:
        raise ValueError("unknown review lane: " + str(lane))
    try:
        assert_attempt(record)
    except ValueError:
        # A superseded attempt still reached a verdict, and `claim` cannot tell
        # whether it was blocking. Fail closed: retire EVERY lane before refusing,
        # its own included, so no approval recorded by the attempt that superseded
        # this one — another lane's or a newer run in this lane — can outlive a
        # blocking verdict on the same artifact. Racing attempts all lose and one
        # reruns.
        for any_lane in LANES:
            invalidate(receipts, any_lane)
        raise
    for other in LANES:
        if other != lane:
            invalidate(receipts, other)
    claimed = {"attempt": record["attempt"], "claimed": True}
    if "captured_sequence" in record:
        claimed["sequence"] = record["captured_sequence"]
    if is_clean_worktree(record):
        claimed["clean_worktree"] = True
    atomic_json(receipts / (lane + ".attempt.json"), claimed)


def assert_attempt(record, claimed=False):
    _, _, receipts = layout(record["repository"])
    marker = read_json(receipts / (record["reviewer"]["name"] + ".attempt.json"))
    clean = is_clean_worktree(record)
    if "clean_worktree" in marker and marker["clean_worktree"] is not True:
        raise ValueError("malformed clean_worktree attempt marker")
    if (
        marker["attempt"] != record["attempt"]
        or marker.get("sequence") != record.get("captured_sequence")
        or ("clean_worktree" in marker) != clean
    ):
        raise ValueError("review attempt was superseded; rerun the gate")
    if claimed and marker.get("claimed") is not True:
        raise ValueError("review attempt never claimed the artifact; rerun the gate")


def next_sequence(receipts):
    """Bump and return the receipt directory's transition counter (#573).

    Orders every capture against every blocking verdict. Wall time cannot: a
    clock stepped backward between a capture and a verdict would make the
    capture look newer and let its approval ship. Callers hold `attempt_lock`.
    The counter is a cache, never the only record: the next value always sits
    above every sequence the directory still holds (receipts, attempts, run
    snapshots, markers), so a deleted, corrupted or rolled-back counter can
    never sort a new verdict before an older capture.
    """
    path = receipts / "sequence.json"
    current = sequence_floor(receipts)
    if os.path.lexists(path):
        try:
            stored = read_json(path)["sequence"]
        except (OSError, ValueError, KeyError, TypeError):
            stored = None
        if type(stored) is int and stored > current:
            current = stored
    atomic_json(path, {"sequence": current + 1})
    return current + 1


def sequence_floor(receipts):
    """The highest sequence any evidence in the receipt directory carries.

    Evidence that cannot be parsed is skipped: `check` and `complete` read the
    same files strictly, so an unreadable receipt, attempt or snapshot can
    never ship anything, and it must not stop a verdict from being recorded.
    """
    candidates = [
        receipts / (lane + suffix) for lane in LANES for suffix in (".json", ".attempt.json")
    ]
    candidates += sorted(receipts.glob("run-*/snapshot.json"))
    directory = receipts / "blocks"
    if directory.is_dir() and not directory.is_symlink():
        candidates += sorted(directory.glob("*.json"))
    found = [0]
    for path in candidates:
        try:
            record = read_json(path)
        except (OSError, ValueError):
            continue
        if type(record) is not dict:
            continue
        for key in ("sequence", "captured_sequence"):
            value = record.get(key)
            if type(value) is int and value > 0:
                found.append(value)
    return max(found)


def artifact_identity(artifact):
    """The artifact a blocking verdict binds to: merge base, head, scope, patch (#573).

    Keyed by the merge base, not the base tip, for the same reason `check`
    compares merge bases (#680): a sibling advancing the tip must not give a
    later blocking verdict a different key from the approval it retires.
    """
    identity = {
        "merge_base": artifact["base"]["merge_base"],
        "head": artifact["head"],
        "scope": artifact["scope"],
        "patch_sha256": artifact["review_diff_sha256"],
    }
    return identity, digest(encoded(identity))


def legacy_artifact_identity(artifact):
    """The pre-merge-base marker identity, keyed by the base tip.

    Markers written before `artifact_identity` moved to the merge base live
    under this key. A lookup that computed only the new key would never see
    them, and a blocker recorded before the upgrade would stop retiring the
    approvals captured before it. `assert_not_blocked` checks both.
    """
    identity = {
        "base": artifact["base"]["commit"],
        "head": artifact["head"],
        "scope": artifact["scope"],
        "patch_sha256": artifact["review_diff_sha256"],
    }
    return identity, digest(encoded(identity))


def blocks_dir(receipts):
    directory = receipts / "blocks"
    if directory.is_symlink():
        raise ValueError("block marker directory must not be a symlink")
    if os.path.lexists(directory) and not directory.is_dir():
        raise ValueError("block marker store is not a directory")
    return directory


def assert_not_blocked(receipts, record):
    """Refuse a record captured before a blocking verdict on the same artifact.

    The marker, not the attempt-token race, carries the safety property: a
    verdict that blocks retires every review of that artifact captured before
    it, whichever lane recorded it and whether or not either claimed. Callers
    hold `attempt_lock`, so a marker written concurrently is either seen here
    or written after the decision. A receipt without a capture sequence
    predates #573 and is refused whenever a marker exists.

    Markers written before the merge-base key (`legacy_artifact_identity`)
    are keyed by whatever base TIP that gate saw, which may differ from this
    record's while naming the same merge base. They cannot be looked up by
    key, so every legacy marker in the store is read and applies when its
    head, scope and patch match and its base tip shares this record's merge
    base, or cannot be resolved at all (fail closed).
    """
    artifact = record["artifact"]
    identity, key = artifact_identity(artifact)
    directory = blocks_dir(receipts)
    path = directory / (key + ".json")
    # Only a genuine ENOENT is "no marker": os.path.lexists also answers False
    # when the lookup itself fails (an unsearchable store), which must refuse.
    try:
        os.lstat(path)
    except FileNotFoundError:
        pass
    else:
        refuse_if_blocked_before(path, identity, record)
    try:
        entries = sorted(directory.iterdir())
    except FileNotFoundError:
        return
    repo = Path(record["repository"])
    for entry in entries:
        if entry.suffix != ".json" or entry.is_symlink():
            continue
        marker = read_json(entry)
        legacy = marker.get("artifact") if type(marker) is dict else None
        if type(legacy) is not dict or "base" not in legacy or "merge_base" in legacy:
            continue
        if (
            legacy.get("head") != artifact["head"]
            or legacy.get("scope") != artifact["scope"]
            or legacy.get("patch_sha256") != artifact["review_diff_sha256"]
        ):
            continue
        base = legacy.get("base")
        if base != artifact["base"]["commit"]:
            try:
                shared = git(repo, "merge-base", str(base), artifact["head"]).decode().strip()
            except (subprocess.SubprocessError, OSError, ValueError, TypeError):
                shared = None
            if shared is not None and shared != artifact["base"]["merge_base"]:
                continue
        refuse_if_blocked_before(entry, legacy, record)


def refuse_if_blocked_before(path, identity, record):
    marker = read_json(path)
    if (
        type(marker) is not dict
        or type(marker.get("sequence")) is not int
        or marker["sequence"] < 1
        or marker.get("artifact") != identity
    ):
        raise ValueError("malformed block marker: " + str(path))
    captured = record.get("captured_sequence")
    if type(captured) is not int or captured <= marker["sequence"]:
        raise ValueError(
            "a blocking verdict on this artifact ("
            + str(marker.get("reviewer"))
            + ", "
            + str(marker.get("blocked_at"))
            + ") postdates this review's capture; rerun the gate"
        )


def block(args):
    """Record a blocking verdict against the snapshot's artifact (#573).

    Needs no live, claimed or unsuperseded attempt: a verdict is a fact about
    the artifact whatever happened to the token of the run that reached it.
    The snapshot's artifact is what was reviewed, so it is not re-captured.
    """
    record = read_json(Path(args.snapshot))
    lane = record["reviewer"]["name"]
    if lane not in LANES:
        raise ValueError("unknown review lane: " + str(lane))
    identity, key = artifact_identity(record["artifact"])
    _, _, receipts = layout(record["repository"])
    with attempt_lock(receipts):
        directory = blocks_dir(receipts)
        directory.mkdir(mode=0o700, exist_ok=True)
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError("block marker directory must be a real directory")
        os.chmod(directory, 0o700)
        atomic_json(
            directory / (key + ".json"),
            {
                "version": 1,
                "artifact": identity,
                "reviewer": lane,
                "sequence": next_sequence(receipts),
                "blocked_at": datetime.now(timezone.utc).isoformat(),
            },
        )
    print("Blocking verdict recorded for " + identity["head"])


RETAINED_REVIEWS = 30


def retain(args):
    """Keep a reviewer's output past the run that produced it (#788).

    The gate deletes its working files on every exit, and only an approval
    stores the output in a receipt, so a blocking, failed or cancelled review
    used to leave its findings nowhere but the terminal. The record is the
    output's exact bytes, named by the artifact, the lane and the output's own
    digest: retaining the same output twice is one file. It is evidence only.
    Nothing reads it to decide a verdict, clear a marker or accept a receipt.
    """
    record = read_json(Path(args.snapshot))
    lane = record["reviewer"]["name"]
    if lane not in LANES:
        raise ValueError("unknown review lane: " + str(lane))
    source = Path(args.output)
    if source.is_symlink() or not source.is_file():
        raise ValueError("missing or unsafe review output: " + str(source))
    data = source.read_bytes()
    if not data:
        raise ValueError("no review output to retain")
    _, key = artifact_identity(record["artifact"])
    _, _, receipts = layout(record["repository"])
    with attempt_lock(receipts):
        directory = receipts / "reviews"
        if directory.is_symlink() or (os.path.lexists(directory) and not directory.is_dir()):
            raise ValueError("retained review store must be a real directory")
        directory.mkdir(mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)
        path = directory / f"{key}.{lane}.{digest(data)[:16]}.json"
        fd, temporary = tempfile.mkstemp(prefix=".review-", dir=str(directory))
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        # Bounded: the newest records stay, this one included.
        kept = sorted(
            (item for item in directory.glob("*.json") if item.is_file() and not item.is_symlink()),
            key=lambda item: (item.stat().st_mtime_ns, item.name),
        )
        for item in kept[:-RETAINED_REVIEWS]:
            if item != path:
                item.unlink()
    print(path)


def validate_artifact(record):
    assert_attempt(record)
    artifact = record["artifact"]
    if is_clean_worktree(record):
        if artifact["scope"] != "committed":
            raise ValueError("clean_worktree requires committed scope")
        if "capture_repository" not in record or not isinstance(record["capture_repository"], str):
            raise ValueError("clean_worktree snapshot missing capture_repository")
        capture_launcher = record.get("capture_launcher")
        if capture_launcher is not None and not isinstance(capture_launcher, str):
            raise ValueError("malformed capture_launcher")
        source_repo, receipt_repo = verify_clean_worktree_pair(
            record["capture_repository"], record["repository"]
        )
        assert_worktree_clean(source_repo)
        reviewer = record.get("reviewer") if isinstance(record.get("reviewer"), dict) else {}
        assert_live_runtime_clean(
            receipt_repo,
            executable=reviewer.get("executable"),
            launcher=capture_launcher,
            reviewer=reviewer.get("name"),
        )
        current, patch = stable_capture(
            source_repo,
            artifact["base"]["ref"],
            "committed",
            artifact["base"]["commit"],
        )
        if oid(receipt_repo, "HEAD") != artifact["head"]:
            raise ValueError("receipt repository HEAD changed during review")
    else:
        if "capture_repository" in record:
            raise ValueError("unexpected capture_repository")
        if "capture_launcher" in record:
            raise ValueError("unexpected capture_launcher")
        current, patch = stable_capture(
            Path(record["repository"]),
            artifact["base"]["ref"],
            artifact["scope"],
            artifact["base"]["commit"],
        )
    if artifact != current:
        raise ValueError("repository changed during review or after approval; rerun the gate")
    assert_attempt(record)
    return patch


def build_clean_worktree_receipt(repo, record, patch):
    snap_artifact = record["artifact"]
    committed_artifact, committed_patch = stable_committed_objects(
        repo,
        snap_artifact["base"]["ref"],
        snap_artifact["base"]["commit"],
    )
    if committed_patch != patch:
        raise ValueError("clean worktree diff does not match committed objects")
    for key in (
        "head",
        "tree",
        "base",
        "scope",
        "diff_sha256",
        "review_diff_sha256",
        "changed_paths",
        "changed_modes",
    ):
        if snap_artifact[key] != committed_artifact[key]:
            raise ValueError("clean worktree artifact does not match committed objects")
    snap_links = snap_artifact["instruction_links"]
    comm_links = committed_artifact["instruction_links"]
    if set(snap_links) != set(comm_links):
        raise ValueError("clean worktree instruction links do not match committed objects")
    for link_path in snap_links:
        for field in ("target", "link_object", "link_sha256", "target_object", "target_mode"):
            if snap_links[link_path][field] != comm_links[link_path][field]:
                raise ValueError("clean worktree instruction links do not match committed objects")
    classification = classify_tier(committed_artifact, committed_patch, record["policy"])
    if classification != record["classification"]:
        raise ValueError("clean worktree classification mismatch")
    return {
        "version": record["version"],
        "attempt": record["attempt"],
        "captured_sequence": record["captured_sequence"],
        "repository": record["repository"],
        "git_directory": record["git_directory"],
        "clean_worktree": True,
        "artifact": committed_artifact,
        "policy": dict(record["policy"]),
        "classification": classification,
        "reviewer": dict(record["reviewer"]),
        "started_at": record["started_at"],
        "completion": dict(record["completion"]),
    }


def required_lane(tier, risk_paths, changed_paths, unclassifiable=False):
    """The weakest review lane that may ship this diff (ADR-0008).

    Tier 1 is satisfied by either lane's exemption receipt. A tier-2 diff that
    touches no risk surface is ordinary work and the Antigravity lane is
    enough — that is where the Codex quota saving comes from. Risk paths, an
    empty changed-path list, and a diff the classifier could not read all fail
    toward Codex, the same fail-toward-the-strongest rule the tier valve uses.
    Size alone never escalates the lane: a large ordinary diff is still ordinary.
    """
    if tier == 1:
        return "any"
    if unclassifiable or risk_paths or not changed_paths:
        return "codex"
    return "antigravity"


def classify_tier(artifact, patch, policy):
    max_lines = policy["tier1_max_lines"]
    if not isinstance(max_lines, str):
        raise ValueError("malformed tier-1 policy")
    # A receipt minted before the byte ceiling existed carries no tier1_max_bytes
    # at all. `.get` rather than `[...]` so that reads as "unclassifiable", the
    # fail-closed answer, instead of crashing or meaning "no limit" (#494).
    max_bytes = policy.get("tier1_max_bytes")
    paths = artifact["changed_paths"]
    risk_paths = [path for path in paths if risk(path)]

    def verdict(tier, reason, unclassifiable=False):
        return {
            "tier": tier,
            "reason": reason,
            "risk_paths": risk_paths,
            "required_lane": required_lane(tier, risk_paths, paths, unclassifiable),
        }

    if not re.fullmatch(r"[0-9]+", max_lines):
        return verdict(2, "full pass (captured tier-1 cap is not a number)", True)
    try:
        limit = int(max_lines)
    except ValueError:
        return verdict(2, "full pass (captured tier-1 cap is not supported)", True)
    if not isinstance(max_bytes, str) or not re.fullmatch(r"[0-9]+", max_bytes):
        return verdict(2, "full pass (captured tier-1 byte cap is not a number)", True)
    try:
        byte_limit = int(max_bytes)
    except ValueError:
        return verdict(2, "full pass (captured tier-1 byte cap is not supported)", True)
    lines = patch.count(b"\n")
    if lines > limit:
        return verdict(2, f"full pass (diff is {lines} lines > tier-1 cap {max_lines})")
    # The line ceiling alone is not a size limit: one 200,000-byte line is a
    # 1-line diff. The ceiling lives here rather than in a gate's prompt cap so
    # both lanes and `check` agree, and so such a diff is ESCALATED to an
    # ordinary review instead of being refused by whichever gate was asked
    # (#494).
    if len(patch) > byte_limit:
        return verdict(2, f"full pass (diff is {len(patch)} bytes > tier-1 cap {max_bytes})")
    if not paths:
        return verdict(2, "full pass (could not enumerate changed paths)")
    for path in paths:
        if not passive_modes(artifact["changed_modes"][path]) or not docsafe(path):
            return verdict(2, "full pass (active, risk, or unclassified path: " + path + ")")
    return verdict(1, f"docs-only diff, {lines} lines ≤ {max_lines}")


def exemption(outcome, artifact, patch, policy):
    classification = classify_tier(artifact, patch, policy)
    if outcome == "no-diff" and (
        patch.strip()
        or any(
            not excluded(path, artifact["changed_modes"][path])
            for path in artifact["changed_paths"]
        )
    ):
        raise ValueError("no-diff exemption has reviewable content")
    if outcome == "tier-1" and classification["tier"] != 1:
        raise ValueError("tier-1 exemption is not a small docs-only artifact")


def classify(args):
    snapshot = Path(args.snapshot)
    record = read_json(snapshot)
    patch = validate_artifact(record)
    if (snapshot.parent / "diff.patch").read_bytes() != patch:
        raise ValueError("review diff changed during review")
    print(json.dumps(classify_tier(record["artifact"], patch, record["policy"])))


def lane(args):
    """Print the classification for the current diff without minting anything.

    review-and-push.sh and any other dispatcher consults this to pick a gate;
    it writes no receipt, no attempt marker and no run directory, so calling it
    can never invalidate an approval that is already in hand.
    """
    repo = repo_root(args.repo)
    base = resolve_base(repo, args.base)
    scope = args.scope
    if getattr(args, "clean_worktree", False):
        if scope != "committed":
            raise ValueError("--clean-worktree requires --scope committed")
        artifact, patch = stable_committed_objects(repo, base)
    else:
        if scope == "auto":
            scope = (
                "committed"
                if git(repo, "rev-list", "--max-count=1", oid(repo, base) + "..HEAD").strip()
                else "uncommitted"
            )
        artifact, patch = stable_capture(repo, base, scope)
        if args.scope == "auto" and scope == "uncommitted" and not artifact["changed_paths"]:
            artifact, patch = stable_capture(repo, base, "committed")
    print(
        json.dumps(
            classify_tier(
                artifact,
                patch,
                {
                    "tier1_max_lines": args.tier1_max_lines,
                    "tier1_max_bytes": args.tier1_max_bytes,
                },
            )
        )
    )


def ledger_append(receipts, entry):
    """Append one measurement record to the append-only lane ledger.

    `check` never reads this file: it is telemetry for `stats`, so a forged
    ledger cannot approve a push and an unwritable one cannot block one. A
    failure is reported on stderr rather than discarding a receipt that is
    already recorded.
    """
    path = receipts / "ledger.jsonl"
    try:
        # O_NOFOLLOW: the ledger is never a symlink to somewhere else.
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(encoded(entry) + b"\n")
    except OSError as exc:
        print("review-receipt: lane ledger not recorded: " + str(exc), file=sys.stderr)


def stats(args):
    """Print lane x outcome counts over the recent ledger window."""
    if args.since_days < 0:
        raise ValueError("--since-days must not be negative")
    # Read-only like `lane`: resolve the directory, never create it.
    ledger = receipts_dir(repo_root(args.repo)) / "ledger.jsonl"
    if ledger.is_symlink():
        raise ValueError("lane ledger must not be a symlink")
    cutoff = datetime.now(timezone.utc) - timedelta(days=args.since_days)
    counts, degraded, unreadable, total = {}, 0, 0, 0
    if ledger.is_file():
        for line in ledger.read_text(errors="replace").splitlines():
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
                when = datetime.fromisoformat(entry["completed_at"])
                key = (str(entry["lane"]), str(entry["outcome"]))
                note = str(entry.get("note") or "")
            except (ValueError, KeyError, TypeError, AttributeError):
                unreadable += 1
                continue
            if when.tzinfo is None or when < cutoff:
                continue
            total += 1
            counts[key] = counts.get(key, 0) + 1
            if key[0] == "codex" and note.startswith(DEGRADED_NOTE_PREFIX):
                degraded += 1
    print(f"review lanes, last {args.since_days} day(s): {total} completed review(s)")
    for (name, outcome), count in sorted(counts.items()):
        print(f"  {name:<12} {outcome:<8} {count}")
    print(f"  antigravity degraded \u2192 codex: {degraded}")
    if unreadable:
        print(f"  unreadable ledger lines: {unreadable}")


def resolve_base(repo, requested=None):
    if not requested:
        try:
            requested = (
                git(repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
                .decode()
                .strip()
                .replace("refs/remotes/origin/", "", 1)
            )
        except subprocess.CalledProcessError as exc:
            if exc.returncode != 1:
                raise
            requested = "main"
    for ref in ("origin/" + requested, requested):
        try:
            oid(repo, ref)
            return ref
        except subprocess.CalledProcessError:
            continue
    raise ValueError("base could not be resolved: " + requested)


def _validate_materialize_path(rel_path):
    if not rel_path or "\0" in rel_path or rel_path.startswith("/"):
        raise ValueError("unsafe path in materialized tree: " + rel_path)
    parts = rel_path.split("/")
    for seg in parts:
        if seg in ("", ".", ".."):
            raise ValueError("unsafe path component in materialized tree: " + rel_path)
        lower = seg.lower().rstrip(". ")
        if lower in (".git", "git~1"):
            raise ValueError("refusing .git path in materialized tree: " + rel_path)
    return parts


def _read_blobs_batch(repo, object_ids):
    if not object_ids:
        return {}
    unique_ids = list(dict.fromkeys(object_ids))
    env = _git_env()
    payload = "".join(obj + "\n" for obj in unique_ids).encode()
    proc = subprocess.run(
        [
            "git",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-C",
            str(repo),
            "cat-file",
            "--batch",
        ],
        input=payload,
        capture_output=True,
        env=env,
        check=True,
    )
    out = proc.stdout
    pos = 0
    blobs = {}
    for expected in unique_ids:
        nl = out.find(b"\n", pos)
        if nl == -1:
            raise ValueError("truncated git cat-file --batch header for " + expected)
        header = out[pos:nl].decode()
        pos = nl + 1
        fields = header.split()
        if len(fields) != 3 or fields[0] != expected or fields[1] != "blob":
            raise ValueError("unexpected git cat-file --batch header: " + header)
        size = int(fields[2])
        end = pos + size
        if end + 1 > len(out) or out[end : end + 1] != b"\n":
            raise ValueError("truncated git cat-file --batch body for " + expected)
        blobs[expected] = out[pos:end]
        pos = end + 1
    if pos != len(out):
        raise ValueError("unexpected trailing bytes from git cat-file --batch")
    return blobs


def _ensure_parent_dir(root, dir_parts):
    cur = root
    for seg in dir_parts:
        cur = cur / seg
        try:
            st = cur.lstat()
        except FileNotFoundError:
            cur.mkdir(mode=0o755)
            continue
        if stat.S_ISLNK(st.st_mode):
            raise ValueError("cannot materialize through symlink ancestor: " + str(cur))
        if not stat.S_ISDIR(st.st_mode):
            raise ValueError("non-directory blocks materialized parent path: " + str(cur))


def _write_tree_blobs(repo, head, dest):
    entries = tree_files(repo, head)
    regular_items = []
    symlink_items = []
    object_ids = []
    for path in sorted(entries):
        mode, obj = entries[path]
        parts = _validate_materialize_path(path)
        if mode in ("100644", "100755"):
            regular_items.append((path, parts, mode, obj))
        elif mode == "120000":
            symlink_items.append((path, parts, obj))
        else:
            raise ValueError("unsupported tree entry mode in clean worktree: " + mode)
        object_ids.append(obj)
    blobs = _read_blobs_batch(repo, object_ids)
    _assert_tree_symlinks_confined(entries, lambda obj: blobs[obj])
    for path, parts, mode, obj in regular_items:
        _ensure_parent_dir(dest, parts[:-1])
        target = dest / path
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(target, flags, 0o644)
        try:
            data = blobs[obj]
            view = memoryview(data)
            written = 0
            while written < len(data):
                written += os.write(fd, view[written:])
        finally:
            os.close(fd)
        os.chmod(target, 0o755 if mode == "100755" else 0o644)
    for path, parts, obj in symlink_items:
        _ensure_parent_dir(dest, parts[:-1])
        target = dest / path
        os.symlink(os.fsdecode(blobs[obj]), target)
    _assert_disk_symlinks_confined(dest, [path for path, _, _ in symlink_items])


def materialize_clean_worktree(args):
    _reject_git_routing_overrides()
    source_repo, receipt_repo = verify_clean_worktree_pair(args.repo, args.receipt_repo)
    head = oid(source_repo, "HEAD")
    expected_head = oid(source_repo, args.head)
    if head != expected_head:
        raise ValueError("materialized HEAD mismatch")
    dotgit = source_repo / ".git"
    if dotgit.is_symlink() or not dotgit.is_file():
        raise ValueError("clean worktree requires a regular .git file")
    existing = sorted(entry.name for entry in source_repo.iterdir())
    if existing != [".git"]:
        raise ValueError("clean worktree must contain only .git before materialization")
    wt_gitdir = worktree_gitdir(source_repo)
    store = os.path.realpath(os.path.join(common_dir(source_repo), "worktrees"))
    receipt_gitdir = os.path.realpath(git_dir(receipt_repo))
    if (
        wt_gitdir is None
        or not _same_existing_path(os.path.dirname(wt_gitdir), store)
        or _same_existing_path(wt_gitdir, receipt_gitdir)
    ):
        raise ValueError("clean worktree metadata path is not isolated from receipt repository")
    wt_index = os.path.join(wt_gitdir, "index")
    if os.path.islink(wt_index):
        raise ValueError("clean worktree index must not be a symlink")
    git(
        source_repo,
        "read-tree",
        head,
        extra_env={
            "GIT_DIR": wt_gitdir,
            "GIT_WORK_TREE": str(source_repo),
            "GIT_INDEX_FILE": wt_index,
        },
    )
    _write_tree_blobs(source_repo, head, source_repo)


def capture_attempt(args):
    """Open this lane's attempt and snapshot the artifact; return the run directory.

    Own-lane only, like the `invalidate` subcommand: the other lane's receipt and
    attempt are untouched until this run CLAIMS the artifact (#499), so a gate
    that degrades after capturing costs no other lane's approval.
    """
    use_receipt_repo = getattr(args, "receipt_repo", None) is not None
    base_commit = None
    if use_receipt_repo:
        _reject_git_routing_overrides()
        if args.scope != "committed":
            raise ValueError("--receipt-repo requires --scope committed")
        source_repo, receipt_repo = verify_clean_worktree_pair(args.repo, args.receipt_repo)
        assert_worktree_clean(source_repo)
        launcher = getattr(args, "launcher", None)
        if (
            launcher
            and not os.path.isabs(launcher)
            and ("/" in launcher or (os.sep != "/" and os.sep in launcher))
        ):
            launcher = os.path.join(os.path.realpath(os.getcwd()), launcher)
        assert_live_runtime_clean(
            receipt_repo, executable=args.executable, launcher=launcher, reviewer=args.reviewer
        )
        receipt_repo, directory, receipts = layout(receipt_repo)
        base_ref = resolve_base(receipt_repo, args.base)
        base_commit = oid(receipt_repo, base_ref)
        args.base = base_ref
    else:
        source_repo, directory, receipts = layout(args.repo)
        receipt_repo = source_repo
    with attempt_lock(receipts):
        # Taken in the same transition as the attempt: a verdict recorded after
        # this point outranks this capture (#573).
        sequence = next_sequence(receipts)
        attempt = invalidate(receipts, args.reviewer, sequence, clean_worktree=use_receipt_repo)
    scope = args.scope
    if scope == "auto":
        scope = (
            "committed"
            if git(
                source_repo, "rev-list", "--max-count=1", oid(source_repo, args.base) + "..HEAD"
            ).strip()
            else "uncommitted"
        )
    artifact, patch = stable_capture(source_repo, args.base, scope, base_commit=base_commit)
    if args.scope == "auto" and scope == "uncommitted" and not artifact["changed_paths"]:
        artifact, patch = stable_capture(source_repo, args.base, "committed")
    if use_receipt_repo:
        assert_worktree_clean(source_repo)
        assert_live_runtime_clean(
            receipt_repo, executable=args.executable, launcher=launcher, reviewer=args.reviewer
        )
        if oid(receipt_repo, "HEAD") != artifact["head"]:
            raise ValueError("receipt repository HEAD changed during snapshot")
    run = Path(tempfile.mkdtemp(prefix="run-", dir=str(receipts)))
    (run / "diff.patch").write_bytes(patch)
    os.chmod(run / "diff.patch", 0o600)
    policy = {
        "tier1_max_lines": args.tier1_max_lines,
        "tier1_max_bytes": args.tier1_max_bytes,
    }
    record = {
        # Version 2 adds "classification": check recomputes it and refuses a
        # receipt whose lane ranks below what the diff requires, so a version-1
        # receipt (which carries no lane requirement) can no longer ship.
        "version": 2,
        "attempt": attempt,
        "captured_sequence": sequence,
        "repository": str(receipt_repo),
        "git_directory": str(directory),
        "artifact": artifact,
        "policy": policy,
        "classification": classify_tier(artifact, patch, policy),
        "reviewer": {"name": args.reviewer, "executable": args.executable or None},
        "started_at": datetime.now(timezone.utc).isoformat(),
    }
    if use_receipt_repo:
        record["capture_repository"] = str(source_repo)
        if launcher:
            record["capture_launcher"] = launcher
        record["clean_worktree"] = True
    atomic_json(run / "snapshot.json", record)
    return run


def claim_snapshot(snapshot):
    record = read_json(Path(snapshot))
    _, _, receipts = layout(record["repository"])
    with attempt_lock(receipts):
        supersede(receipts, record)


def capture_command(args):
    print(capture_attempt(args))


def claim_command(args):
    claim_snapshot(args.snapshot)


def begin(args):
    # Backward-compatible capture + claim, for callers that decide nothing between
    # the two. Both gates call `capture` and `claim` separately (#499).
    run = capture_attempt(args)
    claim_snapshot(run / "snapshot.json")
    print(run)


def complete(args):
    snapshot = Path(args.snapshot)
    record = read_json(snapshot)
    patch = validate_artifact(record)
    if (snapshot.parent / "diff.patch").read_bytes() != patch:
        raise ValueError("review diff changed during review")
    exemption(args.outcome, record["artifact"], patch, record["policy"])
    output = Path(args.output).read_text() if args.output else ""
    if args.outcome == "passed" and not output.strip():
        raise ValueError("completed review must have output")
    clean = is_clean_worktree(record)
    record["reviewer"].update(
        requested_model=args.requested_model,
        observed_model=args.observed_model,
        model_evidence=args.model_evidence,
    )
    record["completion"] = {
        "status": "completed",
        "outcome": args.outcome,
        "completed_at": datetime.now(timezone.utc).isoformat(),
        "output_sha256": digest(output.encode()),
        "output": output,
    }
    repo, directory, receipts = layout(record["repository"])
    if str(directory) != record["git_directory"]:
        raise ValueError("Git directory changed during review")
    # The authoritative attempt check and the write it authorizes are one
    # transition: a `supersede` interleaving between them would otherwise file a
    # receipt the newer review had already retired. The earlier checks above are
    # fail-fast; this one decides. A receipt also requires that this attempt
    # CLAIMED the artifact (#499): an unclaimed attempt never retired the other
    # lane, so recording beside it would leave two lanes' evidence standing.
    with attempt_lock(receipts):
        patch = validate_artifact(record)
        assert_attempt(record, claimed=True)
        assert_not_blocked(receipts, record)
        persisted = build_clean_worktree_receipt(repo, record, patch) if clean else record
        atomic_json(receipts / (persisted["reviewer"]["name"] + ".json"), persisted)
    # The ledger records what the artifact actually is, not what the snapshot
    # claims: a tampered stored classification stays in the receipt for `check`
    # to reject rather than being laundered into the measurement.
    classification = classify_tier(persisted["artifact"], patch, persisted["policy"])
    ledger_append(
        receipts,
        {
            "completed_at": persisted["completion"]["completed_at"],
            "lane": persisted["reviewer"]["name"],
            "outcome": args.outcome,
            "tier": classification["tier"],
            "required_lane": classification["required_lane"],
            "head": persisted["artifact"]["head"],
            "note": args.note or "",
        },
    )
    print("Review receipt recorded for " + persisted["artifact"]["head"])


def check(args):
    repo, directory, receipts = layout(args.repo)
    head = oid(repo, args.head)
    if head != oid(repo, "HEAD") or args.head != head:
        raise ValueError("outgoing commit is not the reviewed worktree HEAD")
    expected_base = oid(repo, resolve_base(repo, args.base))
    expected_merge = git(repo, "merge-base", expected_base, head).decode().strip()
    errors = []
    for lane_name in (args.reviewer,) if args.reviewer else LANES:
        try:
            record = read_json(receipts / (lane_name + ".json"))
            if "capture_repository" in record:
                raise ValueError("receipt must not carry capture_repository")
            if "capture_launcher" in record:
                raise ValueError("receipt must not carry capture_launcher")
            clean = is_clean_worktree(record)
            if (
                type(record["version"]) is not int
                or record["version"] != 2
                or record["repository"] != str(repo)
                or record["git_directory"] != str(directory)
                or record["reviewer"]["name"] != lane_name
                or record["artifact"]["scope"] != "committed"
                or record["artifact"]["head"] != head
                or record["completion"]["status"] != "completed"
                or record["completion"]["outcome"] not in ("passed", "tier-1", "no-diff")
            ):
                raise ValueError("receipt identity, scope, or completion does not match")
            reviewer = record["reviewer"]
            for field in ("requested_model", "observed_model", "model_evidence", "executable"):
                if reviewer[field] is not None and not isinstance(reviewer[field], str):
                    raise ValueError("malformed reviewer identity")
            # The reviewed diff is merge_base..HEAD, so that is what must still
            # match. The base TIP may have moved on (a sibling merged, #680);
            # a receipt for another merge base — a narrower --base, or a branch
            # the base has since absorbed — still refuses.
            if expected_merge != record["artifact"]["base"]["merge_base"]:
                raise ValueError("receipt does not cover the expected base")
            base_ref = record["artifact"]["base"]["ref"]
            if not isinstance(base_ref, str) or not base_ref:
                raise ValueError("malformed receipt base ref")
            completion = record["completion"]
            started = datetime.fromisoformat(record["started_at"])
            completed = datetime.fromisoformat(completion["completed_at"])
            # Wall time is audit metadata; attempt and artifact checks establish
            # freshness even when the system clock steps backward during review.
            if started.tzinfo is None or completed.tzinfo is None:
                raise ValueError("malformed completion timestamps")
            if digest(completion["output"].encode()) != completion["output_sha256"]:
                raise ValueError("malformed review output")
            if completion["outcome"] == "passed" and not completion["output"].strip():
                raise ValueError("completed review output is empty")
            if clean:
                assert_attempt(record)
                current, patch = stable_committed_objects(
                    repo,
                    base_ref,
                    record["artifact"]["base"]["commit"],
                )
                if record["artifact"] != current:
                    raise ValueError(
                        "repository changed during review or after approval; rerun the gate"
                    )
                assert_attempt(record)
            else:
                patch = validate_artifact(record)
            exemption(completion["outcome"], record["artifact"], patch, record["policy"])
            # Recompute on the re-captured patch: the stored classification is
            # receipt content, so only the recomputation is authoritative, and a
            # mismatch means the receipt was edited after the gate wrote it.
            current = classify_tier(record["artifact"], patch, record["policy"])
            if record["classification"] != current:
                raise ValueError("receipt classification does not match the reviewed artifact")
            required = current["required_lane"]
            if LANE_RANK[lane_name] < LANE_RANK[required]:
                raise ValueError(
                    "receipt lane below required lane: "
                    + lane_name
                    + " < "
                    + required
                    + " ("
                    + current["reason"]
                    + ")"
                )
            # The deciding assertion, synchronized with `claim` (#533). Everything
            # above runs lock-free so a long capture never blocks a gate, which
            # left a window: a claim landing after validate_artifact()'s last token
            # read retired this receipt, and the checker still said yes. Under the
            # lock the attempt is still live and the receipt still the one
            # validated, so a claim either precedes this (and refuses it) or
            # follows the decision.
            with attempt_lock(receipts):
                assert_attempt(record)
                if read_json(receipts / (lane_name + ".json")) != record:
                    raise ValueError("receipt changed during check; rerun the gate")
                assert_not_blocked(receipts, record)
            print(
                "Valid "
                + lane_name
                + " review receipt for "
                + head
                + " (required lane: "
                + required
                + ")"
            )
            return
        except (
            OSError,
            ValueError,
            KeyError,
            TypeError,
            AttributeError,
            subprocess.SubprocessError,
        ) as exc:
            errors.append(lane_name + ": " + str(exc))
    raise ValueError("no valid committed review receipt; " + "; ".join(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("capture", "begin", "invalidate", "check"):
        sub = commands.add_parser(name)
        sub.add_argument("--repo", default=".")
        sub.add_argument("--reviewer", choices=LANES, required=name != "check")
        if name != "invalidate":
            sub.add_argument("--base")
        if name in ("capture", "begin"):
            sub.add_argument("--scope", choices=("auto", "committed", "uncommitted"), required=True)
            sub.add_argument("--receipt-repo")
            sub.add_argument("--executable")
            sub.add_argument("--launcher")
            sub.add_argument("--tier1-max-lines", default=TIER1_MAX_LINES)
            sub.add_argument("--tier1-max-bytes", default=TIER1_MAX_BYTES)
        if name == "check":
            sub.add_argument("--head", required=True)
    for name in ("claim", "verify", "classify", "block"):
        sub = commands.add_parser(name)
        sub.add_argument("--snapshot", required=True)
    sub = commands.add_parser("retain")
    sub.add_argument("--snapshot", required=True)
    sub.add_argument("--output", required=True)
    sub = commands.add_parser("lane")
    sub.add_argument("--repo", default=".")
    sub.add_argument("--base")
    sub.add_argument("--scope", choices=("auto", "committed", "uncommitted"), default="committed")
    sub.add_argument("--clean-worktree", action="store_true")
    sub.add_argument("--tier1-max-lines", default=TIER1_MAX_LINES)
    sub.add_argument("--tier1-max-bytes", default=TIER1_MAX_BYTES)
    sub = commands.add_parser("stats")
    sub.add_argument("--repo", default=".")
    sub.add_argument("--since-days", type=int, default=7)
    sub = commands.add_parser("materialize")
    sub.add_argument("--repo", required=True)
    sub.add_argument("--receipt-repo", required=True)
    sub.add_argument("--head", required=True)
    sub = commands.add_parser("complete")
    sub.add_argument("--snapshot", required=True)
    sub.add_argument("--outcome", choices=("passed", "tier-1", "no-diff"), required=True)
    sub.add_argument("--output")
    sub.add_argument("--note")
    sub.add_argument("--requested-model")
    sub.add_argument("--observed-model")
    sub.add_argument("--model-evidence")
    args = parser.parse_args()
    try:
        if args.command == "invalidate":
            _, _, receipts = layout(args.repo)
            # Locked at the call site, never inside invalidate(): supersede()
            # already holds the lock when it calls it.
            with attempt_lock(receipts):
                invalidate(receipts, args.reviewer)
        elif args.command == "materialize":
            materialize_clean_worktree(args)
        elif args.command == "verify":
            validate_artifact(read_json(Path(args.snapshot)))
        elif args.command in ("capture", "claim"):
            # Suffixed: `capture` already names the artifact-capture function.
            globals()[args.command + "_command"](args)
        else:
            globals()[args.command](args)
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        subprocess.SubprocessError,
    ) as exc:
        print("review-receipt: " + str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
