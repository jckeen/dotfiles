#!/usr/bin/env python3
"""Run one native Claude Code print-mode turn from a prompt file, with evidence.

Built for an operator agent (Codex or any agent with a shell) that drives
Claude Code as the implementer. Invariants the mock suite pins:

- The prompt travels literally through stdin (bytes, UTF-8 validated, BOM
  stripped); it is never interpolated into a shell string or argv.
- The native executable is selected explicitly (~/.local/bin/claude or
  --claude-bin, never a PATH lookup) and recorded.
- Claude starts in the project directory even when the interactive Bash
  startup files cd elsewhere, because the cd runs after they load.
- Every streamed event, the exact session ID, and the final state land in a
  fresh run directory; existing run directories are never touched.
- Exit codes separate a completed turn, a failure, and a permission denial.
- --dry-run resolves inputs and prints the plan without creating files,
  launching Claude, or contacting its service.
- Stopping the runner (SIGINT/SIGTERM, or --timeout) terminates only the
  process group it owns and records the interrupted state. The leader stays
  unreaped until the last signal is sent, so the group id cannot be reused
  by a stranger while it is still a target (Linux procfs is required).

This wrapper is not an isolation boundary: Claude runs with the caller's
normal configuration, hooks, permissions, and credentials. No permission
bypass is exposed.
"""

from __future__ import annotations

import argparse
import array
from datetime import datetime, timezone
import fcntl
import json
import math
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import termios
import time
import uuid

PERMISSION_MODES = ("manual", "acceptEdits", "auto", "dontAsk", "plan")
# Claude's own stdin limit is higher; this catches a wrong --prompt-file (a
# binary, a repo dump) before anything launches.
MAX_PROMPT_BYTES = 9_000_000
UTF8_BOM = b"\xef\xbb\xbf"
EXIT_COMPLETE = 0
EXIT_FAILED = 1
EXIT_NEEDS_PERMISSION = 2
EXIT_USAGE = 64
EXIT_TIMED_OUT = 124
SIGNAL_EXIT_BASE = 128
STOP_GRACE_SECONDS = 10
UNKNOWN_OPTION_RE = re.compile(r"unknown option '?(--[A-Za-z][A-Za-z0-9-]*)")


class Interrupted(Exception):
    def __init__(self, signum: int):
        super().__init__(signal.Signals(signum).name)
        self.signum = signum


class TimedOut(Exception):
    pass


class Parser(argparse.ArgumentParser):
    # argparse exits 2 on usage errors, which would collide with the
    # needs-permission exit code an operator branches on.
    def error(self, message: str) -> None:  # type: ignore[override]
        self.print_usage(sys.stderr)
        self.exit(EXIT_USAGE, f"claude_run: {message}\n")


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def emit(event: dict) -> None:
    print(json.dumps(event, ensure_ascii=False), flush=True)


def arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = Parser(description="Run one native Claude Code print-mode turn from a prompt file.")
    parser.add_argument("--cwd", required=True, type=Path, help="project directory Claude works in")
    parser.add_argument("--prompt-file", required=True, type=Path, help="UTF-8 prompt, sent literally on stdin")
    parser.add_argument("--output-dir", required=True, type=Path, help="new directory for this turn's evidence")
    parser.add_argument("--resume", type=uuid.UUID, metavar="SESSION_ID", help="resume exactly this session")
    parser.add_argument("--claude-bin", type=Path, help="Claude executable (default: ~/.local/bin/claude; PATH is never searched)")
    parser.add_argument("--permission-mode", choices=PERMISSION_MODES, default="acceptEdits")
    parser.add_argument("--allow-tool", action="append", default=[], metavar="RULE",
                        help="permission rule to allow for this turn, e.g. 'Bash(bun test)' (repeatable)")
    parser.add_argument("--tools", help="restrict the built-in tool set, e.g. 'Read,Edit,Bash'")
    parser.add_argument("--model", help="model override; omit to keep the configured model")
    parser.add_argument("--timeout", type=float, metavar="SECONDS", help="stop the owned run after this long")
    parser.add_argument("--safe-mode", action="store_true",
                        help="launch with customizations disabled (troubleshooting only)")
    parser.add_argument("--dry-run", action="store_true", help="print the plan; create and launch nothing")
    args = parser.parse_args(argv)
    if args.timeout is not None and not (math.isfinite(args.timeout) and args.timeout > 0):
        parser.error("--timeout must be a finite, positive number of seconds")
    # Forwarded values become argv tokens after Claude's own options. A value
    # shaped like an option (`--allow-tool=--dangerously-skip-permissions`)
    # would be parsed by Claude as that option, smuggling a bypass past the
    # recorded permission mode. Flags inside a rule ("Bash(bun test --watch)")
    # are fine; only a leading dash is rejected.
    for option, values in (("--allow-tool", args.allow_tool), ("--tools", [args.tools]), ("--model", [args.model])):
        for value in values:
            if value is not None and value.startswith("-"):
                parser.error(f"{option} value {value!r} looks like a command-line option and is not forwarded")
    return args


def find_claude(explicit: Path | None) -> tuple[Path, str]:
    """Native install or an explicit path; never a PATH lookup. On WSL a bare
    `claude` on PATH can be the Windows npm shim (different config and auth),
    and silently switching to it is exactly what this selection prevents."""
    if explicit is not None:
        candidate, source = explicit.expanduser(), "--claude-bin"
    else:
        candidate, source = Path.home() / ".local" / "bin" / "claude", "native install (~/.local/bin/claude)"
        if not candidate.exists():
            raise ValueError(f"native Claude executable not found at {candidate}; the runner does not search PATH, "
                             "pass --claude-bin to use another installation")
    resolved = candidate.resolve(strict=True)
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ValueError(f"Claude executable is not an executable file: {resolved}")
    return resolved, source


def load_prompt(path: Path) -> bytes:
    # Read only up to the limit (plus an optional BOM and one overflow byte):
    # a wrongly selected huge file is rejected without ever being loaded.
    with path.open("rb") as handle:
        raw = handle.read(MAX_PROMPT_BYTES + len(UTF8_BOM) + 1)
    if raw.startswith(UTF8_BOM):
        raw = raw[len(UTF8_BOM):]
    if len(raw) > MAX_PROMPT_BYTES:
        raise ValueError(f"prompt exceeds the runner's {MAX_PROMPT_BYTES} byte stdin limit")
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"prompt file is not valid UTF-8: {error}") from error
    if not raw.strip():
        raise ValueError("prompt file is empty")
    return raw


def unsupported_flag(stderr_path: Path) -> str | None:
    try:
        with stderr_path.open("r", encoding="utf-8", errors="replace") as log:
            text = log.read(20_000)  # the diagnostic is at the top; never load the whole log
    except OSError:
        return None
    match = UNKNOWN_OPTION_RE.search(text)
    return match.group(1) if match else None


def shell_launch(events_fd: int, prompt_fd: int, cwd: Path, command: list[str]) -> list[str]:
    """Interactive Bash loads the user's startup files first (their PATH,
    version managers, aliases) with stdout pointed at the log and stdin at
    /dev/null: startup files may print (Ubuntu's /etc/bash.bashrc sudo hint, a
    banner) and may read (a `read` prompt), and neither may touch the
    stream-json evidence or eat part of the prompt. The -c body then reclaims
    the events pipe as stdout and the prompt file as stdin, cd's after the
    startup files so a ~/.bashrc that changes directory cannot move Claude out
    of the project, and execs Claude. The prompt is not part of this string or
    of "$@": Claude reads it from the descriptor."""
    body = (f'exec >&{events_fd} {events_fd}>&- <&{prompt_fd} {prompt_fd}<&-; '
            'cd -- "$1" || exit $?; shift; exec "$@"')
    return ["/bin/bash", "-ic", body, "claude-operator", str(cwd), *command]


def live_members(pgid: int) -> list[int]:
    """Running (non-zombie) processes in the group, read from Linux procfs.

    `killpg(pgid, 0)` cannot be used for this: it also answers for the zombie
    leader, which stop_owned keeps on purpose."""
    members = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat", encoding="ascii", errors="replace") as stat:
                fields = stat.read().rsplit(")", 1)[1].split()
        except (OSError, IndexError):
            continue  # exited between listing and reading
        if fields[0] not in ("Z", "X") and int(fields[2]) == pgid:
            members.append(int(entry))
    return members


def leader_exited(pid: int) -> bool:
    """True once the direct child has exited. WNOWAIT leaves it unreaped so
    its PID, and with it the group id, stays pinned until stop_owned is done."""
    return os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None


def queued_bytes(fd: int) -> int:
    """Bytes currently waiting in the pipe (Linux FIONREAD)."""
    counter = array.array("i", [0])
    fcntl.ioctl(fd, termios.FIONREAD, counter)
    return counter[0]


def stream_lines(fd: int, leader_pid: int):
    """Yield decoded lines from the events pipe until every writer closed it,
    or until the leader has exited and the bytes that were queued at that
    moment have been drained. The exit check runs on every iteration, whether
    or not bytes arrived, and the drain is bounded to that snapshot: a
    descendant that never stops writing cannot keep the turn open. Signals
    interrupt the wait and propagate as usual."""
    os.set_blocking(fd, False)
    buffer = b""

    def read_available(limit: int = 65536) -> bytes | None:
        try:
            return os.read(fd, limit)
        except BlockingIOError:
            return None

    def lines_from(chunk: bytes):
        nonlocal buffer
        buffer += chunk
        *lines, buffer = buffer.split(b"\n")
        for line in lines:
            yield line.decode("utf-8", errors="replace") + "\n"

    while True:
        ready, _, _ = select.select([fd], [], [], 0.1)
        chunk = read_available() if ready else None
        if chunk == b"":
            break
        if chunk:
            yield from lines_from(chunk)
        if leader_exited(leader_pid):
            remaining = queued_bytes(fd)
            while remaining > 0:
                chunk = read_available(min(remaining, 65536))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield from lines_from(chunk)
            break
    if buffer:
        yield buffer.decode("utf-8", errors="replace") + "\n"


def stop_owned(process: subprocess.Popen | None, state: dict) -> None:
    """Terminate the whole process group this runner started, and nothing else.

    The group is addressed by id, so a leader that already exited can still
    leave children behind (a Bash-tool child holding the events pipe open) that
    are the runner's to stop. The leader is deliberately NOT reaped until the
    last signal has been sent: its zombie keeps the PID, and therefore the
    group id, from being reused by an unrelated process while the runner still
    targets it. SIGTERM first; anything that ignores it is SIGKILLed after the
    grace period. Signalling errors and survivors are recorded in `state`
    rather than raised, so the final run.json is always written."""
    if process is None:
        return
    pgid = process.pid  # start_new_session=True made the leader its own group
    errors: list[str] = []

    def signal_group(signum: signal.Signals) -> None:
        try:
            os.killpg(pgid, signum)
        except ProcessLookupError:
            pass
        except OSError as error:
            errors.append(f"{signum.name}: {error}")

    try:
        if live_members(pgid):
            signal_group(signal.SIGTERM)
            deadline = time.monotonic() + STOP_GRACE_SECONDS
            while live_members(pgid) and time.monotonic() < deadline:
                time.sleep(0.1)
        if live_members(pgid):
            signal_group(signal.SIGKILL)
            deadline = time.monotonic() + 2
            while live_members(pgid) and time.monotonic() < deadline:
                time.sleep(0.05)
        survivors = live_members(pgid)
    finally:
        try:
            process.wait(timeout=STOP_GRACE_SECONDS)  # only now is the group id released
        except subprocess.TimeoutExpired:
            errors.append("leader still running after SIGKILL; left unreaped")
    if errors:
        state["stop_errors"] = errors
    if survivors:
        state["stop_survivors"] = survivors


def main(argv: list[str] | None = None) -> int:
    args = arguments(argv)
    if os.name != "posix" or not os.path.exists("/proc/self/stat"):
        raise ValueError("run this helper with Python inside WSL or Linux: it tracks the owned process group "
                         "through Linux procfs (/proc)")
    if os.environ.get("CLAUDECODE"):
        raise ValueError("refusing to launch Claude from inside a Claude Code session (CLAUDECODE is set); "
                         "an operator that is already Claude should use its native subagents and worktrees")
    cwd = args.cwd.resolve(strict=True)
    if not cwd.is_dir():
        raise ValueError(f"--cwd is not a directory: {cwd}")
    executable, executable_source = find_claude(args.claude_bin)
    prompt = load_prompt(args.prompt_file.resolve(strict=True))
    # Check the path as requested, before resolving: a dangling symlink there
    # would resolve to its absent target and be created through the link.
    requested = args.output_dir.expanduser()
    if requested.is_symlink() or requested.exists():
        raise ValueError(f"output directory already exists: {requested} (choose a new directory per turn; runs are never overwritten)")
    output = requested.resolve()
    if output.exists() or output.is_symlink():
        raise ValueError(f"output directory already exists: {output} (choose a new directory per turn; runs are never overwritten)")

    session_id = str(args.resume or uuid.uuid4())
    command = [str(executable), "--print", "--output-format", "stream-json", "--verbose",
               "--permission-mode", args.permission_mode, "--permission-prompts", "none",
               "--resume" if args.resume else "--session-id", session_id]
    if args.tools is not None:
        command.extend(["--tools", args.tools])
    if args.model:
        command.extend(["--model", args.model])
    if args.safe_mode:
        command.append("--safe-mode")
    if args.allow_tool:
        # Variadic on the Claude side; kept last so it cannot swallow later options.
        command.extend(["--allowedTools", *args.allow_tool])

    state = {
        "session_id": session_id,
        "resumed": args.resume is not None,
        "cwd": str(cwd),
        "output_dir": str(output),
        "claude_binary": str(executable),
        "claude_binary_source": executable_source,
        "permission_mode": args.permission_mode,
        "timeout_seconds": args.timeout,
        "runner_pid": os.getpid(),
        "status": "prepared",
        "shell": "interactive bash loads startup files (stdout to stderr.log, stdin /dev/null), then cd to cwd, "
                 "then exec claude with the prompt on stdin",
        "command": command,
    }
    if args.dry_run:
        emit({"event": "dry_run", **state})
        return EXIT_COMPLETE

    output.mkdir(parents=True, exist_ok=False)
    prompt_path = output / "prompt.txt"
    prompt_path.write_bytes(prompt)
    state.update(status="starting", started_at=now())
    write_json(output / "run.json", state)

    # Only the first termination signal (or the alarm) unwinds the run. Later
    # ones arrive while stop_owned is still waiting out a TERM-ignoring child;
    # raising then would abandon the group and leave run.json at "running".
    # While `deferring`, a signal is parked instead of raised: it arrived
    # between Popen creating the child and the runner taking ownership of it,
    # and raising there would orphan a live Claude with no recorded group.
    stopping = False
    deferring = False
    pending: signal.Signals | None = None

    def on_signal(signum, _frame):
        nonlocal stopping, pending
        if stopping:
            return
        if deferring:
            pending = pending or signal.Signals(signum)
            return
        stopping = True
        raise Interrupted(signum)

    def on_alarm(_signum, _frame):
        nonlocal stopping
        if stopping or deferring:
            return
        stopping = True
        raise TimedOut()

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, on_signal)
    signal.signal(signal.SIGALRM, on_alarm)

    process: subprocess.Popen | None = None
    result: dict | None = None
    return_code = EXIT_FAILED
    torn_down = False

    def teardown() -> None:
        """Stop the owned group exactly once; non-raising on every path until
        run.json is final. Runs at normal completion too, so a descendant that
        closed stdout and lingered does not outlive the run, and so the
        leader's exit code is read only after the group id is no longer needed."""
        nonlocal torn_down, stopping
        # Non-raising first: a signal landing before this store raises out of
        # here before the idempotence marker is set, so the caller's retry
        # loop runs the cleanup; a signal after it can only be ignored.
        stopping = True
        if torn_down:
            return
        torn_down = True
        signal.setitimer(signal.ITIMER_REAL, 0)
        stop_owned(process, state)

    def handle_line(line: str) -> None:
        nonlocal result
        events.write(line)
        events.flush()
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            return
        if not isinstance(event, dict):
            return
        if event.get("type") == "result":
            result = event
            write_json(output / "result.json", result)
        elif event.get("type") == "assistant":
            # Progress is best-effort: a malformed assistant event must
            # not stop the loop from reaching a later valid result.
            message = event.get("message")
            content = message.get("content") if isinstance(message, dict) else None
            for block in content if isinstance(content, list) else []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    emit({"event": "progress", "text": str(block.get("text", ""))[:1400]})
                elif block.get("type") == "tool_use":
                    emit({"event": "tool", "name": block.get("name")})

    try:
        with (output / "stderr.log").open("w", encoding="utf-8") as errors, \
             (output / "events.jsonl").open("w", encoding="utf-8") as events:
            events_read, events_write = os.pipe()
            prompt_fd = os.open(prompt_path, os.O_RDONLY)
            # Deferred from just before the child can exist until its group is
            # on disk, so a cancel in that window can neither orphan Claude
            # nor leave the final state without the group's identity.
            deferring = True
            try:
                process = subprocess.Popen(shell_launch(events_write, prompt_fd, cwd, command), cwd=cwd,
                                           stdin=subprocess.DEVNULL, stdout=errors, stderr=errors,
                                           pass_fds=(events_write, prompt_fd), start_new_session=True)
            except BaseException:
                os.close(events_read)  # nobody will read it; the normal path closes it after streaming
                raise
            finally:
                os.close(events_write)
                os.close(prompt_fd)
            state.update(status="running", claude_process_group=process.pid)
            write_json(output / "run.json", state)
            deferring = False
            if pending is not None:
                stopping = True
                raise Interrupted(pending)
            if args.timeout is not None:
                signal.setitimer(signal.ITIMER_REAL, args.timeout)
            emit({"event": "started", **state})
            # Completion is the direct child's exit (peeked without reaping),
            # not the pipe's EOF: a background job from ~/.bashrc inherits the
            # events descriptor and can hold it open long after Claude has
            # written its result and exited. Everything already in the pipe is
            # drained before teardown stops such stragglers.
            try:
                for line in stream_lines(events_read, process.pid):
                    handle_line(line)
            finally:
                os.close(events_read)
            # Closing stdout is not exiting: Claude may still be finishing its
            # own cleanup after the last event. Wait for the exit itself
            # (still unreaped) with the turn timeout and signals live, so a
            # hung child with a closed pipe times out instead of being killed
            # for merely going quiet.
            while not leader_exited(process.pid):
                time.sleep(0.05)
            teardown()
            return_code = process.returncode
        # Success means success for the exact requested session; a result that
        # names another session, or none at all, is not that.
        if result and result.get("session_id") != session_id:
            state.update(status="session_mismatch", actual_session_id=result.get("session_id"))
            return_code = EXIT_FAILED
        # A nonzero Claude exit is a failure even when the result carries
        # permission denials: a process error must not be read as a mere
        # approval need. needs_permission is reserved for a completed turn.
        elif not result or result.get("is_error") or result.get("subtype") != "success" or return_code:
            state["status"] = "failed"
            flag = unsupported_flag(output / "stderr.log")
            if flag:
                state.update(unsupported_flag=flag,
                             error=f"the installed Claude CLI rejected {flag}; upgrade Claude Code rather than "
                                   "dropping it, the runner never retries with weaker permission handling")
            elif not result:
                state["error"] = "Claude exited without a result event (see stderr.log)"
            # Claude's raw exit code is kept as claude_exit_code; the runner's
            # own code must not collide with 2/124/130 from the public contract.
            return_code = EXIT_FAILED
        elif result.get("permission_denials"):
            state["status"] = "needs_permission"
            return_code = EXIT_NEEDS_PERMISSION
        else:
            state["status"] = "turn_complete"
            return_code = EXIT_COMPLETE
        # A turn whose owned processes could not all be stopped is neither a
        # clean success nor a safe place to resume from, whatever Claude's
        # result said; the result (denials included) stays in result.json.
        if state["status"] in ("turn_complete", "needs_permission") \
                and (state.get("stop_errors") or state.get("stop_survivors")):
            state.update(status="failed", error="Claude's turn ended but owned processes were not stopped "
                                                "cleanly (see stop_errors / stop_survivors); do not resume "
                                                "until they are gone")
            return_code = EXIT_FAILED
    except Interrupted as interrupt:
        state.update(status="interrupted", interrupted_by=str(interrupt))
        return_code = SIGNAL_EXIT_BASE + interrupt.signum
    except TimedOut:
        state.update(status="timed_out", error=f"no result within {args.timeout} seconds; owned run stopped")
        return_code = EXIT_TIMED_OUT
    except Exception as error:  # noqa: BLE001 - recorded, never silently dropped
        state.update(status="failed", error=f"{type(error).__name__}: {error}")
        return_code = EXIT_FAILED
    finally:
        while True:
            try:
                teardown()
                break
            except (Interrupted, TimedOut):
                continue  # beat teardown to its non-raising marker; the group is still owned, retry
            except Exception as error:  # noqa: BLE001 - evidence beats a clean traceback here
                state["teardown_error"] = f"{type(error).__name__}: {error}"
                break
        if process is not None:
            state["claude_exit_code"] = process.returncode
        state.update(finished_at=now(), exit_code=return_code)
        write_json(output / "run.json", state)
    emit({"event": "finished", "status": state["status"], "exit_code": return_code,
          "session_id": session_id, "output_dir": str(output),
          "error": state.get("error"), "result": result.get("result") if result else None})
    return return_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"claude_run: {error}", file=sys.stderr)
        sys.exit(EXIT_FAILED)
