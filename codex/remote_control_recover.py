#!/usr/bin/env python3
"""Snapshot and recover only an exactly identified managed Codex updater."""

from __future__ import annotations

import json
import os
from pathlib import Path
import select
import signal
import stat
import sys
import tempfile
import time
from typing import Callable


MAX_RECORD_BYTES = 4096
MAX_CMDLINE_BYTES = 4096
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
    proc_stat = _read_bounded(proc_root / "stat", MAX_RECORD_BYTES).decode("ascii")
    boot_time = next(
        int(line.split()[1])
        for line in proc_stat.splitlines()
        if line.startswith("btime ")
    )
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


def _managed_executable(proc_root: Path, pid: int, home: Path) -> Path:
    executable = (proc_root / str(pid) / "exe").resolve(strict=True)
    releases = (home / ".codex/packages/standalone/releases").resolve(strict=True)
    relative = executable.relative_to(releases)
    if len(relative.parts) != 3 or relative.parts[1:] != ("bin", "codex"):
        raise ValueError("executable is outside a managed release")
    return executable


def _validate_managed_process(
    *,
    proc_root: Path,
    home: Path,
    pid: int,
    recorded_start: str,
    expected_uid: int,
    clock_ticks: int,
) -> dict[str, object]:
    process_dir = proc_root / str(pid)
    if process_dir.stat().st_uid != expected_uid:
        raise ValueError("process owner is invalid")
    identity = _process_identity(proc_root, pid, clock_ticks)
    if identity["processStartTime"] != recorded_start:
        raise ValueError("process display time does not match")

    executable = _managed_executable(proc_root, pid, home)
    cmdline = _read_bounded(process_dir / "cmdline", MAX_CMDLINE_BYTES)
    if not cmdline.endswith(b"\0"):
        raise ValueError("process command line does not match")
    arguments = cmdline[:-1].split(b"\0")
    if len(arguments) != 4:
        raise ValueError("process argument count does not match")
    argv_zero = Path(os.fsdecode(arguments[0]))
    if not argv_zero.is_absolute() or argv_zero.resolve(strict=True) != executable:
        raise ValueError("process argv zero does not resolve to its executable")
    if arguments[1:] != [b"app-server", b"daemon", b"pid-update-loop"]:
        raise ValueError("process role arguments do not match")
    return identity


def _write_identity(
    identity_file: Path, identity: dict[str, object], expected_uid: int
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


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 4) or argv[1] not in ("recover", "snapshot"):
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
    succeeded = (
        snapshot_updater(**common)
        if argv[1] == "snapshot"
        else terminate_stale_updater(**common)
    )
    return 0 if succeeded else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
