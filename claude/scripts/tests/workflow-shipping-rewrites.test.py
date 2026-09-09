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

    def destinations(self, redirected_name="redirected-remote"):
        t = self.fixture
        reviewed = t.root / "reviewed-remote"
        redirected = t.root / redirected_name
        for remote in (reviewed, redirected):
            self.git("clone", "--bare", str(t.remote), str(remote))
            self.git("--git-dir", str(remote), "update-ref", "refs/heads/feature", t.base)
        self.git("--git-dir", str(redirected), "symbolic-ref", "HEAD", "refs/heads/feature")
        self.git("config", f"url.{reviewed}.pushInsteadOf", str(t.remote))
        return reviewed, redirected

    def assert_rewrite_blocked(self, reviewed, redirected, diagnostic="Git URL rewrite"):
        t = self.fixture
        (t.bin / "git").unlink()
        result = t.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(diagnostic, result.stderr)
        self.assertEqual(self.git("--git-dir", str(redirected), "rev-parse", "refs/heads/feature"),
                         t.base, "a URL rewrite updated an unchecked default branch")
        self.assertEqual(self.git("--git-dir", str(reviewed), "rev-parse", "refs/heads/feature"),
                         t.base, "the wrapper pushed despite ambiguous URL rewrites")

    def push_remotes(self):
        t = self.fixture
        remotes = {"origin": t.remote}
        for name in ("fetch", "default-push", "branch-push"):
            remote = t.root / name
            self.git("clone", "--bare", str(t.remote), str(remote))
            self.git("remote", "add", name, str(remote))
            remotes[name] = remote
        for remote in remotes.values():
            self.git("--git-dir", str(remote), "update-ref", "refs/heads/feature", t.base)
        (t.bin / "git").unlink()
        return remotes

    def assert_push_tips(self, remotes, selected=None):
        t = self.fixture
        for name, remote in remotes.items():
            self.assertEqual(
                self.git("--git-dir", str(remote), "rev-parse", "refs/heads/feature"),
                t.head if name == selected else t.base, name)

    def test_push_remote_selection_precedence(self):
        remotes = self.push_remotes()
        self.git("config", "branch.feature.remote", "fetch")
        self.git("config", "remote.pushDefault", "default-push")
        self.git("config", "branch.feature.pushRemote", "branch-push")
        cases = ((None, "branch-push"),
                 ("branch.feature.pushRemote", "default-push"),
                 ("remote.pushDefault", "fetch"),
                 ("branch.feature.remote", "origin"))
        for unset, selected in cases:
            with self.subTest(selected=selected):
                if unset:
                    self.git("config", "--unset", unset)
                for remote in remotes.values():
                    self.git("--git-dir", str(remote), "update-ref", "refs/heads/feature",
                             self.fixture.base)
                result = self.fixture.run_wrapper()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_push_tips(remotes, selected)

    def test_invalid_selected_push_remote_never_falls_back(self):
        remotes = self.push_remotes()
        for key in ("branch.feature.pushRemote", "remote.pushDefault", "branch.feature.remote"):
            for value in ("missing-remote", ""):
                with self.subTest(key=key, value=value):
                    for remote in remotes.values():
                        self.git("--git-dir", str(remote), "update-ref", "refs/heads/feature",
                                 self.fixture.base)
                    self.git("config", key, value)
                    try:
                        result = self.fixture.run_wrapper()
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assert_push_tips(remotes)
                    finally:
                        self.git("config", "--unset", key)

    def test_selected_pushurl_default_branch_is_checked(self):
        remotes = self.push_remotes()
        self.git("config", "branch.feature.pushRemote", "branch-push")
        self.git("config", "remote.branch-push.pushurl", str(remotes["default-push"]))
        self.git("--git-dir", str(remotes["default-push"]), "symbolic-ref", "HEAD",
                 "refs/heads/feature")
        result = self.fixture.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("does not push the default branch", result.stderr)
        self.assert_push_tips(remotes)

    def test_selected_push_remote_still_rejects_further_url_rewrites(self):
        remotes = self.push_remotes()
        self.git("config", "remote.pushDefault", "default-push")
        self.git("config", f"url.{remotes['branch-push']}.pushInsteadOf",
                 str(remotes["default-push"]))
        self.git("config", f"url.{remotes['fetch']}.pushInsteadOf",
                 str(remotes["branch-push"]))
        result = self.fixture.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Git URL rewrite", result.stderr)
        self.assert_push_tips(remotes)

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

    def test_newline_in_rewrite_subsection_fails_closed(self):
        reviewed, redirected = self.destinations("redirected-\nremote")
        with (self.fixture.repo / ".git/config").open("a") as config:
            config.write(f'\n[url "{redirected}"]\n\tpushInsteadOf = {reviewed}\n')
        t = self.fixture
        (t.bin / "git").unlink()
        result = t.run_wrapper()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("push", t.events())

    def test_resolved_url_cannot_name_another_remote(self):
        reviewed, redirected = self.destinations()
        self.git("config", "remote.origin.url", "destination")
        self.git("config", "remote.destination.url", str(reviewed))
        self.git("config", "remote.destination.pushurl", str(redirected))
        self.assert_rewrite_blocked(reviewed, redirected, "configured remote")

    def test_resolved_url_cannot_name_a_global_remote(self):
        reviewed, redirected = self.destinations()
        self.git("config", "remote.origin.url", "destination")
        self.git("config", "--global", "remote.destination.url", str(reviewed))
        self.git("config", "--global", "remote.destination.pushurl", str(redirected))
        self.assert_rewrite_blocked(reviewed, redirected, "configured remote")

    def test_remote_alias_added_during_review_cannot_change_the_endpoint(self):
        reviewed, redirected = self.destinations()
        t = self.fixture
        (t.repo / "destination").symlink_to(reviewed, target_is_directory=True)
        self.git("config", "remote.origin.url", "destination")
        t.env.update(REVIEWED_REMOTE=str(reviewed), REDIRECT_REMOTE=str(redirected))
        t.write(t.scripts / "codex-review-gate.sh", '''#!/bin/bash
printf 'gate\\n' >> "$CALLS"
git config --global remote.destination.url "$REVIEWED_REMOTE"
git config --global remote.destination.pushurl "$REDIRECT_REMOTE"
''')
        self.assert_rewrite_blocked(reviewed, redirected, "configured remote")

    def test_remote_alias_with_multiple_push_urls_is_rejected(self):
        reviewed, redirected = self.destinations()
        self.git("config", "remote.origin.url", "destination")
        self.git("config", "remote.destination.url", str(reviewed))
        self.git("config", "--add", "remote.destination.pushurl", str(reviewed))
        self.git("config", "--add", "remote.destination.pushurl", str(redirected))
        self.assert_rewrite_blocked(reviewed, redirected, "configured remote")


if __name__ == "__main__":
    unittest.main()
