#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import signal
import tempfile
import time
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "remote_control_recover.py"
SPEC = importlib.util.spec_from_file_location("remote_control_recover", MODULE_PATH)
assert SPEC and SPEC.loader
RECOVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECOVER)


class RemoteControlRecoverTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.proc = self.root / "proc"
        self.pid = 4242
        self.clock_ticks = 100
        self.boot_time = 100_000
        self.start_ticks = 250

        daemon = self.home / ".codex/app-server-daemon"
        daemon.mkdir(parents=True)
        self.pid_file = daemon / "app-server-updater.pid"
        self.identity_file = daemon / "app-server-updater.identity.json"
        release = self.home / ".codex/packages/standalone/releases/test/bin"
        release.mkdir(parents=True)
        self.exe = release / "codex"
        self.exe.write_bytes(b"fixture")
        current_release = self.home / ".codex/packages/standalone/current"
        current_release.symlink_to("releases/test", target_is_directory=True)
        self.argv_zero = current_release / "bin/codex"

        process = self.proc / str(self.pid)
        process.mkdir(parents=True)
        (self.proc / "stat").write_text(f"btime {self.boot_time}\n")
        boot_id_dir = self.proc / "sys/kernel/random"
        boot_id_dir.mkdir(parents=True)
        self.boot_id = "11111111-2222-3333-4444-555555555555"
        (boot_id_dir / "boot_id").write_text(self.boot_id + "\n")
        stat_tail = ["S", *(["0"] * 18), str(self.start_ticks)]
        (process / "stat").write_text(
            f"{self.pid} (codex) " + " ".join(stat_tail) + "\n"
        )
        (process / "exe").symlink_to(self.exe)
        (process / "cmdline").write_bytes(
            os.fsencode(str(self.argv_zero))
            + b"\0app-server\0daemon\0pid-update-loop\0"
        )
        self.recorded_start = time.strftime(
            "%a %b %e %H:%M:%S %Y",
            time.localtime(self.boot_time + self.start_ticks / self.clock_ticks),
        )
        self.write_record()
        self.write_identity()
        self.signals = []

    def tearDown(self):
        self.temp.cleanup()

    def write_record(self, **overrides):
        record = {"pid": self.pid, "processStartTime": self.recorded_start}
        record.update(overrides)
        self.pid_file.write_text(json.dumps(record))

    def write_identity(self, **overrides):
        identity = {
            "bootId": self.boot_id,
            "pid": self.pid,
            "processStartTime": self.recorded_start,
            "startTicks": self.start_ticks,
        }
        identity.update(overrides)
        self.identity_file.write_text(json.dumps(identity))

    def recover(self):
        return RECOVER.terminate_stale_updater(
            pid_file=self.pid_file,
            identity_file=self.identity_file,
            proc_root=self.proc,
            home=self.home,
            expected_uid=os.getuid(),
            clock_ticks=self.clock_ticks,
            pidfd_open=lambda pid: 99 if pid == self.pid else -1,
            pidfd_send_signal=lambda fd, sig: self.signals.append((fd, sig)),
            wait_for_exit=lambda fd, timeout: fd == 99 and timeout == 5,
            close_pidfd=lambda fd: None,
        )

    def test_snapshot_records_exact_kernel_identity(self):
        self.identity_file.unlink()
        snapshot_signals = []
        self.assertTrue(
            RECOVER.snapshot_updater(
                pid_file=self.pid_file,
                identity_file=self.identity_file,
                proc_root=self.proc,
                home=self.home,
                expected_uid=os.getuid(),
                clock_ticks=self.clock_ticks,
                pidfd_open=lambda pid: 99 if pid == self.pid else -1,
                pidfd_send_signal=lambda fd, sig: snapshot_signals.append((fd, sig)),
                close_pidfd=lambda fd: None,
            )
        )
        self.assertEqual(snapshot_signals, [(99, 0)])
        self.assertEqual(
            json.loads(self.identity_file.read_text()),
            {
                "bootId": self.boot_id,
                "pid": self.pid,
                "processStartTime": self.recorded_start,
                "startTicks": self.start_ticks,
            },
        )

    def test_valid_managed_updater_is_signaled_through_pidfd(self):
        self.assertTrue(self.recover())
        self.assertEqual(self.signals, [(99, signal.SIGTERM)])

    def test_foreign_command_line_is_refused(self):
        (self.proc / str(self.pid) / "cmdline").write_bytes(b"/usr/bin/sleep\0600\0")
        self.assertFalse(self.recover())
        self.assertEqual(self.signals, [])

    def test_reused_pid_start_time_is_refused(self):
        self.write_record(processStartTime="Fri Jul 17 00:19:26 2026")
        self.assertFalse(self.recover())
        self.assertEqual(self.signals, [])

    def test_new_updater_in_same_formatted_second_is_refused(self):
        new_start_ticks = self.start_ticks + 49
        stat_tail = ["S", *(["0"] * 18), str(new_start_ticks)]
        (self.proc / str(self.pid) / "stat").write_text(
            f"{self.pid} (codex) " + " ".join(stat_tail) + "\n"
        )
        self.assertFalse(self.recover())
        self.assertEqual(self.signals, [])

    def test_missing_exact_identity_is_refused(self):
        self.identity_file.unlink()
        self.assertFalse(self.recover())
        self.assertEqual(self.signals, [])

    def test_previous_boot_identity_is_refused(self):
        (self.proc / "sys/kernel/random/boot_id").write_text(
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n"
        )
        self.assertFalse(self.recover())
        self.assertEqual(self.signals, [])

    def test_symlinked_exact_identity_is_refused(self):
        real_identity = self.identity_file.with_suffix(".real")
        self.identity_file.rename(real_identity)
        self.identity_file.symlink_to(real_identity)
        self.assertFalse(self.recover())
        self.assertEqual(self.signals, [])

    def test_snapshot_refuses_identity_when_pidfd_process_exited(self):
        self.identity_file.unlink()

        def process_gone(fd, sig):
            raise ProcessLookupError

        self.assertFalse(
            RECOVER.snapshot_updater(
                pid_file=self.pid_file,
                identity_file=self.identity_file,
                proc_root=self.proc,
                home=self.home,
                expected_uid=os.getuid(),
                clock_ticks=self.clock_ticks,
                pidfd_open=lambda pid: 99 if pid == self.pid else -1,
                pidfd_send_signal=process_gone,
                close_pidfd=lambda fd: None,
            )
        )
        self.assertFalse(self.identity_file.exists())

    def test_symlinked_pid_record_is_refused(self):
        real_record = self.pid_file.with_suffix(".real")
        self.pid_file.rename(real_record)
        self.pid_file.symlink_to(real_record)
        self.assertFalse(self.recover())
        self.assertEqual(self.signals, [])

    def test_executable_outside_managed_release_is_refused(self):
        foreign = self.root / "foreign-codex"
        foreign.write_bytes(b"fixture")
        exe_link = self.proc / str(self.pid) / "exe"
        exe_link.unlink()
        exe_link.symlink_to(foreign)
        self.assertFalse(self.recover())
        self.assertEqual(self.signals, [])


if __name__ == "__main__":
    unittest.main()
