#!/usr/bin/env python3
"""Snapshot and recover an exactly identified managed Codex daemon.

Safety argument — why the SIGTERM path cannot hit the wrong process:

- Within one boot, a reused PID's start ticks must postdate the snapshot's, so
  an exact ``{bootId, pid, startTicks}`` match proves the ``/proc`` reads
  describe the fingerprinted process even though those reads are keyed by PID
  rather than by the pidfd.
- ``snapshot_updater`` has no prior identity to compare against, so it needs
  the signal-0 liveness proof through the held pidfd to bind its ``/proc``
  reads to a live process; ``terminate_stale_updater`` does not, because any
  mismatch fails the exact-fingerprint comparison before a signal is sent.
- If the pidfd and the validated process ever diverge, the pidfd necessarily
  refers to an already-dead process, so signaling it is harmless and
  ``_wait_for_exit`` degrades safely.
- Plain SIGTERM with no SIGKILL escalation is a deliberate fail-closed choice.

Missing PID-record repair sends only signal 0: the saved updater fingerprint
and a socket-provided pidfd establish ownership before native records are
restored under Codex's own locks. The startup probe touches neither PID records
nor process state: native management commands can discard live PID records
after wall-clock drift.

None of this is reproducible in a unit test: do not reorder ``pidfd_open``
relative to the ``/proc`` reads, and do not remove the signal-0 call.
"""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import select
import signal
import socket
import stat
import struct
import sys
import tempfile
import time
from typing import Callable


MAX_RECORD_BYTES = 4096
MAX_CMDLINE_BYTES = 4096
MAX_PROC_STAT_BYTES = 64 * 1024 * 1024
WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTHS = (
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
)


def _read_bounded(path: Path, limit: int) -> bytes:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK
    fd = os.open(path, flags)
    try:
        data = os.read(fd, limit + 1)
    finally:
        os.close(fd)
    if len(data) > limit:
        raise ValueError("file is too large")
    return data


def _load_json_record(path: Path, expected_uid: int) -> dict[str, object]:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK | os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("record is not a regular file")
        if metadata.st_uid != expected_uid or metadata.st_size > MAX_RECORD_BYTES:
            raise ValueError("record ownership or size is invalid")
        raw = os.read(fd, MAX_RECORD_BYTES + 1)
    finally:
        os.close(fd)
    if len(raw) > MAX_RECORD_BYTES:
        raise ValueError("record is too large")

    record = json.loads(raw.decode("utf-8"))
    if not isinstance(record, dict):
        raise ValueError("record is not an object")
    return record


def _load_pid_record(pid_file: Path, expected_uid: int) -> tuple[int, str]:
    record = _load_json_record(pid_file, expected_uid)
    pid = record.get("pid")
    process_start = record.get("processStartTime")
    if type(pid) is not int or pid <= 1:  # bool is an int subclass
        raise ValueError("recorded PID is invalid")
    if not isinstance(process_start, str) or not process_start:
        raise ValueError("recorded start time is invalid")
    return pid, process_start


def _read_boot_time(proc_stat_path: Path) -> int:
    """Find btime without retaining the potentially large per-CPU stat file."""

    fd = os.open(proc_stat_path, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK)
    scanned = 0
    window = b"\n"
    try:
        while True:
            chunk = os.read(fd, 8192)
            if not chunk:
                break
            scanned += len(chunk)
            if scanned > MAX_PROC_STAT_BYTES:
                raise ValueError("process stat scan is too large")
            window += chunk
            marker = window.find(b"\nbtime ")
            if marker >= 0:
                value = window[marker + len(b"\nbtime ") :]
                if b"\n" in value:
                    return int(value.split(b"\n", 1)[0])
            window = window[-128:]
    finally:
        os.close(fd)
    raise ValueError("process stat has no boot time")


def _load_exact_identity(
    identity_file: Path, expected_uid: int
) -> dict[str, object]:
    identity = _load_json_record(identity_file, expected_uid)
    if set(identity) != {"bootId", "pid", "processStartTime", "startTicks"}:
        raise ValueError("identity fields are invalid")
    if type(identity["pid"]) is not int or identity["pid"] <= 1:
        raise ValueError("identity PID is invalid")
    if type(identity["startTicks"]) is not int or identity["startTicks"] < 0:
        raise ValueError("identity start ticks are invalid")
    if not isinstance(identity["bootId"], str) or not identity["bootId"]:
        raise ValueError("identity boot ID is invalid")
    if (
        not isinstance(identity["processStartTime"], str)
        or not identity["processStartTime"]
    ):
        raise ValueError("identity display time is invalid")
    return identity


def _process_identity(
    proc_root: Path, pid: int, clock_ticks: int
) -> dict[str, object]:
    if clock_ticks <= 0:
        raise ValueError("clock tick rate is invalid")
    boot_time = _read_boot_time(proc_root / "stat")
    boot_id = (
        _read_bounded(proc_root / "sys/kernel/random/boot_id", MAX_RECORD_BYTES)
        .decode("ascii")
        .strip()
    )
    if not boot_id:
        raise ValueError("boot ID is empty")

    pid_stat = _read_bounded(proc_root / str(pid) / "stat", MAX_RECORD_BYTES).decode(
        "ascii"
    )
    closing_paren = pid_stat.rfind(")")
    if closing_paren < 0:
        raise ValueError("process stat is malformed")
    fields_after_command = pid_stat[closing_paren + 2 :].split()
    start_ticks = int(fields_after_command[19])
    started = time.localtime(boot_time + start_ticks / clock_ticks)
    process_start = (
        f"{WEEKDAYS[started.tm_wday]} {MONTHS[started.tm_mon - 1]} "
        f"{started.tm_mday:2d} {started.tm_hour:02d}:{started.tm_min:02d}:"
        f"{started.tm_sec:02d} {started.tm_year:04d}"
    )
    return {
        "bootId": boot_id,
        "pid": pid,
        "processStartTime": process_start,
        "startTicks": start_ticks,
    }


def _managed_executable(
    proc_root: Path, pid: int, home: Path, codex_home: Path, expected_uid: int
) -> tuple[Path, Path]:
    proc_exe = proc_root / str(pid) / "exe"
    executable = proc_exe.resolve(strict=True)
    running_metadata = proc_exe.stat()
    if (
        running_metadata.st_uid != expected_uid
        or not stat.S_ISREG(running_metadata.st_mode)
        or running_metadata.st_mode & 0o022
    ):
        raise ValueError("running executable ownership is invalid")
    selected_home = codex_home.resolve(strict=True)
    if selected_home.stat().st_uid != expected_uid:
        raise ValueError("selected Codex home owner is invalid")

    # Daemon state selects one installation; the login-home installation also
    # remains valid when only daemon state has moved to a custom Codex home.
    for candidate in (selected_home, home / ".codex"):
        try:
            root = candidate.resolve(strict=True)
            installation = root / "packages/standalone"
            releases = installation / "releases"
            relative = executable.relative_to(releases)
            if len(relative.parts) != 3 or relative.parts[1:] != ("bin", "codex"):
                continue
            paths = (
                root, root / "packages", installation, releases,
                executable.parent.parent, executable.parent, executable,
            )
            for path in paths:
                metadata = path.stat()
                expected_type = stat.S_ISREG if path == executable else stat.S_ISDIR
                if (
                    metadata.st_uid != expected_uid
                    or not expected_type(metadata.st_mode)
                    or metadata.st_mode & 0o022
                    or path.resolve(strict=True) != path
                    or (path == executable and not os.path.samestat(metadata, running_metadata))
                ):
                    raise ValueError("managed release ownership or path is invalid")
            return executable, installation
        except (OSError, ValueError):
            continue
    raise ValueError("executable is outside an owned managed release")


def _validate_managed_process(
    *,
    proc_root: Path,
    home: Path,
    codex_home: Path,
    pid: int,
    recorded_start: str | None,
    expected_uid: int,
    clock_ticks: int,
    role: tuple[bytes, ...] = (b"app-server", b"daemon", b"pid-update-loop"),
) -> dict[str, object]:
    process_dir = proc_root / str(pid)
    if process_dir.stat().st_uid != expected_uid:
        raise ValueError("process owner is invalid")
    identity = _process_identity(proc_root, pid, clock_ticks)
    if recorded_start is not None and identity["processStartTime"] != recorded_start:
        raise ValueError("process display time does not match")

    executable, installation = _managed_executable(
        proc_root, pid, home, codex_home, expected_uid
    )
    cmdline = _read_bounded(process_dir / "cmdline", MAX_CMDLINE_BYTES)
    if not cmdline.endswith(b"\0"):
        raise ValueError("process command line does not match")
    arguments = cmdline[:-1].split(b"\0")
    if len(arguments) != len(role) + 1:
        raise ValueError("process argument count does not match")
    argv_zero = Path(os.fsdecode(arguments[0]))
    # An updated launcher can name an older running release only within the
    # same installation, including a selected-home alias to that installation.
    updated_launcher = False
    if argv_zero.is_absolute():
        for suffix in (("current", "codex"), ("current", "bin", "codex")):
            if (
                argv_zero.parts[-len(suffix):] == suffix
                and argv_zero.parents[len(suffix) - 1].resolve(strict=True) == installation
            ):
                updated_launcher = True
                break
    if not argv_zero.is_absolute() or (
        not updated_launcher and argv_zero.resolve(strict=True) != executable
    ):
        raise ValueError("process argv zero does not resolve to its executable")
    if tuple(arguments[1:]) != role:
        raise ValueError("process role arguments do not match")
    return identity


def _write_identity(
    identity_file: Path, identity: dict[str, object], expected_uid: int,
    *, create_only: bool = False,
) -> None:
    parent = identity_file.parent
    parent_metadata = parent.stat()
    if not stat.S_ISDIR(parent_metadata.st_mode) or parent_metadata.st_uid != expected_uid:
        raise ValueError("identity directory is invalid")
    try:
        existing = identity_file.lstat()
    except FileNotFoundError:
        pass
    else:
        if not stat.S_ISREG(existing.st_mode) or existing.st_uid != expected_uid:
            raise ValueError("existing identity file is invalid")

    payload = (json.dumps(identity, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )
    temp_fd, temp_name = tempfile.mkstemp(
        dir=parent, prefix=f".{identity_file.name}.", text=False
    )
    try:
        os.fchmod(temp_fd, 0o600)
        with os.fdopen(temp_fd, "wb", closefd=True) as temp_file:
            temp_fd = -1
            temp_file.write(payload)
            temp_file.flush()
            os.fsync(temp_file.fileno())
        if create_only:
            os.link(temp_name, identity_file)
        else:
            os.replace(temp_name, identity_file)
    finally:
        if temp_fd >= 0:
            os.close(temp_fd)
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def _wait_for_exit(pidfd: int, timeout_seconds: int) -> bool:
    poller = select.poll()
    poller.register(pidfd, select.POLLIN)
    return bool(poller.poll(timeout_seconds * 1000))


def probe_shared_server(socket_path: Path) -> int:
    """Return 0 for listening, 3 for absent, and 2 for an uncertain socket."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(2)
            client.connect(str(socket_path))
        # The native TUI owns protocol validation. Any listener at its configured
        # socket must be left untouched, even when its relay or PID records fail.
        return 0
    except (FileNotFoundError, ConnectionRefusedError):
        # Reserve exit 1 for interpreter/import failures, which are uncertain.
        return 3
    except OSError:
        return 2


def snapshot_updater(
    *,
    pid_file: Path,
    identity_file: Path,
    proc_root: Path,
    home: Path,
    expected_uid: int,
    clock_ticks: int,
    pidfd_open: Callable[[int], int] | None = None,
    pidfd_send_signal: Callable[[int, int], None] | None = None,
    close_pidfd: Callable[[int], None] | None = None,
) -> bool:
    """Persist an exact identity only after a successful managed launch."""

    pidfd: int | None = None
    pidfd_open = pidfd_open or getattr(os, "pidfd_open", None)
    pidfd_send_signal = pidfd_send_signal or getattr(signal, "pidfd_send_signal", None)
    close_pidfd = close_pidfd or os.close
    if pidfd_open is None or pidfd_send_signal is None:
        return False
    try:
        pid, recorded_start = _load_pid_record(pid_file, expected_uid)
        pidfd = pidfd_open(pid)
        identity = _validate_managed_process(
            proc_root=proc_root,
            home=home,
            codex_home=pid_file.parent.parent,
            pid=pid,
            recorded_start=recorded_start,
            expected_uid=expected_uid,
            clock_ticks=clock_ticks,
        )
        # Signal 0 has no process effect. It proves the pidfd-captured process
        # remained alive through the /proc reads, so the exact ticks belong to it.
        pidfd_send_signal(pidfd, 0)
        _write_identity(identity_file, identity, expected_uid)
        return True
    except (IndexError, KeyError, OSError, StopIteration, UnicodeError, ValueError):
        return False
    finally:
        if pidfd is not None:
            try:
                close_pidfd(pidfd)
            except OSError:
                pass


def terminate_stale_updater(
    *,
    pid_file: Path,
    identity_file: Path,
    proc_root: Path,
    home: Path,
    expected_uid: int,
    clock_ticks: int,
    pidfd_open: Callable[[int], int] | None = None,
    pidfd_send_signal: Callable[[int, int], None] | None = None,
    wait_for_exit: Callable[[int, int], bool] | None = None,
    close_pidfd: Callable[[int], None] | None = None,
) -> bool:
    """Signal only the process fingerprinted after an earlier successful launch."""

    pidfd: int | None = None
    pidfd_open = pidfd_open or getattr(os, "pidfd_open", None)
    pidfd_send_signal = pidfd_send_signal or getattr(signal, "pidfd_send_signal", None)
    wait_for_exit = wait_for_exit or _wait_for_exit
    close_pidfd = close_pidfd or os.close
    if pidfd_open is None or pidfd_send_signal is None:
        return False
    try:
        expected_identity = _load_exact_identity(identity_file, expected_uid)
        pid, recorded_start = _load_pid_record(pid_file, expected_uid)
        pidfd = pidfd_open(pid)
        identity = _validate_managed_process(
            proc_root=proc_root,
            home=home,
            codex_home=pid_file.parent.parent,
            pid=pid,
            recorded_start=recorded_start,
            expected_uid=expected_uid,
            clock_ticks=clock_ticks,
        )
        if identity != expected_identity:
            return False
        pidfd_send_signal(pidfd, signal.SIGTERM)
        return wait_for_exit(pidfd, 5)
    except (IndexError, KeyError, OSError, StopIteration, UnicodeError, ValueError):
        return False
    finally:
        if pidfd is not None:
            try:
                close_pidfd(pidfd)
            except OSError:
                pass


def _control_socket_peer(socket_path: Path) -> tuple[int, int, int]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect(str(socket_path))
        pid, uid, _ = struct.unpack(
            "3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        )
        # Linux SO_PEERPIDFD is 77 even on Python versions without the constant.
        # Unsupported kernels fail closed; a PID lookup cannot replace this handle.
        pidfd = client.getsockopt(socket.SOL_SOCKET, getattr(socket, "SO_PEERPIDFD", 77))
        return pid, uid, pidfd


def repair_pid_records(
    *,
    pid_file: Path,
    identity_file: Path,
    proc_root: Path,
    home: Path,
    expected_uid: int,
    clock_ticks: int,
    pidfd_open: Callable[[int], int] | None = None,
    socket_peer: Callable[[Path], tuple[int, int, int]] | None = None,
    pidfd_send_signal: Callable[[int, int], None] | None = None,
    close_pidfd: Callable[[int], None] | None = None,
) -> bool:
    """Restore missing native records after clock drift, without signaling termination."""

    pidfd_open = pidfd_open or getattr(os, "pidfd_open", None)
    socket_peer = socket_peer or _control_socket_peer
    pidfd_send_signal = pidfd_send_signal or getattr(signal, "pidfd_send_signal", None)
    close_pidfd = close_pidfd or os.close
    if pidfd_open is None or pidfd_send_signal is None:
        return False
    locks: list[int] = []
    pidfds: list[int] = []
    try:
        # Match native lock order, including the PID locks used by stale-record cleanup.
        for name in ("daemon.lock", "app-server.pid.lock", "app-server-updater.pid.lock"):
            fd = os.open(
                pid_file.parent / name,
                os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
            )
            locks.append(fd)
            metadata = os.fstat(fd)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != expected_uid:
                return False
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

        expected = _load_exact_identity(identity_file, expected_uid)
        updater_fd = pidfd_open(expected["pid"])
        pidfds.append(updater_fd)
        common = dict(
            proc_root=proc_root, home=home, codex_home=pid_file.parent.parent,
            recorded_start=None,
            expected_uid=expected_uid, clock_ticks=clock_ticks,
        )
        updater = _validate_managed_process(pid=expected["pid"], **common)
        # Wall-clock text can drift under WSL; these kernel fields cannot.
        if any(updater[key] != expected[key] for key in ("bootId", "pid", "startTicks")):
            return False

        server_pid, peer_uid, server_fd = socket_peer(
            pid_file.parent.parent / "app-server-control/app-server-control.sock"
        )
        pidfds.append(server_fd)
        if peer_uid != expected_uid or server_pid <= 1 or server_pid == expected["pid"]:
            return False
        server = _validate_managed_process(
            pid=server_pid,
            role=(b"app-server", b"--remote-control", b"--listen", b"unix://"),
            **common,
        )
        missing: list[tuple[Path, dict[str, object]]] = []
        for path, identity in (
            (pid_file, updater), (pid_file.parent / "app-server.pid", server)
        ):
            record = {key: identity[key] for key in ("pid", "processStartTime")}
            try:
                existing = _load_pid_record(path, expected_uid)
            except FileNotFoundError:
                if path.is_symlink():
                    return False
                missing.append((path, record))
            else:
                if existing != (record["pid"], record["processStartTime"]):
                    return False
        if not missing:
            return False
        # Both held handles must still be alive after all /proc and record reads.
        pidfd_send_signal(updater_fd, 0)
        pidfd_send_signal(server_fd, 0)
        for path, record in missing:
            _write_identity(path, record, expected_uid, create_only=True)
        return True
    except (IndexError, KeyError, OSError, StopIteration, UnicodeError, ValueError):
        return False
    finally:
        for fd in pidfds:
            try:
                close_pidfd(fd)
            except OSError:
                pass
        for fd in reversed(locks):
            os.close(fd)


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "probe":
        return probe_shared_server(Path(argv[2]))
    if len(argv) not in (2, 4) or argv[1] not in ("recover", "snapshot", "repair"):
        return 2
    home = Path.home()
    daemon_dir = home / ".codex/app-server-daemon"
    pid_file = Path(argv[2]) if len(argv) == 4 else daemon_dir / "app-server-updater.pid"
    identity_file = (
        Path(argv[3])
        if len(argv) == 4
        else daemon_dir / "app-server-updater.identity.json"
    )
    try:
        clock_ticks = os.sysconf("SC_CLK_TCK")
    except (OSError, ValueError):
        return 1
    common = {
        "pid_file": pid_file,
        "identity_file": identity_file,
        "proc_root": Path("/proc"),
        "home": home,
        "expected_uid": os.getuid(),
        "clock_ticks": clock_ticks,
    }
    actions = {"snapshot": snapshot_updater, "recover": terminate_stale_updater,
               "repair": repair_pid_records}
    succeeded = actions[argv[1]](**common)
    return 0 if succeeded else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
