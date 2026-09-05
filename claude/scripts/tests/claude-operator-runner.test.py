#!/usr/bin/env python3
"""Offline mock suite for agents/skills/claude-operator/scripts/claude_run.py.

A stub `claude` (a Python script) stands in for the real CLI, HOME points at a
throwaway directory with a crafted ~/.bashrc, and the child environment is
built from scratch, so the suite never launches the real model, needs no auth,
and inherits none of the developer's shell startup side effects. Standard
library only. Run directly: python3 claude/scripts/tests/claude-operator-runner.test.py
"""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

RUNNER = Path(__file__).resolve().parents[3] / "agents/skills/claude-operator/scripts/claude_run.py"

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
        # banners and /etc/bash.bashrc hints do, and tries to move Claude away.
        (self.home / ".bashrc").write_text(
            f'export OPERATOR_TEST_RC=loaded\necho STARTUP_BANNER\ncd "{self.base}/elsewhere"\n')
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

    def test_invalid_utf8_prompt_is_rejected(self):
        self.prompt.write_bytes(b"bad \xff prompt")
        outcome = self.run_turn()
        self.assertEqual(outcome.returncode, 1)
        self.assertIn("UTF-8", outcome.stderr)
        self.assertFalse(self.out.exists())

    # ── owned-process cleanup ───────────────────────────────────────────
    def start_hanging_run(self, *extra, mode="hang"):
        proc = subprocess.Popen(self.command(*extra), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=self.env(mode))
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
            proc, pids = self.start_hanging_run("--timeout", "1", mode="orphan")
            leader, child = pids
            stdout, stderr = proc.communicate(timeout=60)
            self.assertEqual(proc.returncode, 124, stderr)
            # A zombie would already count as dead; require the live child to be gone too.
            self.assertTrue(wait_dead([child], seconds=5), "TERM-ignoring child survived the runner stop")
            self.assertFalse(is_alive(leader))
            self.assertTrue(is_alive(bystander.pid), "cleanup reached a process outside the owned group")
            state = self.state()
            self.assertEqual(state["status"], "timed_out")
            self.assertEqual(state["exit_code"], 124)
            self.assertEqual(state["claude_exit_code"], 0)
            self.assertIn("finished_at", state)
            self.assertEqual(json.loads(stdout.splitlines()[-1])["status"], "timed_out")
        finally:
            bystander.kill()
            bystander.wait()

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
