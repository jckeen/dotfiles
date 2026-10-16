#!/usr/bin/env python3
"""Exercise the service launcher's opt-in and execution boundary without credentials."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

LAUNCHER = Path(__file__).resolve().parents[1] / "remote-control-service.sh"


class ServiceLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.codex_home = self.home / ".codex"
        self.settings = self.codex_home / "app-server-daemon/settings.json"
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text('{"remoteControlEnabled": true}')
        binary = self.home / ".local/bin/codex"
        binary.parent.mkdir(parents=True)
        binary.write_text(
            "#!/usr/bin/python3\nimport json, os, sys\n"
            "print(json.dumps({'args': sys.argv[1:], 'pid': os.getpid(), "
            "'path': os.environ['PATH'], 'node': os.environ.get('NVM_TEST')}))\n"
        )
        binary.chmod(0o755)
        self.env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin"}

    def run_launcher(self):
        with subprocess.Popen(
            ["bash", str(LAUNCHER)],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ) as child:
            stdout, stderr = child.communicate(timeout=10)
            return child.returncode, stdout, stderr, child.pid

    def test_executes_standalone_foreground_server_without_daemon_management(self):
        result, stdout, stderr, pid = self.run_launcher()
        self.assertEqual(result, 0, stderr)
        payload = json.loads(stdout)
        self.assertEqual(payload["args"], ["app-server", "--remote-control", "--listen", "unix://"])
        self.assertEqual(payload["pid"], pid)
        self.assertIn(str(self.home / ".bun/bin"), payload["path"].split(":"))

    def test_disabled_missing_or_invalid_opt_in_never_launches(self):
        for settings in [
            None,
            "{}",
            '{"remoteControlEnabled":false}',
            "invalid",
            '{"remoteControlEnabled":"true"}',
            '{"remoteControlEnabled":false}\n{"remoteControlEnabled":true}',
            '{"remoteControlEnabled":true,"x":NaN}',
            '{"remoteControlEnabled":true,"x":Infinity}',
            '{"remoteControlEnabled":false,"remoteControlEnabled":true}',
        ]:
            with self.subTest(settings=settings):
                if settings is None:
                    self.settings.unlink(missing_ok=True)
                else:
                    self.settings.write_text(settings)
                result, stdout, _, _ = self.run_launcher()
                self.assertEqual(result, 78)
                self.assertEqual(stdout, "")

    def test_custom_codex_home_cannot_inherit_default_opt_in(self):
        self.env["CODEX_HOME"] = str(self.home / "other")
        result, stdout, _, _ = self.run_launcher()
        self.assertEqual(result, 78)
        self.assertEqual(stdout, "")

    def test_loads_optional_nvm_and_preserves_its_node_path(self):
        nvm = self.home / ".nvm/nvm.sh"
        nvm.parent.mkdir()
        nvm.write_text('export NVM_TEST=loaded\nexport PATH="$HOME/node-default/bin:$PATH"\n')
        result, stdout, stderr, _ = self.run_launcher()
        self.assertEqual(result, 0, stderr)
        payload = json.loads(stdout)
        self.assertEqual(payload["node"], "loaded")
        self.assertIn(str(self.home / "node-default/bin"), payload["path"].split(":"))

    def test_nvm_failure_does_not_start_a_partially_configured_server(self):
        nvm = self.home / ".nvm/nvm.sh"
        nvm.parent.mkdir()
        nvm.write_text("return 1\n")
        result, stdout, _, _ = self.run_launcher()
        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")


if __name__ == "__main__":
    unittest.main()
