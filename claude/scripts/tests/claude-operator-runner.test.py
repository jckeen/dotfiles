#!/usr/bin/env python3
"""Offline mock suite for agents/skills/claude-operator/scripts/claude_run.py.

A stub `claude` (a Python script) stands in for the real CLI, HOME points at a
throwaway directory with a crafted ~/.bashrc, and the child environment is
built from scratch, so the suite never launches the real model, needs no auth,
and inherits none of the developer's shell startup side effects. Standard
library only. Run directly: python3 claude/scripts/tests/claude-operator-runner.test.py
"""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

RUNNER = Path(__file__).resolve().parents[3] / "agents/skills/claude-operator/scripts/claude_run.py"


def load_runner_module():
    """Import the runner for in-process tests that need to observe its syscalls."""
    spec = importlib.util.spec_from_file_location("claude_run_under_test", RUNNER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

FAKE_CLAUDE = f'''#!{sys.executable}
import json, os, subprocess, sys, time
args = sys.argv[1:]
mode = os.environ.get("FAKE_CLAUDE_MODE", "success")
if mode == "unknown_flag":
    sys.stderr.write("error: unknown option '--permission-prompts'\\n")
    sys.exit(1)
flag = "--resume" if "--resume" in args else "--session-id"
sid = args[args.index(flag) + 1]
prompt = sys.stdin.buffer.read()
with open(os.environ["FAKE_CLAUDE_RECORD"], "a", encoding="utf-8") as record:
    record.write(json.dumps({{"prompt": prompt.decode("utf-8"), "args": args, "cwd": os.getcwd(),
                             "rc_marker": os.environ.get("OPERATOR_TEST_RC")}}) + "\\n")
def emit(obj):
    print(json.dumps(obj), flush=True)
emit({{"type": "system", "subtype": "init", "session_id": sid}})
emit({{"type": "assistant", "message": {{"content": [{{"type": "text", "text": "working"}},
                                                    {{"type": "tool_use", "name": "Read"}}]}}}})
if mode == "hang":
    child = subprocess.Popen(["sleep", "300"])
    emit({{"type": "assistant", "message": {{"content": [{{"type": "text", "text": "PIDS " + json.dumps([os.getpid(), child.pid])}}]}}}})
    time.sleep(300)
if mode == "hang_ignore_term":
    # The child survives SIGTERM and writes a marker when it arrives, so a test
    # knows the runner's teardown has begun; the leader hangs until stopped.
    child = subprocess.Popen([sys.executable, "-c",
        "import os, signal, time\\n"
        "def mark(*_): open(os.environ['FAKE_CLAUDE_TERM_MARKER'], 'w').close()\\n"
        "signal.signal(signal.SIGTERM, mark)\\n"
        "open(os.environ['FAKE_CLAUDE_TERM_MARKER'] + '.ready', 'w').close()\\n"
        "while True: time.sleep(0.1)"])
    while not os.path.exists(os.environ["FAKE_CLAUDE_TERM_MARKER"] + ".ready"):
        time.sleep(0.02)  # the handler must be installed before anyone signals the group
    emit({{"type": "assistant", "message": {{"content": [{{"type": "text", "text": "PIDS " + json.dumps([os.getpid(), child.pid])}}]}}}})
    time.sleep(300)
if mode == "close_stdout_then_cleanup":
    emit({{"type": "result", "subtype": "success", "is_error": False, "session_id": sid,
          "permission_denials": [], "result": "done"}})
    os.close(1)
    time.sleep(0.5)  # Claude-side cleanup after its last event
    open(os.environ["FAKE_CLAUDE_MARKER"], "w").close()
    sys.exit(0)
if mode == "close_stdout_hang":
    os.close(1)
    time.sleep(300)
if mode == "success_with_chatty_child":
    # Inherits the events pipe and never stops writing to it.
    child = subprocess.Popen(["yes", "noise"])
    emit({{"type": "assistant", "message": {{"content": [{{"type": "text", "text": "PIDS " + json.dumps([os.getpid(), child.pid])}}]}}}})
    emit({{"type": "result", "subtype": "success", "is_error": False, "session_id": sid,
          "permission_denials": [], "result": "done"}})
    sys.exit(0)
if mode == "denied_with_surviving_child":
    child = subprocess.Popen([sys.executable, "-c",
        "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"])
    emit({{"type": "assistant", "message": {{"content": [{{"type": "text", "text": "PIDS " + json.dumps([os.getpid(), child.pid])}}]}}}})
    emit({{"type": "result", "subtype": "success", "is_error": False, "session_id": sid,
          "permission_denials": [{{"tool_name": "Bash", "tool_input": {{"command": "bun test"}}}}], "result": "done"}})
    sys.exit(0)
if mode == "success_with_surviving_child":
    child = subprocess.Popen([sys.executable, "-c",
        "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"])
    emit({{"type": "assistant", "message": {{"content": [{{"type": "text", "text": "PIDS " + json.dumps([os.getpid(), child.pid])}}]}}}})
    emit({{"type": "result", "subtype": "success", "is_error": False, "session_id": sid,
          "permission_denials": [], "result": "done"}})
    sys.exit(0)
if mode == "malformed_progress":
    emit({{"type": "assistant", "message": None}})
    emit({{"type": "assistant", "message": {{"content": "not a list"}}}})
    emit({{"type": "assistant", "message": {{"content": ["not a block", {{"type": "text", "text": "still here"}}]}}}})
if mode == "exit_code":
    sys.exit(int(os.environ["FAKE_CLAUDE_EXIT"]))
if mode == "orphan":
    # A child that ignores SIGTERM and keeps the inherited stdout open; the
    # leader then exits, so the group outlives its leader.
    child = subprocess.Popen([sys.executable, "-c",
        "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"])
    emit({{"type": "assistant", "message": {{"content": [{{"type": "text", "text": "PIDS " + json.dumps([os.getpid(), child.pid])}}]}}}})
    sys.exit(0)
if mode == "no_result":
    sys.exit(0)
result = {{"type": "result", "subtype": "success", "is_error": False, "session_id": sid,
          "permission_denials": [], "result": "done"}}
if mode == "denied":
    result["permission_denials"] = [{{"tool_name": "Bash", "tool_input": {{"command": "bun test"}}}}]
elif mode == "error":
    result.update(subtype="error_during_execution", is_error=True)
    emit(result)
    sys.exit(1)
elif mode == "mismatch":
    result["session_id"] = "00000000-0000-4000-8000-000000000000"
elif mode == "no_session_id":
    del result["session_id"]
elif mode == "denied_then_exit_1":
    result["permission_denials"] = [{{"tool_name": "Bash", "tool_input": {{"command": "bun test"}}}}]
    emit(result)
    sys.exit(1)
emit(result)
'''

LITERAL_PROMPT = 'Keep "quotes", $HOME, $(touch never), `ticks`, \\backslash, café, 日本語\r\nand CRLF + newlines.\n'


def is_alive(pid):
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except FileNotFoundError:
        return False
    except OSError:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True
    return stat.rsplit(")", 1)[1].split()[0] != "Z"


def wait_dead(pids, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not any(is_alive(p) for p in pids):
            return True
        time.sleep(0.1)
    return False


def group_members(pgid):
    """Running (non-zombie) processes whose process group is pgid, via /proc."""
    members = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            fields = Path(f"/proc/{entry}/stat").read_text().rsplit(")", 1)[1].split()
        except (OSError, IndexError):
            continue
        if fields[0] not in ("Z", "X") and int(fields[2]) == pgid:
            members.append(int(entry))
    return members


def wait_group_empty(pgid, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not group_members(pgid):
            return True
        time.sleep(0.1)
    return False


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="claude-operator-test-")
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        (self.home / ".local" / "bin").mkdir(parents=True)
        self.project = self.base / "project"
        self.project.mkdir()
        (self.base / "elsewhere").mkdir()
        # The crafted startup file proves it ran, prints a banner the way login
        # banners and /etc/bash.bashrc hints do, tries to read stdin the way an
        # interactive prompt would, and tries to move Claude away.
        (self.home / ".bashrc").write_text(
            f'export OPERATOR_TEST_RC=loaded\necho STARTUP_BANNER\n'
            f'IFS= read -r STARTUP_INPUT\necho "STARTUP_READ=[$STARTUP_INPUT]"\ncd "{self.base}/elsewhere"\n')
        self.fake = self.base / "fake-claude"
        self.fake.write_text(FAKE_CLAUDE, encoding="utf-8")
        self.fake.chmod(0o700)
        self.record = self.base / "received.jsonl"
        self.prompt = self.base / "prompt.txt"
        self.prompt.write_bytes(LITERAL_PROMPT.encode("utf-8"))
        self.out = self.base / "runs" / "run-01"

    def tearDown(self):
        self.temp.cleanup()

    def env(self, mode="success", **extra):
        env = {
            "PATH": os.pathsep.join([str(Path(sys.executable).parent), "/usr/local/bin", "/usr/bin", "/bin"]),
            "HOME": str(self.home),
            "LC_ALL": "C.UTF-8",
            "FAKE_CLAUDE_MODE": mode,
            "FAKE_CLAUDE_RECORD": str(self.record),
        }
        env.update(extra)
        return env

    def command(self, *extra, claude_bin=True):
        cmd = [sys.executable, str(RUNNER), "--cwd", str(self.project),
               "--prompt-file", str(self.prompt), "--output-dir", str(self.out)]
        if claude_bin:
            cmd += ["--claude-bin", str(self.fake)]
        return cmd + list(extra)

    def run_turn(self, *extra, mode="success", claude_bin=True, **env_extra):
        return subprocess.run(self.command(*extra, claude_bin=claude_bin), capture_output=True,
                              text=True, env=self.env(mode, **env_extra), timeout=60)

    def run_in_process(self, *extra, mode="success", **env_extra):
        """Run main() inside this interpreter so a test can observe or fail the
        runner's syscalls. The child environment is still built from scratch;
        the runner's signal handlers are restored afterwards."""
        module = load_runner_module()
        handled = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGALRM)
        saved = {s: signal.getsignal(s) for s in handled}
        stdout = io.StringIO()
        argv = self.command(*extra)[2:]
        try:
            with mock.patch.dict(os.environ, self.env(mode, **env_extra), clear=True), \
                 contextlib.redirect_stdout(stdout):
                rc = module.main(argv)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            for s, handler in saved.items():
                signal.signal(s, handler)
        return rc, stdout.getvalue()

    @contextlib.contextmanager
    def signal_inside_teardown(self, at_line_events):
        """Send SIGINT to this process at chosen statement boundaries inside the
        runner's teardown(), via a trace function scoped to that frame. A
        signal raised there surfaces exactly between two statements."""
        seen = []

        def local_tracer(frame, event, _arg):
            if event == "line":
                seen.append(frame.f_lineno)
                if at_line_events(len(seen)):
                    os.kill(os.getpid(), signal.SIGINT)
            return local_tracer

        def global_tracer(frame, event, _arg):
            if event == "call" and frame.f_code.co_name == "teardown" \
                    and Path(frame.f_code.co_filename).resolve() == RUNNER.resolve():
                return local_tracer
            return None

        sys.settrace(global_tracer)
        try:
            yield seen
        finally:
            sys.settrace(None)

    def pids_from(self, stdout):
        for line in stdout.splitlines():
            event = json.loads(line)
            if event.get("event") == "progress" and event["text"].startswith("PIDS "):
                return json.loads(event["text"][5:])
        self.fail("stub never reported its pids")

    def received(self):
        if not self.record.exists():
            return []
        return [json.loads(line) for line in self.record.read_text(encoding="utf-8").splitlines()]

    def state(self):
        return json.loads((self.out / "run.json").read_text(encoding="utf-8"))

    def events(self, outcome):
        return [json.loads(line) for line in outcome.stdout.splitlines()]

    # ── success, evidence, session ──────────────────────────────────────
    def test_success_records_streamed_evidence_and_exact_session(self):
        outcome = self.run_turn()
        self.assertEqual(outcome.returncode, 0, outcome.stderr + outcome.stdout)
        state = self.state()
        self.assertEqual(state["status"], "turn_complete")
        self.assertFalse(state["resumed"])
        uuid.UUID(state["session_id"])
        received = self.received()
        self.assertEqual(len(received), 1)
        args = received[0]["args"]
        self.assertEqual(args[args.index("--session-id") + 1], state["session_id"])
        self.assertIn("--print", args)
        self.assertEqual(args[args.index("--permission-mode") + 1], "acceptEdits")
        self.assertEqual(args[args.index("--permission-prompts") + 1], "none")
        self.assertEqual((self.out / "prompt.txt").read_bytes(), LITERAL_PROMPT.encode("utf-8"))
        self.assertEqual(json.loads((self.out / "result.json").read_text())["session_id"], state["session_id"])
        event_types = [json.loads(l)["type"] for l in (self.out / "events.jsonl").read_text().splitlines()]
        self.assertEqual(event_types, ["system", "assistant", "result"])
        kinds = [e["event"] for e in self.events(outcome)]
        self.assertEqual(kinds, ["started", "progress", "tool", "finished"])
        self.assertEqual(self.events(outcome)[-1]["status"], "turn_complete")
        self.assertEqual(state["claude_binary_source"], "--claude-bin")

    def test_prompt_is_transported_literally_on_stdin(self):
        with_bom = b"\xef\xbb\xbf" + LITERAL_PROMPT.encode("utf-8")
        self.prompt.write_bytes(with_bom)
        outcome = self.run_turn("--allow-tool", "Read", "--allow-tool", "Bash(bun test)", "--tools", "Read,Edit")
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        received = self.received()[0]
        self.assertEqual(received["prompt"], LITERAL_PROMPT)
        self.assertFalse((self.project / "never").exists())
        self.assertFalse((self.base / "never").exists())
        self.assertNotIn(LITERAL_PROMPT.strip(), " ".join(received["args"]))
        args = received["args"]
        self.assertEqual(args.count("--allowedTools"), 1)
        self.assertEqual(args[args.index("--allowedTools"):], ["--allowedTools", "Read", "Bash(bun test)"])
        self.assertEqual(args[args.index("--tools") + 1], "Read,Edit")

    def test_cwd_is_restored_after_shell_startup_files(self):
        outcome = self.run_turn()
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        received = self.received()[0]
        self.assertEqual(received["rc_marker"], "loaded")
        self.assertEqual(Path(received["cwd"]).resolve(), self.project.resolve())
        self.assertNotIn("STARTUP_BANNER", (self.out / "events.jsonl").read_text())
        self.assertIn("STARTUP_BANNER", (self.out / "stderr.log").read_text())
        self.assertNotIn("STARTUP_BANNER", outcome.stdout)

    def test_startup_files_cannot_consume_the_prompt(self):
        outcome = self.run_turn()
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        # The startup `read` ran (proof it was exercised) but saw nothing;
        # Claude still received every byte of the prompt.
        self.assertIn("STARTUP_READ=[]", (self.out / "stderr.log").read_text())
        self.assertEqual(self.received()[0]["prompt"], LITERAL_PROMPT)

    def test_exact_resume_passes_the_requested_session(self):
        sid = str(uuid.uuid4())
        outcome = self.run_turn("--resume", sid)
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        args = self.received()[0]["args"]
        self.assertNotIn("--session-id", args)
        self.assertNotIn("--continue", args)
        self.assertEqual(args[args.index("--resume") + 1], sid)
        state = self.state()
        self.assertTrue(state["resumed"])
        self.assertEqual(state["session_id"], sid)

    def test_session_mismatch_is_not_success(self):
        outcome = self.run_turn("--resume", str(uuid.uuid4()), mode="mismatch")
        self.assertEqual(outcome.returncode, 1)
        state = self.state()
        self.assertEqual(state["status"], "session_mismatch")
        self.assertEqual(state["actual_session_id"], "00000000-0000-4000-8000-000000000000")

    def test_success_result_without_session_id_is_not_success(self):
        outcome = self.run_turn(mode="no_session_id")
        self.assertEqual(outcome.returncode, 1, outcome.stdout)
        state = self.state()
        self.assertEqual(state["status"], "session_mismatch")
        self.assertIsNone(state["actual_session_id"])
        self.assertEqual(self.events(outcome)[-1]["status"], "session_mismatch")

    # ── distinct failure states ─────────────────────────────────────────
    def test_permission_denial_is_a_distinct_state(self):
        outcome = self.run_turn(mode="denied")
        self.assertEqual(outcome.returncode, 2, outcome.stdout + outcome.stderr)
        self.assertEqual(self.state()["status"], "needs_permission")
        denials = json.loads((self.out / "result.json").read_text())["permission_denials"]
        self.assertEqual(denials[0]["tool_name"], "Bash")

    def test_missing_result_is_failure(self):
        outcome = self.run_turn(mode="no_result")
        self.assertEqual(outcome.returncode, 1)
        state = self.state()
        self.assertEqual(state["status"], "failed")
        self.assertIn("without a result", state["error"])

    def test_error_result_is_failure(self):
        outcome = self.run_turn(mode="error")
        self.assertEqual(outcome.returncode, 1)
        self.assertEqual(self.state()["status"], "failed")
        self.assertEqual(self.state()["claude_exit_code"], 1)

    def test_reserved_child_exit_codes_do_not_leak_into_the_runner_contract(self):
        for code in (2, 64, 124, 130, 143):
            self.out = self.base / "runs" / f"exit-{code}"
            outcome = self.run_turn(mode="exit_code", FAKE_CLAUDE_EXIT=str(code))
            self.assertEqual(outcome.returncode, 1, f"child exit {code} leaked as the runner exit code")
            state = self.state()
            self.assertEqual(state["status"], "failed")
            self.assertEqual(state["claude_exit_code"], code)
            self.assertEqual(state["exit_code"], 1)

    def test_malformed_progress_events_do_not_hide_a_later_result(self):
        outcome = self.run_turn(mode="malformed_progress")
        self.assertEqual(outcome.returncode, 0, outcome.stderr + outcome.stdout)
        self.assertEqual(self.state()["status"], "turn_complete")
        texts = [e["text"] for e in self.events(outcome) if e["event"] == "progress"]
        self.assertEqual(texts, ["working", "still here"])

    def test_unsupported_flag_is_reported_not_worked_around(self):
        outcome = self.run_turn(mode="unknown_flag")
        self.assertEqual(outcome.returncode, 1)
        state = self.state()
        self.assertEqual(state["status"], "failed")
        self.assertEqual(state["unsupported_flag"], "--permission-prompts")
        self.assertEqual(self.received(), [], "runner must not retry with weaker settings")
        self.assertIn("--permission-prompts", self.events(outcome)[-1]["error"])

    # ── no bypass, no recursion ─────────────────────────────────────────
    def test_bypass_flags_are_not_exposed(self):
        for flag in (["--permission-mode", "bypassPermissions"], ["--dangerously-skip-permissions"], ["--bare"]):
            outcome = self.run_turn(*flag)
            self.assertEqual(outcome.returncode, 64, flag)
            self.assertEqual(self.received(), [])
            self.assertFalse(self.out.exists())

    def test_option_shaped_forwarded_values_are_rejected(self):
        injections = (
            ["--allow-tool", "Read", "--allow-tool=--dangerously-skip-permissions"],
            ["--allow-tool=--permission-mode", "--allow-tool", "bypassPermissions"],
            ["--allow-tool=-p"],
            ["--tools=--bare"],
            ["--model=--dangerously-skip-permissions"],
        )
        for argv in injections:
            outcome = self.run_turn(*argv)
            self.assertEqual(outcome.returncode, 64, argv)
            self.assertIn("looks like a command-line option", outcome.stderr)
            self.assertEqual(self.received(), [])
            self.assertFalse(self.out.exists())
        # Flags inside a rule are legitimate and forwarded intact.
        outcome = self.run_turn("--allow-tool", "Bash(bun test --coverage)", "--dry-run")
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        self.assertEqual(self.events(outcome)[0]["command"][-1], "Bash(bun test --coverage)")

    def test_refuses_to_nest_inside_a_claude_session(self):
        outcome = self.run_turn(CLAUDECODE="1")
        self.assertEqual(outcome.returncode, 1)
        self.assertIn("CLAUDECODE", outcome.stderr)
        self.assertEqual(self.received(), [])
        self.assertFalse(self.out.exists())

    # ── executable selection ────────────────────────────────────────────
    def test_default_executable_is_the_native_install(self):
        native = self.home / ".local" / "bin" / "claude"
        native.write_text(FAKE_CLAUDE, encoding="utf-8")
        native.chmod(0o700)
        outcome = self.run_turn(claude_bin=False)
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        self.assertEqual(self.state()["claude_binary"], str(native.resolve()))
        self.assertIn("native install", self.state()["claude_binary_source"])

    def test_path_is_never_searched_for_claude(self):
        # A `claude` on PATH (on WSL, often the Windows npm shim with its own
        # config and auth) must not be picked up when the native install is absent.
        path_bin = self.base / "mnt-c-npm"
        path_bin.mkdir()
        (path_bin / "claude").write_text(FAKE_CLAUDE, encoding="utf-8")
        (path_bin / "claude").chmod(0o700)
        outcome = subprocess.run(self.command(claude_bin=False), capture_output=True, text=True,
                                 env=self.env(PATH=f"{path_bin}{os.pathsep}{self.env()['PATH']}"), timeout=60)
        self.assertEqual(outcome.returncode, 1, outcome.stdout)
        self.assertIn("--claude-bin", outcome.stderr)
        self.assertEqual(self.received(), [])
        self.assertFalse(self.out.exists())

    def test_missing_executable_fails_before_creating_anything(self):
        outcome = self.run_turn("--claude-bin", str(self.base / "absent"))
        self.assertEqual(outcome.returncode, 1)
        self.assertFalse(self.out.exists())

    # ── filesystem discipline ───────────────────────────────────────────
    def test_dry_run_creates_and_launches_nothing(self):
        before = sorted(p.relative_to(self.base) for p in self.base.rglob("*"))
        outcome = self.run_turn("--dry-run", "--allow-tool", "Bash(bun test)")
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        self.assertEqual(sorted(p.relative_to(self.base) for p in self.base.rglob("*")), before)
        self.assertEqual(self.received(), [])
        plan = self.events(outcome)[0]
        self.assertEqual(plan["event"], "dry_run")
        self.assertIn("--session-id", plan["command"])
        self.assertNotIn("bypassPermissions", plan["command"])
        self.assertNotIn("--dangerously-skip-permissions", plan["command"])
        self.assertNotIn("--bare", plan["command"])
        self.assertEqual(plan["command"][-1], "Bash(bun test)")

    def test_existing_output_directory_is_preserved(self):
        self.out.mkdir(parents=True)
        marker = self.out / "run.json"
        marker.write_text("keep")
        outcome = self.run_turn()
        self.assertEqual(outcome.returncode, 1)
        self.assertIn("already exists", outcome.stderr)
        self.assertEqual(marker.read_text(), "keep")
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ["run.json"])
        self.assertEqual(self.received(), [])

    def test_dangling_output_symlink_is_rejected_without_writing_its_target(self):
        self.out.parent.mkdir(parents=True)
        target = self.base / "link-target"
        self.out.symlink_to(target)
        before = sorted(p.relative_to(self.base) for p in self.base.rglob("*"))
        outcome = self.run_turn()
        self.assertEqual(outcome.returncode, 1)
        self.assertIn("already exists", outcome.stderr)
        self.assertFalse(target.exists())
        self.assertTrue(self.out.is_symlink())
        self.assertEqual(sorted(p.relative_to(self.base) for p in self.base.rglob("*")), before)
        self.assertEqual(self.received(), [])

    def test_oversized_prompt_is_rejected_without_being_loaded(self):
        limit = load_runner_module().MAX_PROMPT_BYTES
        with self.prompt.open("wb") as huge:  # sparse: 2 GiB apparent, almost nothing on disk
            huge.seek(2 * 1024 ** 3 - 1)
            huge.write(b"\0")
        cap = 512 * 1024 ** 2  # far below the file, comfortably above the interpreter
        outcome = subprocess.run(self.command(), capture_output=True, text=True, env=self.env(), timeout=60,
                                 preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_AS, (cap, cap)))
        self.assertEqual(outcome.returncode, 1, outcome.stderr)
        self.assertIn(f"exceeds the runner's {limit} byte", outcome.stderr)
        self.assertNotIn("MemoryError", outcome.stderr)
        self.assertNotIn("Traceback", outcome.stderr)
        self.assertFalse(self.out.exists())
        self.assertEqual(self.received(), [])

    def test_prompt_exactly_at_the_limit_with_bom_still_passes(self):
        limit = load_runner_module().MAX_PROMPT_BYTES
        body = (b"x" * (limit - 1)) + b"\n"
        self.prompt.write_bytes(b"\xef\xbb\xbf" + body)
        outcome = self.run_turn()
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        self.assertEqual((self.out / "prompt.txt").read_bytes(), body)
        self.prompt.write_bytes(b"\xef\xbb\xbf" + body + b"y")
        self.out = self.base / "runs" / "run-02"
        outcome = self.run_turn()
        self.assertEqual(outcome.returncode, 1)
        self.assertIn("exceeds", outcome.stderr)

    def test_huge_stderr_log_still_yields_the_flag_without_loading_it(self):
        log = self.base / "stderr.log"
        with log.open("wb") as huge:
            huge.write(b"error: unknown option '--permission-prompts'\nmore output\n")
            huge.truncate(4 * 1024 ** 3)  # sparse tail, far beyond any sane allocation
        cap = 512 * 1024 ** 2
        probe = ("import importlib.util, sys\nfrom pathlib import Path\n"
                 "spec = importlib.util.spec_from_file_location('r', sys.argv[1])\n"
                 "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
                 "print(m.unsupported_flag(Path(sys.argv[2])))")
        outcome = subprocess.run([sys.executable, "-c", probe, str(RUNNER), str(log)], capture_output=True,
                                 text=True, timeout=60,
                                 preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_AS, (cap, cap)))
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        self.assertEqual(outcome.stdout.strip(), "--permission-prompts")

    def test_invalid_timeout_values_are_rejected_before_anything_happens(self):
        for value in ("nan", "inf", "-inf", "0", "-1"):
            outcome = self.run_turn(f"--timeout={value}")  # '=' form: a leading '-' would read as an option
            self.assertEqual(outcome.returncode, 64, value)
            self.assertIn("finite, positive", outcome.stderr, value)
            self.assertFalse(self.out.exists())
            self.assertEqual(self.received(), [])

    def test_invalid_utf8_prompt_is_rejected(self):
        self.prompt.write_bytes(b"bad \xff prompt")
        outcome = self.run_turn()
        self.assertEqual(outcome.returncode, 1)
        self.assertIn("UTF-8", outcome.stderr)
        self.assertFalse(self.out.exists())

    # ── owned-process cleanup ───────────────────────────────────────────
    def start_hanging_run(self, *extra, mode="hang", **env_extra):
        proc = subprocess.Popen(self.command(*extra), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=self.env(mode, **env_extra))
        pids = None
        for line in proc.stdout:
            event = json.loads(line)
            if event.get("event") == "progress" and event["text"].startswith("PIDS "):
                pids = json.loads(event["text"][5:])
                break
        self.assertIsNotNone(pids, "stub never reported its pids")
        return proc, pids

    def test_sigint_stops_only_the_owned_run_and_records_state(self):
        proc, pids = self.start_hanging_run()
        self.assertTrue(all(is_alive(p) for p in pids))
        proc.send_signal(signal.SIGINT)
        stdout, stderr = proc.communicate(timeout=30)
        self.assertEqual(proc.returncode, 130, stderr)
        self.assertTrue(wait_dead(pids), "claude process group survived the runner interrupt")
        state = self.state()
        self.assertEqual(state["status"], "interrupted")
        self.assertEqual(state["interrupted_by"], "SIGINT")
        self.assertEqual(state["claude_process_group"], pids[0])
        self.assertEqual(state["exit_code"], 130)
        self.assertIn("finished_at", state)
        self.assertIn("PIDS", (self.out / "events.jsonl").read_text())
        self.assertEqual(json.loads(stdout.splitlines()[-1])["status"], "interrupted")

    def test_timeout_stops_the_owned_run(self):
        proc, pids = self.start_hanging_run("--timeout", "1")
        stdout, stderr = proc.communicate(timeout=30)
        self.assertEqual(proc.returncode, 124, stderr)
        self.assertTrue(wait_dead(pids), "claude process group survived the timeout")
        state = self.state()
        self.assertEqual(state["status"], "timed_out")
        self.assertEqual(state["exit_code"], 124)

    def test_group_is_stopped_after_its_leader_exits_and_a_child_ignores_term(self):
        # Unrelated process in its own session: must be untouched by the cleanup.
        bystander = subprocess.Popen(["sleep", "300"], start_new_session=True)
        try:
            started = time.monotonic()
            proc, pids = self.start_hanging_run(mode="orphan")
            leader, child = pids
            stdout, stderr = proc.communicate(timeout=60)
            # Claude itself exited without a result: that is a failure, observed
            # as soon as it happened, and it does not wait for the child's EOF.
            self.assertEqual(proc.returncode, 1, stderr)
            self.assertLess(time.monotonic() - started, 25)
            # A zombie would already count as dead; require the live child to be gone too.
            self.assertTrue(wait_dead([child], seconds=5), "TERM-ignoring child survived the runner stop")
            self.assertFalse(is_alive(leader))
            self.assertTrue(is_alive(bystander.pid), "cleanup reached a process outside the owned group")
            state = self.state()
            self.assertEqual(state["status"], "failed")
            self.assertEqual(state["exit_code"], 1)
            self.assertEqual(state["claude_exit_code"], 0)
            self.assertIn("finished_at", state)
            self.assertEqual(json.loads(stdout.splitlines()[-1])["status"], "failed")
        finally:
            bystander.kill()
            bystander.wait()

    def test_background_startup_writer_does_not_block_or_misreport_completion(self):
        # A ~/.bashrc background job inherits the events pipe and keeps it
        # open long after Claude wrote its result and exited.
        with (self.home / ".bashrc").open("a") as rc:
            rc.write("sleep 30 &\n")
        started = time.monotonic()
        outcome = self.run_turn("--timeout", "3")
        elapsed = time.monotonic() - started
        self.assertEqual(outcome.returncode, 0, outcome.stderr + outcome.stdout)
        self.assertLess(elapsed, 3, "completion waited for the inherited pipe instead of Claude's exit")
        state = self.state()
        self.assertEqual(state["status"], "turn_complete")
        self.assertEqual(json.loads((self.out / "result.json").read_text())["result"], "done")
        self.assertIn('"type": "result"', (self.out / "events.jsonl").read_text())
        self.assertTrue(wait_group_empty(state["claude_process_group"], seconds=5),
                        "the startup background job outlived the turn")

    def test_closing_stdout_is_not_treated_as_exit(self):
        marker = self.base / "cleanup-finished"
        outcome = self.run_turn(mode="close_stdout_then_cleanup", FAKE_CLAUDE_MARKER=str(marker))
        self.assertEqual(outcome.returncode, 0, outcome.stderr + outcome.stdout)
        state = self.state()
        self.assertEqual(state["status"], "turn_complete")
        self.assertEqual(state["claude_exit_code"], 0)
        self.assertTrue(marker.exists(), "Claude was stopped before it finished its own cleanup")

    def test_hung_child_with_closed_stdout_still_times_out(self):
        outcome = self.run_turn("--timeout", "1", mode="close_stdout_hang")
        self.assertEqual(outcome.returncode, 124, outcome.stderr)
        state = self.state()
        self.assertEqual(state["status"], "timed_out")
        self.assertTrue(wait_group_empty(state["claude_process_group"], seconds=5))

    def test_denials_with_unstoppable_survivor_are_failed_not_needs_permission(self):
        def refused(_pgid, _sig):
            raise PermissionError(1, "simulated EPERM")

        with mock.patch.object(os, "killpg", refused):
            rc, stdout = self.run_in_process(mode="denied_with_surviving_child")
        leader, child = self.pids_from(stdout)
        try:
            self.assertEqual(rc, 1, "a live owned child must not be reported as a mere approval need")
            state = self.state()
            self.assertEqual(state["status"], "failed")
            self.assertEqual(state["exit_code"], 1)
            self.assertIn("do not resume", state["error"])
            self.assertEqual(state["stop_survivors"], [child])
            self.assertEqual(len(state["stop_errors"]), 2)
            denials = json.loads((self.out / "result.json").read_text())["permission_denials"]
            self.assertEqual(denials[0]["tool_name"], "Bash")
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.kill(child, signal.SIGKILL)

    def test_success_with_unstoppable_survivor_is_not_success(self):
        def refused(_pgid, _sig):
            raise PermissionError(1, "simulated EPERM")

        with mock.patch.object(os, "killpg", refused):
            rc, stdout = self.run_in_process(mode="success_with_surviving_child")
        leader, child = self.pids_from(stdout)
        try:
            self.assertEqual(rc, 1)
            state = self.state()
            self.assertEqual(state["status"], "failed")
            self.assertEqual(state["exit_code"], 1)
            self.assertIn("stop_survivors", state["error"])
            self.assertEqual(state["stop_survivors"], [child])
            self.assertEqual(len(state["stop_errors"]), 2)
            self.assertEqual(json.loads((self.out / "result.json").read_text())["subtype"], "success")
            self.assertEqual(json.loads(stdout.splitlines()[-1])["status"], "failed")
        finally:
            os.kill(child, signal.SIGKILL)

    def test_continuously_writing_child_does_not_delay_completion(self):
        started = time.monotonic()
        outcome = self.run_turn("--timeout", "5", mode="success_with_chatty_child")
        child = None
        try:
            leader, child = self.pids_from(outcome.stdout)
            elapsed = time.monotonic() - started
            self.assertEqual(outcome.returncode, 0, outcome.stderr + outcome.stdout[-2000:])
            self.assertLess(elapsed, 5, "completion waited on a writer that never stops")
            state = self.state()
            self.assertEqual(state["status"], "turn_complete")
            self.assertEqual(json.loads((self.out / "result.json").read_text())["result"], "done")
            self.assertIn('"type": "result"', (self.out / "events.jsonl").read_text())
            self.assertTrue(wait_group_empty(state["claude_process_group"], seconds=5),
                            "the chatty writer outlived the turn")
        finally:
            if child is not None:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(child, signal.SIGKILL)

    def test_nonzero_exit_with_denials_is_failed_not_needs_permission(self):
        outcome = self.run_turn(mode="denied_then_exit_1")
        self.assertEqual(outcome.returncode, 1, outcome.stdout)
        state = self.state()
        self.assertEqual(state["status"], "failed")
        self.assertEqual(state["claude_exit_code"], 1)
        denials = json.loads((self.out / "result.json").read_text())["permission_denials"]
        self.assertEqual(denials[0]["tool_name"], "Bash")

    def test_cancel_after_popen_before_recording_keeps_group_identity(self):
        module = load_runner_module()
        real_write_json = module.write_json
        fired = []

        def signal_while_recording(path, value):
            if value.get("status") == "running" and "claude_process_group" in value and not fired:
                fired.append(True)
                os.kill(os.getpid(), signal.SIGTERM)  # child exists, group not yet on disk
            return real_write_json(path, value)

        with mock.patch.object(module, "write_json", signal_while_recording):
            argv = self.command()[2:]
            handled = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGALRM)
            saved = {s: signal.getsignal(s) for s in handled}
            stdout = io.StringIO()
            try:
                with mock.patch.dict(os.environ, self.env("hang"), clear=True), contextlib.redirect_stdout(stdout):
                    rc = module.main(argv)
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
                for s, handler in saved.items():
                    signal.signal(s, handler)
        self.assertTrue(fired)
        self.assertEqual(rc, 143)
        state = self.state()
        self.assertEqual(state["status"], "interrupted")
        self.assertEqual(state["interrupted_by"], "SIGTERM")
        self.assertIn("claude_process_group", state)
        self.assertTrue(wait_group_empty(state["claude_process_group"], seconds=5))

    def test_signal_before_teardown_entry_is_retried_not_skipped(self):
        with self.signal_inside_teardown(lambda n: n == 1) as seen:
            rc, stdout = self.run_in_process(mode="success_with_surviving_child")
        leader, child = self.pids_from(stdout)
        try:
            self.assertTrue(seen, "teardown was never traced")
            self.assertEqual(rc, 130)
            state = self.state()
            self.assertEqual(state["status"], "interrupted")
            self.assertEqual(state["interrupted_by"], "SIGINT")
            self.assertIn("finished_at", state)
            self.assertNotIn("stop_survivors", state)
            self.assertNotIn("teardown_error", state)
            self.assertTrue(wait_group_empty(leader, seconds=5), "a signal at teardown entry skipped the cleanup")
            self.assertEqual(json.loads((self.out / "result.json").read_text())["subtype"], "success")
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.kill(child, signal.SIGKILL)

    def test_signal_after_teardown_entry_cannot_abandon_cleanup(self):
        with self.signal_inside_teardown(lambda n: n >= 2) as seen:
            rc, stdout = self.run_in_process(mode="success_with_surviving_child")
        leader, child = self.pids_from(stdout)
        try:
            self.assertGreaterEqual(len(seen), 2, "teardown had fewer boundaries than expected")
            self.assertEqual(rc, 0)
            state = self.state()
            self.assertEqual(state["status"], "turn_complete")
            self.assertNotIn("stop_survivors", state)
            self.assertTrue(wait_group_empty(leader, seconds=5), "a signal inside teardown abandoned the cleanup")
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.kill(child, signal.SIGKILL)

    def test_cancel_at_launch_boundary_still_stops_the_owned_child(self):
        real_popen = subprocess.Popen

        def popen_then_signal(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            # Delivered to the runner's handler before this frame returns, i.e.
            # after the child exists and before the runner has recorded it.
            os.kill(os.getpid(), signal.SIGTERM)
            return child

        with mock.patch.object(subprocess, "Popen", popen_then_signal):
            rc, stdout = self.run_in_process(mode="hang")
        self.assertEqual(rc, 143)
        state = self.state()
        self.assertEqual(state["status"], "interrupted")
        self.assertEqual(state["interrupted_by"], "SIGTERM")
        self.assertIn("claude_process_group", state)
        self.assertIn("finished_at", state)
        self.assertTrue(wait_group_empty(state["claude_process_group"], seconds=5),
                        "a launch-time cancel left the owned group running")
        self.assertEqual(json.loads(stdout.splitlines()[-1])["status"], "interrupted")

    def test_signals_go_only_to_the_pinned_group(self):
        real_killpg = os.killpg
        calls = []

        def observed(pgid, sig):
            # Ownership is intact only while the leader's PID still exists
            # (running or zombie): then the group id cannot belong to anyone else.
            calls.append((pgid, signal.Signals(sig), Path(f"/proc/{pgid}/stat").exists()))
            return real_killpg(pgid, sig)

        with mock.patch.object(os, "killpg", observed):
            rc, stdout = self.run_in_process(mode="orphan")
        leader, child = self.pids_from(stdout)
        self.assertEqual(rc, 1)
        state = self.state()
        self.assertEqual(state["claude_process_group"], leader)
        self.assertEqual([c[1] for c in calls], [signal.SIGTERM, signal.SIGKILL])
        self.assertTrue(all(pgid == leader for pgid, _, _ in calls), calls)
        self.assertTrue(all(pinned for _, _, pinned in calls), "a signal was sent after ownership was released")
        self.assertFalse(Path(f"/proc/{leader}/stat").exists(), "leader was not reaped at the end")
        self.assertFalse(is_alive(child))
        self.assertNotIn("stop_errors", state)
        self.assertNotIn("stop_survivors", state)

    def test_failed_cleanup_syscalls_still_leave_a_final_run_json(self):
        def refused(_pgid, _sig):
            raise PermissionError(1, "simulated EPERM")

        with mock.patch.object(os, "killpg", refused):
            rc, stdout = self.run_in_process(mode="orphan")
        leader, child = self.pids_from(stdout)
        try:
            self.assertEqual(rc, 1)
            state = self.state()
            self.assertEqual(state["status"], "failed")
            self.assertEqual(state["exit_code"], 1)
            self.assertIn("finished_at", state)
            self.assertEqual(len(state["stop_errors"]), 2)
            self.assertIn("SIGTERM", state["stop_errors"][0])
            self.assertIn("SIGKILL", state["stop_errors"][1])
            self.assertEqual(state["stop_survivors"], [child])
            self.assertFalse(Path(f"/proc/{leader}/stat").exists())
            self.assertEqual(json.loads(stdout.splitlines()[-1])["status"], "failed")
        finally:
            os.kill(child, signal.SIGKILL)

    def test_second_signal_during_teardown_does_not_abandon_the_group(self):
        marker = self.base / "term-seen"
        proc, pids = self.start_hanging_run(mode="hang_ignore_term", FAKE_CLAUDE_TERM_MARKER=str(marker))
        leader, child = pids
        proc.send_signal(signal.SIGINT)
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(marker.exists(), "teardown never sent SIGTERM to the child")
        # Teardown is now waiting out the TERM-ignoring child: hit it again.
        proc.send_signal(signal.SIGINT)
        proc.send_signal(signal.SIGTERM)
        stdout, stderr = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, 130, stderr)
        self.assertTrue(wait_dead([leader, child], seconds=5), "group survived a repeated signal during teardown")
        state = self.state()
        self.assertEqual(state["status"], "interrupted")
        self.assertEqual(state["interrupted_by"], "SIGINT")
        self.assertEqual(state["exit_code"], 130)
        self.assertIn("finished_at", state)
        self.assertEqual(json.loads(stdout.splitlines()[-1])["status"], "interrupted")

    def test_zombie_is_not_mistaken_for_a_running_child(self):
        zombie = subprocess.Popen(["true"])
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and Path(f"/proc/{zombie.pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z":
            time.sleep(0.05)
        try:
            self.assertFalse(is_alive(zombie.pid))
        finally:
            zombie.wait()


if __name__ == "__main__":
    unittest.main(verbosity=2)
