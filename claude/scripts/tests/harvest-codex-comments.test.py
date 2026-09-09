#!/usr/bin/env python3
"""Exercise issue creation against a disposable gh transport; never contacts GitHub."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "harvest-codex-comments.sh"
LABEL_ERROR = {"resource": "Issue", "field": "labels", "code": "invalid"}
TITLE_ERROR = {"resource": "Issue", "field": "title", "code": "missing_field"}

GH = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
endpoint = args[1]
config = json.loads(pathlib.Path(os.environ["HARVEST_FIXTURE"]).read_text())
if endpoint.endswith("/comments"):
    print(json.dumps([{"id": 123, "path": "file.sh", "line": 1, "position": 1,
        "user": {"login": "chatgpt-codex-connector[bot]"}, "body": "Review finding"}]))
elif "issues?" in endpoint:
    print(config.get("existing", ""))
elif endpoint == "graphql":
    pass
elif endpoint.endswith("/issues"):
    labeled = "labels[]=codex-finding" in args
    with open(os.environ["HARVEST_POSTS"], "a") as log:
        log.write(json.dumps({"labeled": labeled, "args": args}) + "\n")
    status = config["status"] if labeled else 201
    body = config["body"] if labeled else {"html_url": "https://example.test/issues/1"}
    if "--include" in args and status is not None:
        sys.stdout.write(f"HTTP/2.0 {status} Response\r\nContent-Type: application/json\r\n\r\n")
    if "--jq" in args and status == 201:
        print(body["html_url"])
    else:
        print(body if isinstance(body, str) else json.dumps(body))
    sys.exit(config.get("exit", 0 if status == 201 else 1) if labeled else 0)
else:
    raise SystemExit("Unexpected gh call: " + repr(args))
'''


class HarvestTests(unittest.TestCase):
    def run_case(self, status, body, *, extra=(), **config):
        with tempfile.TemporaryDirectory(prefix="harvest-test-") as temp:
            root = Path(temp)
            gh = root / "gh"
            gh.write_text(GH)
            gh.chmod(0o755)
            fixture = root / "response.json"
            fixture.write_text(json.dumps({"status": status, "body": body, **config}))
            posts = root / "posts.jsonl"
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "HARVEST_FIXTURE": str(fixture), "HARVEST_POSTS": str(posts)}
            result = subprocess.run(
                ["bash", str(SCRIPT), "--repo", "example/repo", "--pr", "1", *extra],
                env=env, capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in posts.read_text().splitlines()] if posts.exists() else []
            return calls, result

    def test_success_creates_once(self):
        calls, result = self.run_case(201, {"html_url": "https://example.test/issues/1"})
        self.assertEqual([c["labeled"] for c in calls], [True])
        self.assertIn("filed: https://example.test/issues/1", result.stdout)

    def test_label_validation_retries_unlabeled(self):
        for error in [LABEL_ERROR, {"resource": "Label", "field": "name", "code": "invalid"}]:
            with self.subTest(error=error):
                calls, result = self.run_case(422, {"message": "Validation Failed", "errors": [error]})
                self.assertEqual([c["labeled"] for c in calls], [True, False])
                self.assertIn("filed: https://example.test/issues/1", result.stdout)

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
                self.assertIn("could not file issue", result.stderr)

    def test_dry_run_and_existing_marker_never_post(self):
        for config in [{"extra": ["--dry-run"]}, {"existing": "codex-comment-id:example/repo#1:123"}]:
            with self.subTest(config=config):
                calls, _ = self.run_case(201, {}, **config)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
