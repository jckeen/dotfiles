#!/usr/bin/env python3
import importlib.util
import fcntl
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

    def test_many_core_proc_stat_is_streamed(self):
        cpu_lines = "".join(f"cpu{number} 1 2 3 4 5 6 7 8 9 10\n" for number in range(1000))
        (self.proc / "stat").write_text(cpu_lines + f"btime {self.boot_time}\n")
        self.assertGreater((self.proc / "stat").stat().st_size, RECOVER.MAX_RECORD_BYTES)
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

    def prepare_repair(self):
        self.pid_file.unlink()
        self.server_pid = self.pid - 1
        self.server_pid_file = self.pid_file.parent / "app-server.pid"
        server = self.proc / str(self.server_pid)
        server.mkdir()
        (server / "stat").write_text(
            f"{self.server_pid} (codex) S " + "0 " * 18 + f"{self.start_ticks - 1}\n"
        )
        (server / "exe").symlink_to(self.exe)
        (server / "cmdline").write_bytes(
            os.fsencode(self.argv_zero) + b"\0app-server\0--remote-control\0--listen\0unix://\0"
        )
        for name in ("daemon.lock", "app-server.pid.lock", "app-server-updater.pid.lock"):
            (self.pid_file.parent / name).touch()

    def repair(self, **overrides):
        args = dict(
            pid_file=self.pid_file,
            identity_file=self.identity_file,
            proc_root=self.proc,
            home=self.home,
            expected_uid=os.getuid(),
            clock_ticks=self.clock_ticks,
            pidfd_open=lambda pid: 99 if pid == self.pid else -1,
            socket_peer=lambda path: (self.server_pid, os.getuid(), 98),
            pidfd_send_signal=lambda fd, sig: self.signals.append((fd, sig)),
            close_pidfd=lambda fd: None,
        )
        args.update(overrides)
        return RECOVER.repair_pid_records(**args)

    def test_repair_survives_clock_drift_and_updated_current_symlink(self):
        self.prepare_repair()
        (self.proc / "stat").write_text(f"btime {self.boot_time + 300}\n")
        newer = self.home / ".codex/packages/standalone/releases/new/bin"
        newer.mkdir(parents=True)
        (newer / "codex").write_bytes(b"newer fixture")
        current = self.argv_zero.parent.parent
        current.unlink()
        current.symlink_to("releases/new", target_is_directory=True)
        self.assertTrue(self.repair())
        for path, pid in ((self.pid_file, self.pid), (self.server_pid_file, self.server_pid)):
            record = json.loads(path.read_text())
            self.assertEqual(record["pid"], pid)
            self.assertNotEqual(record["processStartTime"], self.recorded_start)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.signals, [(99, 0), (98, 0)])
        self.assertTrue(RECOVER.snapshot_updater(
            pid_file=self.pid_file, identity_file=self.identity_file,
            proc_root=self.proc, home=self.home, expected_uid=os.getuid(),
            clock_ticks=self.clock_ticks, pidfd_open=lambda pid: 99,
            pidfd_send_signal=lambda fd, sig: None, close_pidfd=lambda fd: None,
        ))
        self.assertTrue(self.recover())

    def test_repair_refuses_a_reused_updater_pid(self):
        self.prepare_repair()
        self.write_identity(startTicks=self.start_ticks - 1)
        self.assertFalse(self.repair())
        self.assertFalse(self.pid_file.exists())
        self.assertFalse(self.server_pid_file.exists())

    def test_repair_requires_a_prior_identity_from_this_boot(self):
        self.prepare_repair()
        self.write_identity(bootId="different-boot")
        self.assertFalse(self.repair())
        self.identity_file.unlink()
        self.assertFalse(self.repair())
        self.assertFalse(self.pid_file.exists())

    def test_repair_refuses_foreign_socket_peer_or_role(self):
        self.prepare_repair()
        self.assertFalse(self.repair(socket_peer=lambda path: (self.server_pid, os.getuid() + 1, 98)))
        (self.proc / str(self.server_pid) / "cmdline").write_bytes(
            os.fsencode(self.argv_zero) + b"\0app-server\0"
        )
        self.assertFalse(self.repair())
        self.assertFalse(self.server_pid_file.exists())

    def test_repair_refuses_conflicting_or_symlinked_pid_records(self):
        self.prepare_repair()
        self.write_record(pid=self.pid + 1)
        original = self.pid_file.read_bytes()
        self.assertFalse(self.repair())
        self.assertEqual(self.pid_file.read_bytes(), original)
        self.pid_file.unlink()
        self.pid_file.symlink_to(self.root / "absent")
        self.assertFalse(self.repair())
        self.assertFalse(self.server_pid_file.exists())

    def test_repair_refuses_busy_native_locks(self):
        self.prepare_repair()
        for name in ("daemon.lock", "app-server.pid.lock", "app-server-updater.pid.lock"):
            with (self.pid_file.parent / name).open() as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertFalse(self.repair())
        self.assertFalse(self.pid_file.exists())

    def test_repair_refuses_when_captured_process_exits(self):
        self.prepare_repair()
        def process_gone(fd, sig):
            raise ProcessLookupError
        self.assertFalse(self.repair(pidfd_send_signal=process_gone))
        self.assertFalse(self.pid_file.exists())
        self.assertFalse(self.server_pid_file.exists())

    def test_repair_keeps_a_valid_existing_record(self):
        self.prepare_repair()
        self.write_record()
        original = self.pid_file.read_bytes()
        self.assertTrue(self.repair())
        self.assertEqual(self.pid_file.read_bytes(), original)
        self.assertEqual(json.loads(self.server_pid_file.read_text())["pid"], self.server_pid)

    def test_repair_refuses_unsupported_peer_pidfd(self):
        self.prepare_repair()
        def unsupported(path):
            raise OSError("SO_PEERPIDFD unsupported")
        self.assertFalse(self.repair(socket_peer=unsupported))
        self.assertFalse(self.pid_file.exists())
        self.assertFalse(self.server_pid_file.exists())

    def test_repair_refuses_socket_peer_executable_outside_managed_release(self):
        self.prepare_repair()
        foreign = self.root / "foreign-codex"
        foreign.write_bytes(b"fixture")
        exe_link = self.proc / str(self.server_pid) / "exe"
        exe_link.unlink()
        exe_link.symlink_to(foreign)
        self.assertFalse(self.repair())
        self.assertFalse(self.pid_file.exists())

    def test_repair_does_not_overwrite_a_record_created_during_validation(self):
        self.prepare_repair()
        def competing_writer(fd, sig):
            if fd == 98:
                self.pid_file.write_text("concurrent record")
        self.assertFalse(self.repair(pidfd_send_signal=competing_writer))
        self.assertEqual(self.pid_file.read_text(), "concurrent record")
        self.assertFalse(self.server_pid_file.exists())


if __name__ == "__main__":
    unittest.main()
