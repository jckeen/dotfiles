#!/usr/bin/env python3
"""Keep real pushes on the endpoint whose default branch was checked."""
import importlib.util
from pathlib import Path
import sys
import unittest


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "shipping", Path(__file__).with_name("workflow-shipping.test.py"))
shipping = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shipping)


class RewriteTests(unittest.TestCase):
    def setUp(self):
        self.fixture = shipping.ShippingTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.env.update(GIT_CONFIG_NOSYSTEM="1",
                                GIT_CONFIG_GLOBAL=str(self.fixture.root / "global-config"))

    def git(self, *args):
        result = self.fixture.command("git", list(args))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def destinations(self):
        t = self.fixture
        reviewed = t.root / "reviewed-remote"
        redirected = t.root / "redirected-remote"
        for remote in (reviewed, redirected):
            self.git("clone", "--bare", str(t.remote), str(remote))
            self.git("--git-dir", str(remote), "update-ref", "refs/heads/feature", t.base)
        self.git("--git-dir", str(redirected), "symbolic-ref", "HEAD", "refs/heads/feature")
        self.git("config", f"url.{reviewed}.pushInsteadOf", str(t.remote))
        return reviewed, redirected

    def assert_rewrite_blocked(self, reviewed, redirected):
        t = self.fixture
        (t.bin / "git").unlink()
        result = t.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Git URL rewrite", result.stderr)
        self.assertEqual(self.git("--git-dir", str(redirected), "rev-parse", "refs/heads/feature"),
                         t.base, "a URL rewrite updated an unchecked default branch")
        self.assertEqual(self.git("--git-dir", str(reviewed), "rev-parse", "refs/heads/feature"),
                         t.base, "the wrapper pushed despite ambiguous URL rewrites")

    def test_local_push_rewrite_cannot_redirect_the_resolved_url(self):
        reviewed, redirected = self.destinations()
        self.git("config", f"url.{redirected}.pushInsteadOf", str(reviewed))
        self.assert_rewrite_blocked(reviewed, redirected)

    def test_global_push_rewrite_cannot_redirect_the_resolved_url(self):
        reviewed, redirected = self.destinations()
        self.git("config", "--global", f"url.{redirected}.pushInsteadOf", str(reviewed))
        self.assert_rewrite_blocked(reviewed, redirected)

    def test_general_rewrite_cannot_redirect_the_resolved_url(self):
        reviewed, redirected = self.destinations()
        self.git("config", f"url.{redirected}.insteadOf", str(reviewed))
        self.assertEqual(self.git("remote", "get-url", "--push", "origin"), str(reviewed))
        self.assert_rewrite_blocked(reviewed, redirected)

    def test_rewrites_added_during_review_do_not_change_the_endpoint(self):
        reviewed, redirected = self.destinations()
        t = self.fixture
        t.env.update(REVIEWED_REMOTE=str(reviewed), REDIRECT_REMOTE=str(redirected))
        t.write(t.scripts / "codex-review-gate.sh", '''#!/bin/bash
printf 'gate\\n' >> "$CALLS"
git config --global "url.$REDIRECT_REMOTE.pushInsteadOf" "$REVIEWED_REMOTE"
git config --global "url.$REDIRECT_REMOTE.insteadOf" "$REVIEWED_REMOTE"
''')
        self.assert_rewrite_blocked(reviewed, redirected)

    def test_single_rewrite_still_pushes_to_the_resolved_endpoint(self):
        reviewed, redirected = self.destinations()
        t = self.fixture
        (t.bin / "git").unlink()
        result = t.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("--git-dir", str(reviewed), "rev-parse", "refs/heads/feature"), t.head)
        self.assertEqual(self.git("--git-dir", str(redirected), "rev-parse", "refs/heads/feature"), t.base)


if __name__ == "__main__":
    unittest.main()
