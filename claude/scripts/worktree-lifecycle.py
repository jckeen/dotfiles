#!/usr/bin/env python3
"""Release completed tasks for explicit, evidence-backed worktree retirement.

Inventory and retirement preview are read-only. Release is an owner's assertion
that its session is finished; the timer never releases or removes worktrees.
Applied retirement detaches the quarantined worktree's own metadata HEAD as its
last step, after the recovery bundle and record are written, so the record still
names the branch while the merged branch ref becomes deletable; --delete-branch
deletes it only when it still names the verified merged PR head, restores it if
a worktree attached it during the delete, and removes its branch.<name> config.

Accepted limitation (#522): the post-delete holder re-check and create-only
restore catch every attach that completed before the re-check. An attach that
resolved the branch before the delete but writes its HEAD after the re-check
can still land on a missing branch. Git offers no lock that orders `worktree
add` against a ref delete, so this is the same window `git branch -D` has.

Expiry (#562) reports retired archive entries by default. --apply removes the
quarantined checkout and its Git worktree registration once the entry was
retired longer ago than --older-than, and only while the checkout is still
clean at the recorded head and its Git metadata holds nothing retirement did
not archive. It never deletes the recovery files (repository.bundle,
worktree-metadata.tar, recovery.json): they stay in the archive entry
permanently as the recovery path.
"""

import argparse
from datetime import datetime, timedelta, timezone
import errno
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import tempfile

MARKER = "worktree-release.json"
# Retirement locks each quarantine with this reason plus its archive path, and
# expiry removes only a registration whose lock still names its own archive.
QUARANTINE_LOCK = "retained quarantine: "
# The recovery files applied retirement writes beside the quarantined
# `worktree`. Expiry never deletes, rewrites or moves any of them (#562).
ARCHIVE_FILES = ("recovery.json", "repository.bundle", "worktree-metadata.tar")
# Where expiry moves a quarantine for its final inspection before removal.
STAGING = "worktree-expiring"
# Repository-local overrides reported by `git rev-parse --local-env-vars`,
# plus namespace and attribute-source routing. GIT_NO_REPLACE_OBJECTS is safe
# because run() explicitly forces it; configuration overrides are matched as
# a family below, including indexed runtime key/value pairs.
GIT_EVIDENCE_ENV = {
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_OBJECT_DIRECTORY",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_NAMESPACE",
    "GIT_ATTR_SOURCE",
}


def run(argv, cwd=None):
    result = subprocess.run(
        argv,
        cwd=cwd,
        capture_output=True,
        timeout=30,
        env=dict(
            os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_REPLACE_OBJECTS="1", GIT_TERMINAL_PROMPT="0"
        ),
    )
    if result.returncode:
        raise ValueError(f"{argv[0]} could not verify evidence (exit {result.returncode})")
    return result.stdout


def git(repo, *args):
    # -C does not override inherited index/repository routing. Refuse before
    # any Git invocation so direct API callers and CLI actions inspect the
    # selected checkout's actual evidence. Keep SSH and credential transport.
    overrides = sorted(
        name
        for name in os.environ
        if name in GIT_EVIDENCE_ENV or name == "GIT_CONFIG" or name.startswith("GIT_CONFIG_")
    )
    if overrides:
        raise ValueError(
            "Git environment overrides prevent verifying the selected worktree; unset: "
            + ", ".join(overrides)
        )
    return run(["git", "-c", "core.fsmonitor=false", "-C", str(repo), *args])


def text(data):
    return os.fsdecode(data.removesuffix(b"\n"))


def open_regular(path):
    """Open a regular file for reading, never blocking on or following a special one.

    Expiry reads archive entries and worktree metadata from the hygiene timer's
    report run, which no subprocess timeout covers: a FIFO in place of any of
    these files would otherwise hang it. A missing file raises
    FileNotFoundError, as a plain open does.
    """
    if not stat.S_ISREG(Path(path).lstat().st_mode):
        raise ValueError(f"not a regular file, retain for inspection: {path}")
    stream = os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb")
    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
        stream.close()
        raise ValueError(f"not a regular file, retain for inspection: {path}")
    return stream


def read_regular(path):
    with open_regular(path) as stream:
        return stream.read()


def worktrees(repo):
    items = []
    for block in git(repo, "worktree", "list", "--porcelain", "-z").split(b"\0\0"):
        fields = {}
        for line in block.split(b"\0"):
            key, _, value = line.partition(b" ")
            if key:
                fields[os.fsdecode(key)] = os.fsdecode(value)
        if "worktree" in fields:
            fields["path"] = fields.pop("worktree")
            items.append(fields)
    return items


def selected(repo, path):
    path = path.resolve(strict=True)
    item = next((entry for entry in worktrees(repo) if Path(entry["path"]) == path), None)
    if item is None:
        raise ValueError("not a registered worktree in this repository")
    admin = Path(text(git(path, "rev-parse", "--absolute-git-dir")))
    common = Path(text(git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")))
    if admin == common:
        raise ValueError("the primary checkout must be retained")
    if "locked" in item or "prunable" in item:
        raise ValueError("locked or missing worktree must be retained")
    return item, admin


def marker(admin):
    path = admin / MARKER
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("release record is not a private regular file")
    data = json.loads(read_regular(path))
    if (
        not isinstance(data, dict)
        or data.get("schema") != 1
        or not isinstance(data.get("owner"), str)
        or not data["owner"]
    ):
        raise ValueError("invalid release record")
    return data


def clean(path):
    entries = git(path, "ls-files", "-v", "-z").split(b"\0")
    if any(entry and (entry[:1].islower() or entry[:1] == b"S") for entry in entries):
        raise ValueError("index flags hide worktree contents; retain for separate inspection")
    staged = {}
    for row in git(path, "ls-files", "--stage", "-z").split(b"\0"):
        if not row:
            continue
        metadata, name = row.split(b"\t", 1)
        mode, oid, stage = metadata.split()
        if stage != b"0":
            raise ValueError("unmerged index must be retained")
        staged[os.fsdecode(name)] = (mode, oid)
    committed = {}
    for row in git(path, "ls-tree", "-r", "-z", "HEAD").split(b"\0"):
        if not row:
            continue
        metadata, name = row.split(b"\t", 1)
        mode, _, oid = metadata.split()
        committed[os.fsdecode(name)] = (mode, oid)
    if staged != committed:
        raise ValueError("staged changes must be retained")
    if any(mode == b"160000" for mode, _ in staged.values()):
        raise ValueError("worktrees with submodules require separate retirement")
    # Git status applies clean/encoding filters and omits sockets, FIFOs and
    # empty directories. Inspect the actual filesystem and raw blob identities;
    # local bytes absent from the recovery bundle must never be discarded.
    algorithm = text(git(path, "rev-parse", "--show-object-format"))
    if algorithm not in ("sha1", "sha256"):
        raise ValueError("unsupported Git object format; retain worktree")
    parents = {
        str(parent) for name in staged for parent in Path(name).parents if str(parent) != "."
    }
    seen = set()

    def scan_error(error):
        raise error

    for directory, dirs, files in os.walk(path, followlinks=False, onerror=scan_error):
        for name in dirs + files:
            file = Path(directory) / name
            relative = str(file.relative_to(path))
            info = file.lstat()
            if relative == ".git" and stat.S_ISREG(info.st_mode):
                continue
            if stat.S_ISDIR(info.st_mode):
                if relative not in parents:
                    raise ValueError("untracked or empty directory must be retained: " + relative)
                continue
            expected = staged.get(relative)
            if expected is None:
                raise ValueError("untracked, ignored or special file must be retained: " + relative)
            digest = hashlib.new(algorithm)
            if stat.S_ISREG(info.st_mode):
                mode = b"100755" if info.st_mode & stat.S_IXUSR else b"100644"
                with os.fdopen(
                    os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb"
                ) as stream:
                    opened = os.fstat(stream.fileno())
                    if not stat.S_ISREG(opened.st_mode):
                        raise ValueError("file changed during inspection; retain worktree")
                    digest.update(f"blob {opened.st_size}\0".encode())
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
            elif stat.S_ISLNK(info.st_mode):
                mode = b"120000"
                content = os.fsencode(os.readlink(file))
                digest.update(f"blob {len(content)}\0".encode() + content)
            else:
                raise ValueError("special file must be retained: " + relative)
            if (mode, digest.hexdigest().encode()) != expected:
                raise ValueError("raw local content or mode must be retained: " + relative)
            seen.add(relative)
    if seen != staged.keys():
        raise ValueError("missing tracked files must be retained")
    # Keep transformed checkouts in place for separate owner inspection.
    # Inspect attributes without executing a configured driver.
    if staged:
        attributes = git(path, "check-attr", "-z", "filter", "--", *staged).split(b"\0")
        if any(value not in (b"unspecified", b"unset") for value in attributes[2::3]):
            raise ValueError("active content filters require separate retirement")


def check_admin_metadata(admin):
    # Tar silently omits sockets, and an archived special-file node cannot
    # preserve a live endpoint. Never open these targets or follow symlinks.
    def scan_error(error):
        raise error

    for directory, dirs, files in os.walk(admin, followlinks=False, onerror=scan_error):
        for name in dirs + files:
            entry = Path(directory) / name
            mode = entry.lstat().st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
                raise ValueError(
                    "special Git metadata must be retained: " + str(entry.relative_to(admin))
                )


def archived_metadata_matches(admin, archive):
    """Compare saved metadata with the final tree without following symlinks."""

    def scan_error(error):
        raise error

    paths = {"worktree-metadata": admin}
    for directory, dirs, files in os.walk(admin, followlinks=False, onerror=scan_error):
        for name in dirs + files:
            path = Path(directory) / name
            paths["worktree-metadata/" + path.relative_to(admin).as_posix()] = path
    with tarfile.open(archive) as saved:
        members = saved.getmembers()
        if {member.name for member in members} != paths.keys():
            return False
        for member in members:
            path = paths[member.name]
            info = path.lstat()
            if stat.S_IMODE(info.st_mode) != member.mode:
                return False
            if member.isdir():
                if not stat.S_ISDIR(info.st_mode):
                    return False
            elif member.issym():
                if not stat.S_ISLNK(info.st_mode) or os.fsencode(os.readlink(path)) != os.fsencode(
                    member.linkname
                ):
                    return False
            elif member.isfile() or member.islnk():
                if not stat.S_ISREG(info.st_mode):
                    return False
                # Hardlink entries resolve within the archive. The current
                # path must still be a regular file, opened without following
                # a replacement symlink or blocking on a replacement FIFO.
                with os.fdopen(
                    os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb"
                ) as current:
                    opened = os.fstat(current.fileno())
                    if (
                        not stat.S_ISREG(opened.st_mode)
                        or stat.S_IMODE(opened.st_mode) != member.mode
                    ):
                        return False
                    with saved.extractfile(member) as original:
                        while True:
                            chunk = original.read(1024 * 1024)
                            if current.read(1024 * 1024) != chunk:
                                return False
                            if not chunk:
                                break
            else:
                return False
    return True


def thread_exited(entry):
    """A dead task establishes only that thread's exit, never its group's."""
    try:
        status = (entry / "status").read_bytes()
    except FileNotFoundError:
        try:
            entry.stat()
        except FileNotFoundError:
            return True
        raise
    state = next(
        (line.split()[1:2] for line in status.split(b"\n") if line.startswith(b"State:")), []
    )
    if not state:
        raise OSError("process state unavailable")
    return state[0] in (b"Z", b"X")


def process_path_within(target, path):
    # Inspect link text only. Opening pipe/socket/anon-inode targets can block,
    # and resolving them as paths would invent filesystem evidence.
    if not target.startswith("/"):
        return False
    for candidate in (target, target.removesuffix(" (deleted)")):
        reference = Path(candidate)
        if reference == path or path in reference.parents:
            return True
    return False


def inspect_thread(path, entry):
    try:
        if thread_exited(entry):
            return
        identity = f"{entry.parent.parent.name} thread {entry.name}"
        for name in ("cwd", "root", "exe"):
            if process_path_within(os.readlink(entry / name), path):
                raise ValueError(f"active process {identity} uses this worktree ({name})")
        # Keep enumeration open: scanning our own descriptors otherwise
        # lists a temporary directory FD that is closed before readlink.
        with os.scandir(entry / "fd") as descriptors:
            for descriptor in descriptors:
                if process_path_within(os.readlink(descriptor.path), path):
                    raise ValueError(
                        f"active process {identity} uses this worktree (open descriptor)"
                    )
        # /proc maps escapes pathname newlines as literal \012. Compare
        # the encoded worktree path too, without decoding ambiguous names.
        mapped_path = Path(str(path).replace("\n", r"\012"))
        observed_mapping = False
        with (entry / "maps").open("rb") as mappings:
            for line in mappings:
                fields = line.removesuffix(b"\n").split(maxsplit=5)
                if len(fields) < 5:
                    raise OSError("invalid process mapping evidence")
                observed_mapping = True
                if len(fields) == 6 and process_path_within(os.fsdecode(fields[5]), mapped_path):
                    raise ValueError(
                        f"active process {identity} uses this worktree (memory mapping)"
                    )
        if not observed_mapping:
            raise OSError("process mapping evidence unavailable")
    except FileNotFoundError:
        if not thread_exited(entry):
            raise


def process_identity(entry):
    """The command, parent pid and single owning uid recorded for a process.

    Both files stay world-readable after a process clears its dumpable flag,
    so identity remains verifiable for one whose references are denied below.
    """
    comm = os.fsdecode((entry / "comm").read_bytes().removesuffix(b"\n"))
    fields = {}
    for line in (entry / "status").read_bytes().split(b"\n"):
        key, _, value = line.partition(b":")
        fields[os.fsdecode(key)] = value.split()
    owners = {int(value) for value in fields["Uid"]}
    if len(owners) != 1 or len(fields["PPid"]) != 1:
        raise ValueError("ambiguous process identity")
    return comm, int(fields["PPid"][0]), owners.pop()


def readlink_denied(link):
    """True only when an existing link refuses this user with EACCES."""
    try:
        os.readlink(link)
    except OSError as error:
        return error.errno == errno.EACCES
    return False


def evidence_denied(thread):
    """True when every filesystem reference of a thread refuses us with EACCES.

    A readable reference is partial evidence to inspect instead, and another
    errno describes a different failure; both disqualify the exemption below.
    """
    if not all(readlink_denied(thread / name) for name in ("cwd", "root", "exe")):
        return False
    try:
        with (thread / "maps").open("rb"):
            return False
    except OSError as error:
        if error.errno != errno.EACCES:
            return False
    # A session manager's own descriptor table can be listable while every
    # target refuses readlink; its (sd-pam) helper refuses even enumeration.
    try:
        with os.scandir(thread / "fd") as descriptors:
            targets = [Path(descriptor.path) for descriptor in descriptors]
    except OSError as error:
        return error.errno == errno.EACCES
    return all(readlink_denied(target) for target in targets)


def session_manager_pid(uid):
    """The pid the system manager reports for this user's session manager.

    Nothing in /proc establishes this: an orphan is reparented to pid 1 and
    any process can rename its own `comm`, so a same-user look-alike could
    otherwise present the whole signature below. Ask the manager that started
    the session instead; the user cannot influence its answer.
    """
    pid = int(
        text(run(["systemctl", "show", "--property=MainPID", "--value", f"user@{uid}.service"]))
    )
    if pid <= 0:
        raise ValueError("no systemd session manager for this user")
    return pid


def process_session(entry):
    """The process group and session of a pid, from world-readable stat."""
    # comm sits in parentheses and may itself contain spaces or parentheses.
    fields = os.fsdecode((entry / "stat").read_bytes()).rpartition(")")[2].split()
    return int(fields[2]), int(fields[3])


def denied_session_process(proc_root, entry, uid, manager):
    """Identify a systemd user-session process no scan can read, or None.

    Every systemd user session contributes two same-uid processes whose
    references are unreadable: `systemd --user` and its `(sd-pam)` helper
    change credentials at exec, which clears dumpable and makes cwd, root,
    exe, descriptor targets and maps refuse this user with EACCES. Retaining
    on uninspectable evidence therefore retains every worktree on every
    systemd host, which is what `--trust-process-manager` exempts -- and only
    for exactly that pair. The manager is the pid the system manager names,
    not whatever claims the name. The helper must be its child and share its
    session, which a service cannot: the manager starts each one in a session
    of its own, so only a process it forked without exec is in there with it.

    What the operator asserts, rather than this scan proving it, is the
    descriptor residual: a user unit can pass a worktree descriptor to the
    manager's file-descriptor store (`FDSTORE=1`) and close its own copy,
    leaving the manager the last holder, and readlink on those targets is
    exactly what EACCES denies. The structural argument covers the rest --
    a session manager was not started from a checkout this user created later
    -- and any readable reference is evidence rather than an exemption, so a
    look-alike that leaks one inspectable reference still retains the
    worktree. Every exemption is recorded in the release record.
    """
    try:
        comm, ppid, owner = process_identity(entry)
        if owner != uid:
            return None
        if int(entry.name) == manager:
            if comm != "systemd" or ppid != 1:
                return None
        else:
            if comm != "(sd-pam)" or ppid != manager:
                return None
            if process_session(entry) != process_session(proc_root / str(manager)):
                return None
        threads = [thread for thread in (entry / "task").iterdir() if thread.name.isdigit()]
        if not threads or not all(evidence_denied(thread) for thread in threads):
            return None
    except (OSError, ValueError, KeyError, IndexError):
        # Unreadable or malformed identity is never an exemption; the caller
        # inspects the process and reports what it could not establish.
        return None
    return dict(pid=int(entry.name), comm=comm, ppid=ppid)


def active_processes(path, proc_root=Path("/proc"), trust_process_manager=False):
    """Retain visible thread references; missing live-task evidence is unsafe.

    Returns the systemd user-session processes the operator's assertion
    exempted, so callers can record the identities no scan could read.
    """
    if not proc_root.is_dir():
        raise ValueError("automatic process inspection requires /proc; retain on this platform")
    uid = os.getuid()
    # Resolve the one pid an exemption can apply to before scanning. A host
    # without a systemd user session simply exempts nothing.
    try:
        manager = session_manager_pid(uid)
    except (OSError, ValueError, subprocess.SubprocessError):
        manager = None
    exempt = []
    for entry in proc_root.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != uid:
                continue
            session = None
            if manager is not None:
                session = denied_session_process(proc_root, entry, uid, manager)
            if session is not None:
                if not trust_process_manager:
                    raise ValueError(
                        "cannot inspect this user's systemd session process "
                        f"{session['pid']} ({session['comm']}); retain worktree or assert "
                        "--trust-process-manager"
                    )
                exempt.append(session)
                continue
            # The leader may be a zombie while workers still hold references.
            # Threads can also have private cwd/root and descriptor tables.
            tasks = entry / "task"
            threads = {thread.name for thread in tasks.iterdir() if thread.name.isdigit()}
            if not threads:
                raise OSError("process thread evidence unavailable")
            for name in sorted(threads):
                inspect_thread(path, tasks / name)
            if threads != {thread.name for thread in tasks.iterdir() if thread.name.isdigit()}:
                raise OSError("process threads changed during inspection")
        except OSError as error:
            # Only disappearance of the group directory establishes group exit.
            # A zombie leader cannot excuse missing live-worker evidence.
            if isinstance(error, FileNotFoundError):
                try:
                    entry.stat()
                except FileNotFoundError:
                    continue
                except OSError:
                    pass
            raise ValueError("cannot inspect a same-user process; retain worktree") from error
    return exempt


def release(repo, path, head, owner, pr, slug, trust_process_manager=False):
    item, admin = selected(repo, path)
    path = Path(item["path"])
    if item["HEAD"] != head:
        raise ValueError("HEAD changed; owner must release the current artifact explicitly")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", slug) or pr <= 0 or not owner.strip():
        raise ValueError("release needs an owner and valid GitHub repository/PR")
    clean(path)
    check_admin_metadata(admin)
    # Record what no scan could read so the archive shows the exemption.
    scans = active_processes(path, trust_process_manager=trust_process_manager)
    scans += active_processes(admin, trust_process_manager=trust_process_manager)
    exempt = {item["pid"]: item for item in scans}
    if (admin / MARKER).exists():
        previous = marker(admin)
        if previous["owner"] != owner:
            raise ValueError("another owner holds the release record")
    data = dict(
        schema=1,
        path=str(path),
        head=head,
        branch=item.get("branch"),
        owner=owner,
        pr=pr,
        github_repo=slug,
        exempt_processes=[exempt[pid] for pid in sorted(exempt)],
        released_at=datetime.now(timezone.utc).isoformat(),
    )
    with tempfile.NamedTemporaryFile(mode="w", dir=admin, delete=False) as stream:
        json.dump(data, stream, indent=2)
        temporary = Path(stream.name)
    try:
        os.replace(temporary, admin / MARKER)
    finally:
        temporary.unlink(missing_ok=True)
    return data


def assess(repo, path, trust_process_manager=False):
    item, admin = selected(repo, path)
    path = Path(item["path"])
    try:
        record = marker(admin)
    except FileNotFoundError as error:
        raise ValueError("unreleased worktree: its owner must release it first") from error
    if (record.get("head"), record.get("path"), record.get("branch")) != (
        item["HEAD"],
        str(path),
        item.get("branch"),
    ):
        raise ValueError("HEAD, path or branch changed since release")
    clean(path)
    check_admin_metadata(admin)
    scans = active_processes(path, trust_process_manager=trust_process_manager)
    scans += active_processes(admin, trust_process_manager=trust_process_manager)
    exempt = {process["pid"]: process for process in scans}
    if any(admin.glob("*.lock")):
        raise ValueError("Git operation is active; retain worktree")
    slug = record["github_repo"]
    actual_slug = text(
        run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], cwd=repo)
    )
    if slug != actual_slug:
        raise ValueError("release record belongs to a different GitHub repository")
    default = text(run(["gh", "api", f"repos/{slug}", "--jq", ".default_branch"]))
    git(repo, "check-ref-format", "refs/heads/" + default)
    # Verify the local evidence is still the current remote default. No fetch
    # occurs during preview; callers can refresh explicitly and retry.
    cookie_flags = ["-c", "http.saveCookies=false"]
    keys = git(repo, "config", "--null", "--name-only", "--list").split(b"\0")
    for key in keys:
        name = os.fsdecode(key)
        if name.lower().startswith("http.") and name.lower().endswith(".savecookies"):
            cookie_flags.extend(["-c", name + "=false"])
    remote = git(
        repo, *cookie_flags, "ls-remote", "--exit-code", "origin", "refs/heads/" + default
    ).split()
    base = text(git(repo, "rev-parse", "--verify", "refs/remotes/origin/" + default))
    if len(remote) != 2 or os.fsdecode(remote[0]) != base:
        raise ValueError("remote evidence is stale or unavailable; fetch and retry")
    pr = json.loads(
        run(
            [
                "gh",
                "pr",
                "view",
                str(record["pr"]),
                "--repo",
                slug,
                "--json",
                "state,headRefOid,baseRefName,mergeCommit,isCrossRepository",
            ]
        )
    )
    if (
        pr.get("state") != "MERGED"
        or pr.get("isCrossRepository") is not False
        or pr.get("headRefOid") != item["HEAD"]
        or pr.get("baseRefName") != default
    ):
        raise ValueError(
            "no merged same-repository PR for the exact released HEAD and default branch"
        )
    merge = (pr.get("mergeCommit") or {}).get("oid", "")
    if not re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", merge):
        raise ValueError("missing merged artifact identity")
    git(repo, "merge-base", "--is-ancestor", merge, base)
    return (
        item,
        admin,
        dict(
            record,
            merge=merge,
            default_head=base,
            default_branch=default,
            retirement_exempt_processes=[exempt[pid] for pid in sorted(exempt)],
        ),
    )


def check_relocatable_worktree(path):
    # Repair updates Git's worktree links, not configured working-directory
    # overrides. Retain those checkouts without rewriting operator settings.
    keys = git(path, "config", "--null", "--name-only", "--list").split(b"\0")
    if any(key.lower() == b"core.worktree" for key in keys):
        raise ValueError("core.worktree overrides require separate retirement; retain worktree")


def detach_worktree_head(repo, admin, head):
    """Point a retired worktree's own HEAD at the released commit, by value.

    Writes only `HEAD` and its reflog inside that worktree's metadata directory
    in the source repository. The quarantined directory, its index, the recovery
    bundle and the recovery record are never touched, and the commit stays
    reachable from the merged PR, the bundle and this detached HEAD. A retired
    worktree that keeps its branch checked out makes `git branch -D` of that
    merged branch fail forever, with no supported way to finish the ordinary
    post-merge cleanup except editing worktree metadata by hand.
    """
    git(repo, "--git-dir=" + str(admin), "update-ref", "--no-deref", "HEAD", head)


def branch_holders(repo, branch):
    """Every worktree Git itself counts as holding this branch.

    A worktree that is mid-rebase or mid-bisect reports `detached` in worktree
    list while Git still refuses to delete the branch it started from, and
    `update-ref` enforces none of this, so read the same state Git reads:
    `rebase-merge/head-name`, `rebase-apply/head-name` and `BISECT_START`, which
    name either the full ref or its short form.
    """
    holders = []
    names = (branch, branch.removeprefix("refs/heads/"))
    for entry in worktrees(repo):
        if entry.get("branch") == branch:
            holders.append(entry["path"])
            continue
        admin = Path(text(git(entry["path"], "rev-parse", "--absolute-git-dir")))
        for state in ("rebase-merge/head-name", "rebase-apply/head-name", "BISECT_START"):
            try:
                held = (admin / state).read_text().strip()
            except FileNotFoundError:
                continue
            if held in names:
                holders.append(entry["path"])
                break
    return holders


def delete_released_branch(repo, branch, verified_head):
    """Delete the released branch only when it still names the verified head.

    `verified_head` is the head the collector already proved is the head of a
    merged same-repository PR into the verified current default branch. Deletion
    is the one step the quarantine cannot undo, so anything else -- an absent,
    moved, symbolic or still-checked-out ref -- leaves the ref alone and reports
    why. The final delete passes the expected value, so a concurrent update
    between the checks and the write makes Git refuse rather than discard an
    unverified commit; `update-ref` refuses neither a branch another worktree
    holds nor a redirection through a symbolic ref, so both are handled here.
    """
    if not branch:
        return False, "the retired worktree had no branch checked out"
    if not branch.startswith("refs/heads/"):
        return False, f"the released ref is not a local branch: {branch}"
    git(repo, "check-ref-format", branch)
    rows = text(git(repo, "for-each-ref", "--format=%(objectname) %(symref)", branch)).splitlines()
    if len(rows) != 1:
        return False, f"{branch} no longer resolves to exactly one local branch"
    objectname, _, symref = rows[0].partition(" ")
    if symref.strip():
        return False, f"{branch} is a symbolic ref to {symref.strip()}"
    if objectname != verified_head:
        return False, f"{branch} moved to {objectname}; the verified merged head is {verified_head}"
    holders = branch_holders(repo, branch)
    if holders:
        return False, f"{branch} is still held by the worktree at {holders[0]}"
    # --no-deref: a ref that turned symbolic between the check above and this
    # write can then only delete itself, never the branch it points at.
    git(repo, "update-ref", "--no-deref", "-d", branch, verified_head)
    # Git offers no lock that serializes a worktree attaching a branch against
    # deleting it (`git branch -D` has the same window). Once the ref is gone no
    # new attach can succeed, so re-read holders now and restore the ref for any
    # worktree that attached in between; the all-zero old value creates it only
    # if still absent.
    holders = branch_holders(repo, branch)
    if holders:
        git(repo, "update-ref", "--no-deref", branch, verified_head, "0" * len(verified_head))
        return False, f"{branch} was attached by the worktree at {holders[0]}; restored the ref"
    # `update-ref -d` leaves branch.<name>.* behind, and a later branch of the
    # same name would inherit its upstream and rebase settings. Match the whole
    # subsection, so branch `a` never claims the section of branch `a.b`.
    section = b"branch." + branch.removeprefix("refs/heads/").encode()
    try:
        keys = git(repo, "config", "--local", "--null", "--name-only", "--list").split(b"\0")
        if any(key.rpartition(b".")[0] == section for key in keys):
            git(repo, "config", "--local", "--remove-section", section.decode())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return True, f"deleted, but its branch configuration was not removed: {error}"
    return True, None


def retire(repo, path, apply, archive_dir, trust_process_manager=False, delete_branch=False):
    item, admin, record = assess(repo, path, trust_process_manager)
    if not apply:
        result = dict(
            disposition="ready", path=item["path"], owner=record["owner"], head=item["HEAD"]
        )
        if delete_branch:
            result.update(
                branch=record.get("branch"),
                branch_deleted=False,
                branch_reason="preview only; --apply detaches HEAD and then deletes the branch",
            )
        return result
    if archive_dir is None:
        raise ValueError("--apply requires an explicit private --archive-dir")
    check_relocatable_worktree(path)
    archive_dir = archive_dir.resolve()
    common = Path(
        text(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    ).resolve(strict=True)
    invoking_admin = Path(text(git(repo, "rev-parse", "--absolute-git-dir"))).resolve(strict=True)
    if invoking_admin != common:
        raise ValueError("--apply requires --repo to identify the primary checkout")
    # External common metadata can have multiple Git-file primary aliases;
    # neither worktree list nor show-toplevel can enumerate all those roots.
    # Apply only when the primary owns the conventional common directory.
    primary = Path(text(git(repo, "rev-parse", "--show-toplevel"))).resolve(strict=True)
    primary_git = primary / ".git"
    if not stat.S_ISDIR(primary_git.lstat().st_mode) or primary_git.resolve(strict=True) != common:
        raise ValueError(
            "--apply requires a conventional primary checkout with its own .git directory"
        )
    excluded = {primary, common, admin.resolve(strict=True)}
    excluded.update(Path(entry["path"]).resolve() for entry in worktrees(repo))
    for root in excluded:
        if archive_dir == root or root in archive_dir.parents:
            raise ValueError("archive must be outside repository worktrees and Git metadata")
    # Git-file aliases of even a conventional primary need not be registered.
    # Inspect existing ancestry without creating the destination, and force
    # each discovered marker so malformed metadata cannot fall back upward.
    for directory in (archive_dir, *archive_dir.parents):
        git_marker = directory / ".git"
        try:
            git_marker.lstat()
        except FileNotFoundError:
            continue
        ancestor_common = Path(
            text(
                git(
                    directory,
                    "--git-dir=" + str(git_marker),
                    "rev-parse",
                    "--path-format=absolute",
                    "--git-common-dir",
                )
            )
        ).resolve(strict=True)
        if ancestor_common == common:
            raise ValueError("archive must be outside this repository, including Git-file aliases")
    archive_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = archive_dir.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("archive directory must be private to the current user")
    archive = Path(tempfile.mkdtemp(prefix="retired-", dir=archive_dir))
    if path.stat().st_dev != archive.stat().st_dev:
        raise ValueError(f"quarantine requires the same filesystem; retained; archive: {archive}")
    # Include reflog-only detached work in the independent recovery bundle.
    # This adds pack objects without creating recovery refs in the source repo.
    git(path, "bundle", "create", str(archive / "repository.bundle"), "--all", "--reflog")
    git(repo, "bundle", "verify", str(archive / "repository.bundle"))
    with tarfile.open(archive / "worktree-metadata.tar", "w") as stream:
        stream.add(admin, arcname="worktree-metadata", recursive=True)
    record["files"] = {
        p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in archive.iterdir()
    }
    (archive / "recovery.json").write_text(json.dumps(record, indent=2) + "\n")
    # Recheck after archival. Released ownership is still required, but even
    # an exited writer may have changed the source after the earlier sample.
    # Each scan can exempt different identities than release did, because the
    # session manager may have restarted since; the archive records every
    # exemption any retirement scan observed, so that key never compares.
    volatile = ("files", "retirement_exempt_processes")
    again, _, current = assess(repo, path, trust_process_manager)
    if {k: v for k, v in current.items() if k not in volatile} != {
        k: v for k, v in record.items() if k not in volatile
    } or again != item:
        raise ValueError(f"worktree changed during archival; retained; archive: {archive}")
    observed = {
        process["pid"]: process
        for process in record["retirement_exempt_processes"]
        + current["retirement_exempt_processes"]
    }
    record["retirement_exempt_processes"] = [observed[pid] for pid in sorted(observed)]
    # Persist the merged exemptions now: a later check may retain the worktree,
    # and the retained archive must still name every identity a scan skipped.
    (archive / "recovery.json").write_text(json.dumps(record, indent=2) + "\n")
    # A completed writer no longer appears in process evidence. Bind the
    # final source state to the actual saved bytes, including archive hardlinks;
    # ignore access/modify timestamps that do not change recoverable content.
    try:
        if not archived_metadata_matches(admin, archive / "worktree-metadata.tar"):
            raise ValueError("metadata differs from archive")
        check_relocatable_worktree(path)
    except (OSError, ValueError, tarfile.TarError) as error:
        raise ValueError(
            f"Git metadata changed or could not be verified; retained; archive: {archive}"
        ) from error
    # Git removal discards ignored files, including writes after the final
    # sample. Retain the actual directory instead: rename preserves late
    # entries and writes through open descriptors. Never copy/delete it.
    quarantine = archive / "worktree"
    # `expire` dates the entry from this timestamp (#562).
    record.update(
        quarantine=str(quarantine),
        git_metadata=str(admin),
        retired_at=datetime.now(timezone.utc).isoformat(),
    )
    (archive / "recovery.json").write_text(json.dumps(record, indent=2) + "\n")
    # Lock BEFORE renaming so interruption cannot leave now-missing worktree
    # metadata eligible for pruning. Repair reconnects Git to the new path;
    # failure retains both bytes and the lock for explicit recovery.
    git(repo, "worktree", "lock", "--reason", QUARANTINE_LOCK + str(archive), str(path))
    try:
        os.rename(path, quarantine)
        git(repo, "worktree", "repair", str(quarantine))
        actual_path = Path(text(git(quarantine, "rev-parse", "--show-toplevel"))).resolve(
            strict=True
        )
        actual_admin = Path(text(git(quarantine, "rev-parse", "--absolute-git-dir"))).resolve(
            strict=True
        )
        if actual_path != quarantine or actual_admin != admin.resolve(strict=True):
            raise ValueError("repaired Git worktree points outside the retained checkout")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise ValueError(
            f"quarantine interrupted; files and locked metadata retained; archive: {archive}"
        ) from error
    # Detach last, so every record above still names the branch this task
    # worked on. Verify through the same porcelain the operator reads, because
    # the point of the step is that no ref of the source repository is held by
    # the quarantine any more.
    try:
        detach_worktree_head(repo, admin, item["HEAD"])
        detached = next(
            (entry for entry in worktrees(repo) if Path(entry["path"]).resolve() == quarantine),
            None,
        )
        if detached is None or "branch" in detached or detached.get("HEAD") != item["HEAD"]:
            raise ValueError("metadata HEAD is not detached at the released commit")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise ValueError(
            "quarantine completed but the worktree HEAD could not be detached; the branch ref "
            f"is retained; archive: {archive}"
        ) from error
    result = dict(
        disposition="quarantined",
        path=item["path"],
        quarantine=str(quarantine),
        head=item["HEAD"],
        archive=str(archive),
        branch=record.get("branch"),
        detached=True,
        branch_deleted=False,
        branch_reason="detached; the merged branch ref is now deletable",
    )
    if delete_branch:
        # A refused deletion leaves a merged ref behind, which the operator can
        # still delete; it never invalidates the completed retirement, so it is
        # reported here rather than raised.
        try:
            deleted, reason = delete_released_branch(repo, record.get("branch"), item["HEAD"])
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            deleted, reason = False, f"branch deletion could not be verified: {error}"
        result.update(
            branch_deleted=deleted,
            branch_reason=reason or "deleted; it still named the verified merged head",
        )
    return result


def window_days(value):
    match = re.fullmatch(r"([0-9]{1,5})d", value or "")
    if not match:
        raise ValueError("--older-than takes a whole number of days, such as 30d")
    return int(match.group(1))


def recovery_record(archive):
    """The recovery record an applied retirement wrote, and its lstat."""
    path = archive / "recovery.json"
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("not a regular file of the current user")
        record = json.loads(read_regular(path))
    except (OSError, ValueError) as error:
        raise ValueError("missing or unparseable recovery.json; retain for inspection") from error
    if not isinstance(record, dict) or not all(
        isinstance(record.get(key), kind)
        for key, kind in (("head", str), ("path", str), ("github_repo", str), ("pr", int))
    ):
        raise ValueError("recovery.json lacks its head, path or PR; retain for inspection")
    return record, info


def retired_time(record, info):
    value = record.get("retired_at")
    if value is None:
        # Records written before `retired_at` existed: retirement's last write
        # of recovery.json is the quarantine step, so its mtime dates the entry.
        return datetime.fromtimestamp(info.st_mtime, timezone.utc)
    try:
        moment = datetime.fromisoformat(value)
    except (TypeError, ValueError) as error:
        raise ValueError("unparseable retired_at in recovery.json; retain") from error
    if moment.tzinfo is None:
        raise ValueError("retired_at in recovery.json has no timezone; retain")
    return moment


def age_days(moment, now):
    return int((now - moment).total_seconds() // 86400)


def check_window(moment, now, days):
    if now - moment < timedelta(days=days):
        raise ValueError(f"retired {age_days(moment, now)}d ago, inside the {days}d window")


def check_recovery_files(archive, record):
    """Require the bundle and metadata tar to be the bytes retirement wrote.

    Removing the checkout relies on them as the recovery path, and the metadata
    comparison below reads the tar, so each must still hash to what
    recovery.json recorded.
    """
    recorded = record.get("files")
    for name in ("repository.bundle", "worktree-metadata.tar"):
        # Streamed: a bundle holds every ref and reflog of the repository.
        digest = hashlib.sha256()
        try:
            with open_regular(archive / name) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
        except (OSError, ValueError) as error:
            raise ValueError(f"cannot read {name} ({error}); retain for inspection") from error
        if not isinstance(recorded, dict) or recorded.get(name) != digest.hexdigest():
            raise ValueError(f"{name} differs from what retirement recorded; retain for inspection")


def check_metadata_archived(admin, archive, head):
    """Refuse live Git metadata that holds anything worktree-metadata.tar does not.

    `git worktree remove` deletes this directory. Everything it held at
    retirement is in the archived tar, which expiry keeps, so removal can lose
    only what was written since. Retirement's own later writes are allowed: the
    lock, the repaired `gitdir` pointer, HEAD detached at the recorded head and
    reflog lines from the recorded head to itself; neither the lock reason nor
    the gitdir path holds work. Every other file, the index included, must be
    byte-identical to its archived copy, and no other name may appear.
    """
    try:
        with tarfile.open(
            fileobj=io.BytesIO(read_regular(archive / "worktree-metadata.tar"))
        ) as tar:
            saved = {}
            for member in tar.getmembers():
                relative = member.name.removeprefix("worktree-metadata/")
                content = None
                if member.isfile():
                    with tar.extractfile(member) as stream:
                        content = stream.read()
                saved[relative] = (member, content)
    except (OSError, tarfile.TarError) as error:
        raise ValueError("cannot read worktree-metadata.tar; retain for inspection") from error

    def refuse(relative, why):
        raise ValueError(f"Git metadata {relative} {why} since retirement; retain for inspection")

    def scan_error(error):
        raise error

    for directory, dirs, files in os.walk(admin, followlinks=False, onerror=scan_error):
        for name in dirs + files:
            path = Path(directory) / name
            relative = path.relative_to(admin).as_posix()
            info = path.lstat()
            member, content = saved.get(relative, (None, None))
            if stat.S_ISDIR(info.st_mode):
                # A directory holds nothing itself; its entries are walked.
                if member is not None and not member.isdir():
                    refuse(relative, "changed type")
                continue
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
                refuse(relative, "is a special file created or changed")
            if relative in ("locked", "gitdir"):
                if not stat.S_ISREG(info.st_mode):
                    refuse(relative, "changed type")
                continue
            if relative == "HEAD":
                if read_regular(path).strip() != head.encode():
                    refuse(relative, "moved")
                continue
            if relative == "logs/HEAD":
                live, old = read_regular(path), content or b""
                if not live.startswith(old):
                    refuse(relative, "was rewritten")
                # Retirement's detach logs head -> head. A line naming any
                # other commit on either side may be its last reference.
                for line in live[len(old) :].splitlines():
                    if line.split(b" ")[:2] != [head.encode(), head.encode()]:
                        refuse(relative, "recorded a commit other than the recorded head")
                continue
            if member is None:
                refuse(relative, "was written")
            if stat.S_IMODE(info.st_mode) != member.mode:
                refuse(relative, "changed mode")
            if stat.S_ISLNK(info.st_mode):
                if not member.issym() or os.readlink(path) != member.linkname:
                    refuse(relative, "changed")
            elif not member.isfile() or read_regular(path) != content:
                refuse(relative, "changed")


def still_registered(repo, path, head, lock):
    """Re-read the registration right before removal; any change retains it."""
    current = next((entry for entry in worktrees(repo) if Path(entry["path"]) == path), None)
    if (
        current is None
        or "branch" in current
        or current.get("HEAD") != head
        or current.get("locked") != lock
    ):
        raise ValueError("the worktree changed after inspection; retained")


def outside(path):
    cwd = Path.cwd().resolve()
    if cwd == path or path in cwd.parents:
        raise ValueError("run expire from outside the archived worktree; retained")


def expirable_quarantine(repo, archive, item, record, moment, now, days, trust):
    """Check a quarantine and return the function that removes it.

    Removal deletes the checkout and its Git metadata directory only; the
    recovery files stay in the entry permanently (#562).
    """
    quarantine = archive / "worktree"
    if record.get("quarantine") != str(quarantine):
        raise ValueError("recovery.json names a different quarantine; retain for inspection")
    extra = sorted(set(os.listdir(archive)) - {*ARCHIVE_FILES, "worktree"})
    if extra:
        raise ValueError("unexpected archive content, retain for inspection: " + ", ".join(extra))
    lock = QUARANTINE_LOCK + str(archive)
    if item.get("locked") != lock:
        raise ValueError("the worktree lock does not name this archive; retain for inspection")
    if "branch" in item:
        raise ValueError(f"still attached to {item['branch']}; retain worktree")
    head = record["head"]
    if item.get("HEAD") != head:
        raise ValueError("HEAD moved since retirement; retain worktree")
    check_window(moment, now, days)
    check_recovery_files(archive, record)
    admin = Path(text(git(quarantine, "rev-parse", "--absolute-git-dir")))
    if str(admin) != record.get("git_metadata"):
        raise ValueError("Git metadata moved since retirement; retain worktree")
    release = marker(admin)
    if (release.get("head"), release.get("pr"), release.get("github_repo")) != (
        head,
        record["pr"],
        record["github_repo"],
    ):
        raise ValueError("release record disagrees with recovery.json; retain for inspection")

    def inspect(checkout):
        clean(checkout)
        active_processes(checkout, trust_process_manager=trust)
        active_processes(admin, trust_process_manager=trust)
        # Last: a commit made through the Git metadata while the checkout was
        # inspected leaves it clean, but moves HEAD or adds a reflog line.
        still_registered(repo, checkout, head, lock)
        check_metadata_archived(admin, archive, head)

    inspect(quarantine)

    def remove():
        outside(quarantine)
        # Mirror retirement: move the checkout out of its known path first, so
        # a path-based writer can no longer land in what is about to be
        # deleted, then inspect the moved directory itself. The lock (which
        # names this archive) stays in place across the move and repair.
        staging = archive / STAGING
        if os.path.lexists(staging):
            raise ValueError("an earlier expiry left a staging checkout; retain for inspection")
        os.rename(quarantine, staging)
        try:
            git(repo, "worktree", "repair", str(staging))
            inspect(staging)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            try:
                os.rename(staging, quarantine)
                git(repo, "worktree", "repair", str(quarantine))
            except (OSError, ValueError, subprocess.SubprocessError) as restore:
                raise ValueError(
                    f"changed after inspection ({error}); the checkout is retained at {staging} "
                    f"because moving it back failed: {restore}"
                ) from error
            raise ValueError(f"changed after inspection; retained: {error}") from error
        # --force twice overrides the lock this function verified names this
        # archive; clean() above already refused ignored or local bytes. What
        # remains is Git's own window between the last read and this removal,
        # the same one #522 records for branch deletion.
        git(repo, "worktree", "remove", "--force", "--force", str(staging))

    return remove


def expire(repos, archive_dir, days, apply, trust_process_manager=False, now=None):
    """Remove retired checkouts past the window; never their recovery files.

    Report mode (apply false) runs every check and changes nothing: it never
    creates the archive directory and issues only reading Git commands.
    """
    now = now or datetime.now(timezone.utc)
    archive_dir = archive_dir.resolve()
    registrations, errors = {}, []
    for repo in repos:
        try:
            for item in worktrees(repo):
                path = Path(item["path"])
                if archive_dir in path.parents:
                    registrations[path] = (repo, item)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            errors.append(dict(repo=str(repo), reason=str(error)))
    children = []
    try:
        info = archive_dir.lstat()
    except FileNotFoundError:
        info = None
    if info is not None:
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("archive directory must be a private directory of the current user")
        children = sorted(archive_dir.iterdir())
    entries = []
    for child in children:
        entry = dict(archive=str(child), kind="orphan-directory", path=None, pr=None, age_days=None)
        registration = registrations.pop(child / "worktree", None)
        # An expiry interrupted after its repair leaves the registration at the
        # staging path; it belongs to this entry, not to an orphan (#569).
        staged = registrations.pop(child / STAGING, None)
        try:
            if child.is_symlink() or not child.is_dir():
                raise ValueError("not an archive directory; retain for inspection")
            if staged is not None:
                entry["kind"] = "interrupted-expiry"
            elif registration is not None:
                entry["kind"] = "quarantine"
            elif not any(os.path.lexists(child / name) for name in ("worktree", STAGING)):
                # An expired entry, or a retirement stopped before its
                # quarantine: only recovery files, which expiry never deletes.
                entry.update(
                    kind="recovery-files",
                    disposition="kept",
                    reason="recovery files only; expire never deletes them",
                )
            record, record_info = recovery_record(child)
            entry.update(path=record["path"], pr=record["pr"])
            moment = retired_time(record, record_info)
            entry["age_days"] = age_days(moment, now)
            if entry["kind"] == "recovery-files":
                entries.append(entry)
                continue
            if entry["kind"] == "interrupted-expiry":
                raise ValueError(
                    f"an interrupted expiry left the checkout registered at {child / STAGING}; "
                    "inspect it, then remove it or move it back to worktree and run "
                    "`git worktree repair` by hand"
                )
            if entry["kind"] == "orphan-directory":
                raise ValueError(
                    "the quarantined checkout is not a registered worktree of a scanned "
                    "repository; inspect and remove it by hand"
                )
            remove = expirable_quarantine(
                registration[0],
                child,
                registration[1],
                record,
                moment,
                now,
                days,
                trust_process_manager,
            )
            entry.update(
                disposition="expirable",
                reason=f"retired {entry['age_days']}d ago, past the {days}d window; the "
                "checkout is clean and its Git metadata is archived",
            )
            if apply:
                remove()
                entry.update(
                    disposition="expired",
                    reason="removed the checkout and registration, kept the recovery files; "
                    + entry["reason"],
                )
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            if entry["kind"] != "recovery-files":
                entry.update(disposition="retained", reason=str(error))
            else:
                entry["reason"] += f" ({error})"
        entries.append(entry)
    # What remains is registered under the archive without its entry: never
    # removed here, since the recovery files that would back it are gone.
    for path in sorted(registrations):
        entries.append(
            dict(
                archive=str(path.parent),
                kind="orphan-registration",
                path=None,
                pr=None,
                age_days=None,
                disposition="retained",
                reason="registered under the archive without a matching archive entry; "
                "inspect and remove it by hand",
            )
        )
    # Kept recovery files are not retired worktrees any more.
    live = [entry for entry in entries if entry["kind"] != "recovery-files"]
    ages = [entry["age_days"] for entry in live if entry["age_days"] is not None]
    return dict(
        archive_dir=str(archive_dir),
        older_than_days=days,
        applied=apply,
        entries=entries,
        retired=len(live),
        kept=len(entries) - len(live),
        expirable=sum(entry["disposition"] == "expirable" for entry in entries),
        expired=sum(entry["disposition"] == "expired" for entry in entries),
        retained=sum(entry["disposition"] == "retained" for entry in entries),
        oldest_days=max(ages, default=None),
        errors=errors,
    )


def inventory(repo):
    output = []
    for item in worktrees(repo):
        result = dict(path=item["path"], head=item.get("HEAD"), disposition="retained", owner=None)
        try:
            _, admin = selected(repo, Path(item["path"]))
            data = marker(admin)
            result.update(owner=data["owner"], pr=data["pr"])
            if (data.get("head"), data.get("path"), data.get("branch")) != (
                item.get("HEAD"),
                item["path"],
                item.get("branch"),
            ):
                result["reason"] = "HEAD, path or branch changed since release"
            else:
                result.update(
                    disposition="released",
                    reason="owner finished; verify merged PR before retirement",
                )
        except FileNotFoundError:
            result["reason"] = "unreleased; active ownership or task disposition unknown"
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            result["reason"] = str(error)
            if str(error) == "the primary checkout must be retained":
                result["disposition"] = "primary"
        output.append(result)
    return dict(
        worktrees=output,
        retained=sum(i["disposition"] == "retained" for i in output),
        released=sum(i["disposition"] == "released" for i in output),
    )


def primary_repositories(root):
    """Primary repositories directly under root, and the children it could not read."""
    repos, errors = [], []
    seen = set()
    for repo in sorted(root.resolve(strict=True).iterdir()):
        if repo.is_symlink():
            continue
        try:
            if not repo.is_dir():
                continue
            try:
                info = (repo / ".git").lstat()
            except FileNotFoundError:
                continue
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise ValueError(".git is not a regular file or directory")
            # Both primary separate-git-dir checkouts and linked worktrees
            # use Git files. Their canonical admin/common identities differ
            # only for linked worktrees; discover each primary repository once.
            admin = Path(text(git(repo, "rev-parse", "--absolute-git-dir"))).resolve(strict=True)
            common = Path(
                text(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))
            ).resolve(strict=True)
            if admin != common or common in seen:
                continue
            seen.add(common)
            repos.append(repo)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            errors.append(dict(repo=str(repo), reason=str(error)))
    return repos, errors


def inventory_root(root):
    output = []
    repos, errors = primary_repositories(root)
    for repo in repos:
        try:
            output.extend(inventory(repo)["worktrees"])
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            errors.append(dict(repo=str(repo), reason=str(error)))
    return dict(
        worktrees=output,
        errors=errors,
        retained=sum(i["disposition"] == "retained" for i in output),
        released=sum(i["disposition"] == "released" for i in output),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inventory", "release", "retire", "expire"))
    parser.add_argument("--repo", type=Path)
    parser.add_argument(
        "--root",
        type=Path,
        help="inventory or expire across primary repositories directly under this directory",
    )
    parser.add_argument(
        "--older-than",
        help="expire: only entries retired at least this many days ago, such as 30d",
    )
    parser.add_argument("--worktree", type=Path)
    parser.add_argument("--head")
    parser.add_argument("--owner")
    parser.add_argument("--pr", type=int)
    parser.add_argument("--github-repo")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--delete-branch",
        action="store_true",
        help="after detaching, delete the released local branch when it still names the "
        "verified merged PR head; any other state leaves the ref and reports why",
    )
    parser.add_argument(
        "--trust-process-manager",
        action="store_true",
        help="assert that this user's uninspectable systemd session manager and its (sd-pam) "
        "helper hold no reference to the worktree; each exempted pid is recorded",
    )
    parser.add_argument("--archive-dir", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.action == "expire":
            if (args.repo is None) == (args.root is None):
                raise ValueError("expire requires exactly one of --repo or --root")
            if args.archive_dir is None or args.older_than is None:
                raise ValueError("expire requires --archive-dir and --older-than")
            days = window_days(args.older_than)
            if args.root is not None:
                repos, errors = primary_repositories(args.root)
            else:
                repos, errors = [args.repo], []
            result = expire(repos, args.archive_dir, days, args.apply, args.trust_process_manager)
            result["errors"] = errors + result["errors"]
        elif args.action == "inventory" and args.root is not None:
            if args.repo is not None:
                raise ValueError("choose --repo or --root")
            result = inventory_root(args.root)
        elif args.repo is None:
            raise ValueError("--repo is required")
        elif args.root is not None:
            raise ValueError("--root is only supported for inventory and expire")
        elif args.action == "inventory":
            result = inventory(args.repo)
        elif args.worktree is None:
            raise ValueError("--worktree is required")
        elif args.action == "release":
            if not all((args.head, args.owner, args.pr, args.github_repo)):
                raise ValueError("release requires --head, --owner, --pr and --github-repo")
            result = release(
                args.repo,
                args.worktree,
                args.head,
                args.owner,
                args.pr,
                args.github_repo,
                args.trust_process_manager,
            )
        else:
            result = retire(
                args.repo,
                args.worktree.resolve(),
                args.apply,
                args.archive_dir,
                args.trust_process_manager,
                args.delete_branch,
            )
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"worktree-lifecycle: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
