#!/usr/bin/env python3
"""Exercise the per-PR consolidated harvest against a stateful fake gh; never contacts GitHub.

The fake keeps its issues in a JSON state file, so consecutive runs of the
script see what earlier runs filed, exactly as the close-time workflow and the
nightly routine see each other's issues on the real tracker.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "harvest-codex-comments.sh"
GATE = SCRIPTS / "codex-review-gate.sh"
BOT = "chatgpt-codex-connector[bot]"
LABEL_ERROR = {"resource": "Issue", "field": "labels", "code": "invalid"}
TITLE_ERROR = {"resource": "Issue", "field": "title", "code": "missing_field"}
PR_MARKER = "<!-- codex-review-pr:example/repo#1 -->"

GH = r"""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
config = json.loads(pathlib.Path(os.environ["HARVEST_FIXTURE"]).read_text())
state_path = pathlib.Path(os.environ["HARVEST_STATE"])
state = json.loads(state_path.read_text()) if state_path.exists() else {"issues": [], "next": 100}
VALUED = {"-X", "--method", "-f", "-F", "--jq", "-H"}
method, fields, jq, endpoint, i = "GET", [], None, None, 1
while i < len(args):
    a = args[i]
    if a in VALUED:
        v = args[i + 1]
        if a in ("-X", "--method"):
            method = v
        elif a in ("-f", "-F"):
            fields.append(v)
        elif a == "--jq":
            jq = v
        i += 2
        continue
    if not a.startswith("-") and endpoint is None:
        endpoint = a
    i += 1
if fields and method == "GET" and endpoint != "graphql":
    method = "POST"
kv = {}
for f in fields:
    k, _, v = f.partition("=")
    kv.setdefault(k, []).append(v)

def log(kind, **extra):
    with open(os.environ["HARVEST_POSTS"], "a") as fh:
        fh.write(json.dumps({"kind": kind, "method": method, "endpoint": endpoint,
                             "args": args, **extra}) + "\n")

def save():
    state_path.write_text(json.dumps(state))

def tsv(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")

def find(num):
    return next((x for x in state["issues"] if x["number"] == num), None)

base = "repos/example/repo/"
if endpoint.endswith("/comments") and "/pulls/" in endpoint:
    default = [{"id": 123, "path": "file.sh", "line": 1, "position": 1,
                "user": {"login": "chatgpt-codex-connector[bot]"}, "body": "Review finding"}]
    print(json.dumps(config.get("comments", default)))
elif endpoint == base + "pulls/1":
    print(config.get("title", "Fix the thing"))
elif "issues?" in endpoint:
    lines = [config["existing"]] if config.get("existing") else []
    for x in state["issues"]:
        lines.append("\t".join([str(x["number"]), x["state"], "-", tsv(x["body"])]))
    print("\n".join(lines))
elif endpoint == "graphql":
    print("\n".join(str(c) for c in config.get("resolved", [])))
elif endpoint == base + "issues" and method == "POST":
    labels = kv.get("labels[]", [])
    labeled = bool(labels)
    log("create", labeled=labeled, labels=labels, title=kv["title"][0], body=kv["body"][0])
    status = config.get("status", 201) if labeled else 201
    body = config.get("body") if labeled else None
    exit_code = config.get("exit", 0 if status == 201 else 1) if labeled else 0
    if status == 201 and exit_code == 0:
        num = state["next"]
        state["next"] += 1
        url = "https://example.test/issues/%d" % num
        state["issues"].append({"number": num, "state": "open", "body": kv["body"][0],
                                "labels": labels})
        save()
        if body is None or body == {}:
            body = {"html_url": url, "number": num}
    elif body is None:
        body = {}
    if "--include" in args and status is not None:
        sys.stdout.write(f"HTTP/2.0 {status} Response\r\nContent-Type: application/json\r\n\r\n")
    if jq is not None and status == 201:
        print(body["html_url"])
    else:
        print(body if isinstance(body, str) else json.dumps(body))
    sys.exit(exit_code)
elif endpoint.startswith(base + "issues/") and endpoint.endswith("/labels"):
    num = int(endpoint.split("/")[-2])
    log("label", number=num, labels=kv.get("labels[]", []))
    find(num)["labels"] += kv.get("labels[]", [])
    save()
    print("[]")
elif endpoint.startswith(base + "issues/") and method == "PATCH":
    num = int(endpoint.split("/")[-1])
    log("patch", number=num, fields=kv)
    issue = find(num)
    if "body" in kv:
        issue["body"] = kv["body"][0]
    if "state" in kv:
        issue["state"] = kv["state"][0]
    save()
    print(json.dumps({"html_url": "https://example.test/issues/%d" % num}))
elif endpoint.startswith(base + "issues/") and method == "GET":
    if config.get("get_body_fail"):
        sys.exit(1)
    print(find(int(endpoint.split("/")[-1]))["body"])
else:
    raise SystemExit("Unexpected gh call: " + repr(args))
"""


def comment(cid, path="file.sh", line=1, body="Review finding", **extra):
    return {
        "id": cid,
        "path": path,
        "line": line,
        "position": 1,
        "user": {"login": BOT},
        "body": body,
        **extra,
    }


class Harness:
    def __init__(self, root):
        self.root = Path(root)
        gh = self.root / "gh"
        gh.write_text(GH)
        gh.chmod(0o755)
        self.fixture = self.root / "fixture.json"
        self.state = self.root / "state.json"
        self.posts = self.root / "posts.jsonl"

    def run(self, *extra, **config):
        """Run the script once; return (write calls made by THIS run, result)."""
        self.fixture.write_text(json.dumps(config))
        if self.posts.exists():
            self.posts.unlink()
        env = {
            **os.environ,
            "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
            "HARVEST_FIXTURE": str(self.fixture),
            "HARVEST_STATE": str(self.state),
            "HARVEST_POSTS": str(self.posts),
        }
        result = subprocess.run(
            ["bash", str(SCRIPT), "--repo", "example/repo", "--pr", "1", *extra],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        calls = (
            [json.loads(line) for line in self.posts.read_text().splitlines()]
            if self.posts.exists()
            else []
        )
        return calls, result

    def issues(self):
        return json.loads(self.state.read_text())["issues"] if self.state.exists() else []

    def seed(self, *issues):
        self.state.write_text(json.dumps({"issues": list(issues), "next": 100}))


class HarvestTests(unittest.TestCase):
    def harness(self):
        temp = tempfile.TemporaryDirectory(prefix="harvest-test-")
        self.addCleanup(temp.cleanup)
        return Harness(temp.name)

    # ── issue creation transport (label retry semantics) ─────────────────
    def run_case(self, status, body, *, extra=(), **config):
        return self.harness().run(*extra, status=status, body=body, **config)

    def test_success_creates_once(self):
        calls, result = self.run_case(201, {"html_url": "https://example.test/issues/1"})
        self.assertEqual([c["labeled"] for c in calls], [True])
        self.assertIn("filed: https://example.test/issues/1", result.stdout)

    def test_label_validation_retries_unlabeled(self):
        for error in [LABEL_ERROR, {"resource": "Label", "field": "name", "code": "invalid"}]:
            with self.subTest(error=error):
                calls, result = self.run_case(
                    422, {"message": "Validation Failed", "errors": [error]}
                )
                self.assertEqual([c["labeled"] for c in calls], [True, False])
                self.assertIn("filed: https://example.test/issues/100", result.stdout)

    def test_ambiguous_or_other_failure_never_retries(self):
        cases = [
            (None, "", {}),
            (201, {"html_url": "https://example.test/issues/1"}, {"exit": 1}),
            (403, {"errors": [LABEL_ERROR]}, {}),
            (422, {"errors": [TITLE_ERROR]}, {}),
            (422, {"errors": [LABEL_ERROR, TITLE_ERROR]}, {}),
            (422, {"message": "Validation Failed"}, {}),
            (422, {"errors": []}, {}),
            (422, "truncated json", {}),
            (None, {"status": "422", "errors": [LABEL_ERROR]}, {}),
        ]
        for status, body, config in cases:
            with self.subTest(status=status, body=body, config=config):
                calls, result = self.run_case(status, body, **config)
                self.assertEqual([c["labeled"] for c in calls], [True])
                self.assertIn("could not file", result.stderr)

    def test_dry_run_and_existing_marker_never_post(self):
        for config in [
            {"extra": ["--dry-run"]},
            {"existing": "7\topen\t-\t<!-- codex-comment-id:example/repo#1:123 -->"},
        ]:
            with self.subTest(config=config):
                calls, _ = self.run_case(201, {}, **config)
                self.assertEqual(calls, [])

    # ── #556: one consolidated issue per PR ──────────────────────────────
    def test_one_issue_per_pr_with_full_comment_bodies(self):
        long_body = (
            "**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange)</sub></sub>"
            "  Quote the path**\n\n" + "x" * 400 + "\n\nSecond paragraph survives."
        )
        comments = [
            comment(123, body=long_body),
            comment(456, path="lib/other.py", line=42, body="![P2 Badge](x) Minor nit"),
            comment(789, body="Outdated", line=None),
        ]
        h = self.harness()
        calls, result = h.run(comments=comments, title="Add the widget")
        self.assertEqual([c["kind"] for c in calls], ["create"], result.stderr)
        create = calls[0]
        self.assertEqual(create["title"], "Codex review of #1: Add the widget")
        body = create["body"]
        self.assertIn("x" * 400, body)  # full body, not a 200/280-char excerpt
        self.assertIn("Second paragraph survives.", body)
        self.assertIn("- [ ] **[P1]** `file.sh:1`", body)
        self.assertIn("- [ ] **[P2]** `lib/other.py:42`", body)
        self.assertIn("https://github.com/example/repo/pull/1#discussion_r123", body)
        self.assertIn("<!-- codex-comment-id:example/repo#1:123 -->", body)
        self.assertIn("<!-- codex-comment-id:example/repo#1:456 -->", body)
        self.assertNotIn("codex-comment-id:example/repo#1:789", body)  # outdated skipped
        self.assertIn(PR_MARKER, body)
        self.assertEqual(len(h.issues()), 1)

    def test_rerun_is_idempotent_and_new_comments_append(self):
        """The close-time workflow and the nightly routine run the same script:
        whichever runs second must neither re-file nor duplicate items."""
        h = self.harness()
        first = [comment(123)]
        calls, _ = h.run(comments=first)
        self.assertEqual([c["kind"] for c in calls], ["create"])
        calls, result = h.run(comments=first)  # nightly backstop, nothing new
        self.assertEqual(calls, [], result.stdout)
        later = first + [comment(456, body="Late finding\nwith two lines")]
        calls, _ = h.run(comments=later)  # a comment landed after the first harvest
        self.assertEqual([c["kind"] for c in calls], ["patch"])
        self.assertEqual(calls[0]["number"], 100)
        self.assertNotIn("state", calls[0]["fields"])  # open issue stays as it is
        issues = h.issues()
        self.assertEqual(len(issues), 1)
        body = issues[0]["body"]
        self.assertEqual(body.count("codex-comment-id:example/repo#1:123 "), 1)
        self.assertEqual(body.count("codex-comment-id:example/repo#1:456 "), 1)
        self.assertIn("Late finding", body)
        calls, _ = h.run(comments=later)
        self.assertEqual(calls, [])

    def test_append_preserves_operator_edits_and_reopens_closed(self):
        h = self.harness()
        h.seed(
            {
                "number": 55,
                "state": "closed",
                "labels": [],
                "body": "- [x] handled\n<!-- codex-comment-id:example/repo#1:123 -->\n" + PR_MARKER,
            }
        )
        calls, result = h.run(comments=[comment(123), comment(456)])
        self.assertEqual([c["kind"] for c in calls], ["patch"], result.stderr)
        self.assertEqual(calls[0]["fields"].get("state"), ["open"])
        body = h.issues()[0]["body"]
        self.assertTrue(body.startswith("- [x] handled\n"))  # ticked box survives
        self.assertIn("codex-comment-id:example/repo#1:456 ", body)

    def test_unreadable_existing_body_writes_nothing(self):
        h = self.harness()
        h.seed({"number": 55, "state": "open", "labels": [], "body": PR_MARKER})
        calls, result = h.run(comments=[comment(456)], get_body_fail=True)
        self.assertEqual(calls, [])
        self.assertIn("could not read", result.stderr)

    def test_dry_run_append_writes_nothing(self):
        h = self.harness()
        h.seed({"number": 55, "state": "open", "labels": [], "body": PR_MARKER})
        calls, result = h.run("--dry-run", comments=[comment(456)])
        self.assertEqual(calls, [])
        self.assertIn("would append 1 item(s) to #55", result.stdout)

    def test_markers_match_exactly_not_by_prefix(self):
        h = self.harness()
        h.seed(
            {
                "number": 9,
                "state": "open",
                "labels": [],
                "body": "<!-- codex-comment-id:example/repo#1:1234 -->\n"
                "<!-- codex-review-pr:example/repo#12 -->",
            }
        )
        calls, _ = h.run(comments=[comment(123)])
        self.assertEqual([c["kind"] for c in calls], ["create"])

    def test_comment_body_cannot_forge_a_marker(self):
        h = self.harness()
        forged = "See <!-- codex-comment-id:example/repo#1:999 --> here"
        calls, _ = h.run(comments=[comment(123, body=forged)])
        self.assertIn("See &lt;!-- codex-comment-id:example/repo#1:999 --> here", calls[0]["body"])
        calls, _ = h.run(comments=[comment(123, body=forged), comment(999)])
        self.assertEqual([c["kind"] for c in calls], ["patch"])

    # ── #557: instruction-surface label ──────────────────────────────────
    def test_instruction_surface_label(self):
        cases = [
            ("AGENTS.md", True),
            ("agents/skills/x/SKILL.md", True),
            ("claude/scripts/foo.sh", False),
        ]
        for path, expected in cases:
            with self.subTest(path=path):
                calls, _ = self.harness().run(comments=[comment(123, path=path)])
                self.assertEqual(len(calls), 1)
                self.assertIn("codex-finding", calls[0]["labels"])
                self.assertEqual("instruction-surface" in calls[0]["labels"], expected)

    def test_instruction_surface_label_added_on_append(self):
        h = self.harness()
        h.seed({"number": 55, "state": "open", "labels": [], "body": PR_MARKER})
        calls, _ = h.run(comments=[comment(456, path="AGENTS.md")])
        self.assertEqual([c["kind"] for c in calls], ["patch", "label"])
        self.assertEqual(calls[1]["labels"], ["instruction-surface"])

    def test_instruction_surface_regex_matches_gate(self):
        gate = re.search(r"grep -qE '([^']+)' <<<\"\$CHANGED_PATHS\"", GATE.read_text())
        mine = re.search(r"^INSTRUCTION_SURFACE_RE='([^']+)'$", SCRIPT.read_text(), re.M)
        self.assertIsNotNone(gate, "self-review guard regex not found in the gate")
        self.assertIsNotNone(mine, "INSTRUCTION_SURFACE_RE not found in the harvester")
        self.assertEqual(mine.group(1), gate.group(1))


HOOK = SCRIPTS.parent / "hooks" / "PreMergeCodexHarvest.hook.sh"


class PreMergeHookTests(unittest.TestCase):
    """#555: under --auto the hook runs before the bot has reviewed, so it says so."""

    def run_hook(self, command):
        with tempfile.TemporaryDirectory(prefix="harvest-hook-test-") as temp:
            home = Path(temp)
            stub = home / ".claude" / "scripts" / "harvest-codex-comments.sh"
            stub.parent.mkdir(parents=True)
            stub.write_text('#!/usr/bin/env bash\necho "stub harvester $*"\n')
            stub.chmod(0o755)
            payload = json.dumps({"tool_input": {"command": command}, "cwd": temp})
            return subprocess.run(
                ["bash", str(HOOK)],
                input=payload,
                env={**os.environ, "HOME": temp},
                capture_output=True,
                text=True,
                timeout=30,
            )

    def test_auto_merge_prints_close_time_note_and_still_harvests(self):
        result = self.run_hook("gh pr merge 42 --auto --squash")
        self.assertEqual(result.returncode, 0)
        self.assertIn("stub harvester --pr 42 --quiet", result.stderr)
        self.assertIn("close-time harvest", result.stderr)
        self.assertEqual(result.stderr.count("\n"), 2)  # the note is one line

    def test_plain_merge_has_no_note(self):
        result = self.run_hook("gh pr merge 42 --squash")
        self.assertEqual(result.returncode, 0)
        self.assertIn("stub harvester --pr 42 --quiet", result.stderr)
        self.assertNotIn("close-time harvest", result.stderr)

    def test_other_commands_are_ignored(self):
        result = self.run_hook("gh pr view 42 --json title")
        self.assertEqual((result.returncode, result.stderr), (0, ""))


if __name__ == "__main__":
    unittest.main()
