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
  process group it owns and records the interrupted state.

This wrapper is not an isolation boundary: Claude runs with the caller's
normal configuration, hooks, permissions, and credentials. No permission
bypass is exposed.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

PERMISSION_MODES = ("manual", "acceptEdits", "auto", "dontAsk", "plan")
# Claude's own stdin limit is higher; this catches a wrong --prompt-file (a
# binary, a repo dump) before anything launches.
MAX_PROMPT_BYTES = 9_000_000
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
    if args.timeout is not None and args.timeout <= 0:
        parser.error("--timeout must be a positive number of seconds")
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
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"prompt file is not valid UTF-8: {error}") from error
    if not raw.strip():
        raise ValueError("prompt file is empty")
    if len(raw) > MAX_PROMPT_BYTES:
        raise ValueError(f"prompt exceeds the runner's {MAX_PROMPT_BYTES} byte stdin limit")
    return raw


def unsupported_flag(stderr_path: Path) -> str | None:
    try:
        text = stderr_path.read_text(encoding="utf-8", errors="replace")[:20_000]
    except OSError:
        return None
    match = UNKNOWN_OPTION_RE.search(text)
    return match.group(1) if match else None


def shell_launch(events_fd: int, cwd: Path, command: list[str]) -> list[str]:
    """Interactive Bash loads the user's startup files first (their PATH,
    version managers, aliases), while its stdout points at the log: startup
    files may print (Ubuntu's /etc/bash.bashrc sudo hint, a ~/.bashrc banner)
    and that must not land in the stream-json evidence. The -c body then
    reclaims the events pipe as stdout, cd's after the startup files so a
    ~/.bashrc that changes directory cannot move Claude out of the project,
    and execs Claude. The prompt is not part of this string or of "$@": it
    arrives on stdin."""
    body = f'exec >&{events_fd} {events_fd}>&-; cd -- "$1" || exit $?; shift; exec "$@"'
    return ["/bin/bash", "-ic", body, "claude-operator", str(cwd), *command]


def group_alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def stop_owned(process: subprocess.Popen | None) -> None:
    """Terminate the whole process group this runner started.

    The group is addressed by its id, not through the leader: a leader that
    already exited can leave children behind (a Bash-tool child holding the
    events pipe open, for instance), and those are still the runner's to stop.
    SIGTERM first; anything that ignores it is SIGKILLed after the grace period.
    Nothing outside the group is touched."""
    if process is None:
        return
    pgid = process.pid  # start_new_session=True made the leader its own group
    process.poll()  # reap the leader if it already exited so it stops counting as a member
    if group_alive(pgid):
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + STOP_GRACE_SECONDS
        while group_alive(pgid) and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.1)
    if group_alive(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 2
        while group_alive(pgid) and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.05)
    if process.poll() is None:
        process.wait()


def main(argv: list[str] | None = None) -> int:
    args = arguments(argv)
    if os.name != "posix":
        raise ValueError("run this helper with Python inside WSL/Linux/macOS, not Windows Python")
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
        "shell": "interactive bash loads startup files (stdout to stderr.log), then cd to cwd, then exec claude",
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

    def on_signal(signum, _frame):
        raise Interrupted(signum)

    def on_alarm(_signum, _frame):
        raise TimedOut()

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, on_signal)
    signal.signal(signal.SIGALRM, on_alarm)

    process: subprocess.Popen | None = None
    result: dict | None = None
    return_code = EXIT_FAILED
    try:
        events_read, events_write = os.pipe()
        with (output / "stderr.log").open("w", encoding="utf-8") as errors, \
             (output / "events.jsonl").open("w", encoding="utf-8") as events, \
             prompt_path.open("rb") as prompt_input, \
             os.fdopen(events_read, "r", encoding="utf-8", errors="replace") as stream:
            try:
                process = subprocess.Popen(shell_launch(events_write, cwd, command), cwd=cwd,
                                           stdin=prompt_input, stdout=errors, stderr=errors,
                                           pass_fds=(events_write,), start_new_session=True)
            finally:
                os.close(events_write)
            if args.timeout is not None:
                signal.setitimer(signal.ITIMER_REAL, args.timeout)
            state.update(status="running", claude_process_group=process.pid)
            write_json(output / "run.json", state)
            emit({"event": "started", **state})
            for line in stream:
                events.write(line)
                events.flush()
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(event, dict):
                    continue
                if event.get("type") == "result":
                    result = event
                    write_json(output / "result.json", result)
                elif event.get("type") == "assistant":
                    for block in event.get("message", {}).get("content", []):
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "text":
                            emit({"event": "progress", "text": str(block.get("text", ""))[:1400]})
                        elif block.get("type") == "tool_use":
                            emit({"event": "tool", "name": block.get("name")})
            return_code = process.wait()
            signal.setitimer(signal.ITIMER_REAL, 0)
        # Success means success for the exact requested session; a result that
        # names another session, or none at all, is not that.
        if result and result.get("session_id") != session_id:
            state.update(status="session_mismatch", actual_session_id=result.get("session_id"))
            return_code = EXIT_FAILED
        elif not result or result.get("is_error") or result.get("subtype") != "success" or return_code:
            state["status"] = "failed"
            flag = unsupported_flag(output / "stderr.log")
            if flag:
                state.update(unsupported_flag=flag,
                             error=f"the installed Claude CLI rejected {flag}; upgrade Claude Code rather than "
                                   "dropping it, the runner never retries with weaker permission handling")
            elif not result:
                state["error"] = "Claude exited without a result event (see stderr.log)"
            return_code = return_code or EXIT_FAILED
        elif result.get("permission_denials"):
            state["status"] = "needs_permission"
            return_code = EXIT_NEEDS_PERMISSION
        else:
            state["status"] = "turn_complete"
            return_code = EXIT_COMPLETE
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
        signal.setitimer(signal.ITIMER_REAL, 0)
        stop_owned(process)
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
