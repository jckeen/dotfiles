#!/usr/bin/env python3
"""Property tests for receipt tier classification and receipt tamper rejection.

`classify_tier` decides whether a diff may take the reduced-ceremony tier-1 path,
so a wrong tier-1 silently skips the review entirely. The oracle below is written
from the risk list (review-receipt.py `risk`) and the tier rules (`classify_tier`)
rather than by calling those helpers: an oracle built from the implementation
agrees with whatever bug the implementation has.

The tamper suite builds one real receipt from real Git objects, then perturbs a
single JSON leaf and asserts `check` refuses it.
"""

import fnmatch
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

try:
    from hypothesis import HealthCheck, given, settings
    from hypothesis import strategies as st
except ImportError:
    raise SystemExit(
        "Hypothesis is required by the property suites. Install it with:\n"
        "  python3 -m pip install --user -r claude/scripts/tests/requirements-property.txt"
    ) from None

SCRIPTS = Path(__file__).resolve().parents[1]
HELPER = SCRIPTS / "review-receipt.py"
spec = importlib.util.spec_from_file_location("receipt", HELPER)
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)

# ─── The oracle: an independent restatement of the tier-2 surface ─────────────
# Transcribed from review-receipt.py's risk list and docs test, NOT imported from
# it. Keep in sync by hand; a divergence is exactly what these tests report.
RISK_WORDS = (
    "auth",
    "token",
    "secret",
    "credential",
    "password",
    "session",
    "sso",
    "crypt",
    "hash",
    "host",
    "schema",
    "migration",
)
RISK_GLOBS = ("*AGENTPACK*", ".github/*", "*/.github/*", "*hooks/*", "*.githooks*", "*scripts/*")
DOC_SUFFIXES = (".md", ".markdown", ".rst")
DOC_NAMES = ("LICENSE", "LICENSE.txt")
PASSIVE_MODES = ("missing", "100644")
ACTIVE_MODES = ("100755", "120000", "160000", "040000")

# Path segments are drawn from letters that cannot spell any RISK_WORDS entry:
# dropping s, a, o and y removes at least one letter from every one of the twelve.
# The segments also carry no dot and no slash, so a generated "safe" path can
# match no RISK_GLOBS entry and no instruction path either -- every namespace and
# instruction layout in review-receipt.py needs one of those letters, a leading
# dot, or uppercase. test_safe_paths_carry_no_risk_marker pins that reasoning.
SAFE_LETTERS = "bcdefghijklmnpqrtuvwxz0123456789"
SAFE_SEGMENT = st.text(alphabet=SAFE_LETTERS, min_size=1, max_size=6)
GLOB_RISK_PATHS = (
    ".github/notes.md",
    "x/.github/notes.md",
    "hooks/notes.md",
    "x/hooks/notes.md",
    "scripts/notes.md",
    "x/scripts/notes.md",
    "AGENTPACK.md",
    "x/AGENTPACK-notes.md",
)


def basename(path):
    return path.rsplit("/", 1)[-1]


def oracle_risky(path):
    lower = path.lower()
    if any(word in lower for word in RISK_WORDS):
        return True
    return any(fnmatch.fnmatchcase(path, glob) for glob in RISK_GLOBS)


def oracle_docsafe(path):
    if oracle_risky(path):
        return False
    return path.endswith(DOC_SUFFIXES) or basename(path) in DOC_NAMES


def oracle_tier(artifact, patch, policy):
    """Return the tier `classify_tier` must return, in its documented order."""
    cap = policy["tier1_max_lines"]
    if re.fullmatch(r"[0-9]+", cap) is None:
        return 2
    lines = patch.count(b"\n")
    if lines > int(cap):
        return 2
    if not artifact["changed_paths"]:
        return 2
    for path in artifact["changed_paths"]:
        modes = artifact["changed_modes"][path]
        if not all(mode in PASSIVE_MODES for mode in modes):
            return 2
        if not oracle_docsafe(path):
            return 2
    return 1


# ─── Strategies ──────────────────────────────────────────────────────────────
@st.composite
def safe_doc_paths(draw):
    """A docs path with no risk marker: must be eligible for tier 1."""
    depth = draw(st.integers(min_value=0, max_value=3))
    parts = [draw(SAFE_SEGMENT) for _ in range(depth)]
    name = draw(
        st.one_of(
            st.builds(
                lambda stem, suffix: stem + suffix, SAFE_SEGMENT, st.sampled_from(DOC_SUFFIXES)
            ),
            st.sampled_from(DOC_NAMES),
        )
    )
    return "/".join(parts + [name])


@st.composite
def safe_nondoc_paths(draw):
    """A non-docs path with no risk marker: unclassified, so never tier 1."""
    base = draw(safe_doc_paths())
    suffix = draw(st.sampled_from((".txt", ".py", ".json", ".yaml", "")))
    return base.rsplit(".", 1)[0] + suffix if "." in basename(base) else base + suffix


@st.composite
def risky_paths(draw):
    """A path carrying a risk word or matching a risk glob: never tier 1."""
    if draw(st.booleans()):
        base = draw(safe_doc_paths())
        word = draw(st.sampled_from(RISK_WORDS))
        head, _, name = base.rpartition("/")
        return (head + "/" if head else "") + word + name
    return draw(st.sampled_from(GLOB_RISK_PATHS))


@st.composite
def classification_inputs(draw):
    """A (artifact, patch, policy) triple spanning both tiers."""
    paths = draw(
        st.lists(
            st.one_of(safe_doc_paths(), safe_nondoc_paths(), risky_paths()),
            min_size=0,
            max_size=4,
            unique=True,
        )
    )
    modes = {}
    for path in paths:
        modes[path] = draw(
            st.lists(
                st.sampled_from(PASSIVE_MODES + ACTIVE_MODES),
                min_size=1,
                max_size=2,
            )
        )
    cap = draw(st.sampled_from(("0", "1", "5", "200", "0500", "999999")))
    lines = draw(st.integers(min_value=0, max_value=12))
    artifact = {"changed_paths": paths, "changed_modes": modes}
    return artifact, b"x\n" * lines, {"tier1_max_lines": cap}


def artifact_for(paths, modes):
    return {"changed_paths": list(paths), "changed_modes": {p: list(modes) for p in paths}}


class TierClassificationProperties(unittest.TestCase):
    """classify_tier must agree with the oracle and never over-grant tier 1."""

    @given(path=safe_doc_paths())
    def test_safe_paths_carry_no_risk_marker(self, path):
        # Guards the alphabet reasoning above: if this ever fails, the "safe"
        # strategy stopped being safe and the tier-1 tests below became vacuous.
        self.assertFalse(oracle_risky(path))
        self.assertTrue(oracle_docsafe(path))

    @given(inputs=classification_inputs())
    @settings(deadline=None)
    def test_classification_matches_the_independent_oracle(self, inputs):
        artifact, patch, policy = inputs
        result = receipt.classify_tier(artifact, patch, policy)
        self.assertIn(result["tier"], (1, 2))
        self.assertIsInstance(result["reason"], str)
        self.assertTrue(result["reason"])
        self.assertEqual(result["tier"], oracle_tier(artifact, patch, policy))

    @given(
        paths=st.lists(safe_doc_paths(), min_size=1, max_size=4, unique=True),
        modes=st.lists(st.sampled_from(PASSIVE_MODES), min_size=1, max_size=2),
        lines=st.integers(min_value=0, max_value=200),
    )
    @settings(deadline=None)
    def test_passive_safe_docs_within_the_cap_are_tier_1(self, paths, modes, lines):
        result = receipt.classify_tier(
            artifact_for(paths, modes),
            b"x\n" * lines,
            {"tier1_max_lines": "200"},
        )
        self.assertEqual(result["tier"], 1, result["reason"])

    @given(
        paths=st.lists(safe_doc_paths(), min_size=1, max_size=4, unique=True),
        modes=st.lists(st.sampled_from(PASSIVE_MODES), min_size=1, max_size=2),
        excess=st.integers(min_value=1, max_value=50),
    )
    @settings(deadline=None)
    def test_a_diff_over_the_cap_is_tier_2(self, paths, modes, excess):
        result = receipt.classify_tier(
            artifact_for(paths, modes),
            b"x\n" * (200 + excess),
            {"tier1_max_lines": "200"},
        )
        self.assertEqual(result["tier"], 2)

    @given(
        path=risky_paths(),
        modes=st.lists(st.sampled_from(PASSIVE_MODES), min_size=1, max_size=2),
    )
    @settings(deadline=None)
    def test_a_risk_path_is_tier_2(self, path, modes):
        result = receipt.classify_tier(
            artifact_for([path], modes),
            b"",
            {"tier1_max_lines": "200"},
        )
        self.assertEqual(result["tier"], 2)

    @given(
        path=safe_doc_paths(),
        active=st.sampled_from(ACTIVE_MODES),
        other=st.sampled_from(PASSIVE_MODES + ACTIVE_MODES),
    )
    @settings(deadline=None)
    def test_an_active_mode_is_tier_2(self, path, active, other):
        result = receipt.classify_tier(
            artifact_for([path], [other, active]),
            b"",
            {"tier1_max_lines": "200"},
        )
        self.assertEqual(result["tier"], 2)

    @given(lines=st.integers(min_value=0, max_value=50))
    @settings(deadline=None)
    def test_an_empty_path_list_is_tier_2(self, lines):
        # Enumeration failed: nothing is known about the diff, so nothing is safe.
        result = receipt.classify_tier(
            {"changed_paths": [], "changed_modes": {}},
            b"x\n" * lines,
            {"tier1_max_lines": "200"},
        )
        self.assertEqual(result["tier"], 2)

    @given(cap=st.one_of(st.integers(), st.none(), st.booleans(), st.binary(max_size=4)))
    @settings(deadline=None)
    def test_a_non_string_cap_is_refused(self, cap):
        with self.assertRaises(ValueError):
            receipt.classify_tier(
                artifact_for(["notes.md"], ["missing", "100644"]),
                b"",
                {"tier1_max_lines": cap},
            )

    @given(cap=st.text(max_size=6).filter(lambda value: re.fullmatch(r"[0-9]+", value) is None))
    @settings(deadline=None)
    def test_a_non_numeric_cap_keeps_the_full_pass(self, cap):
        result = receipt.classify_tier(
            artifact_for(["notes.md"], ["missing", "100644"]),
            b"",
            {"tier1_max_lines": cap},
        )
        self.assertEqual(result["tier"], 2)


def leaf_keys(node, prefix=()):
    """Every scalar leaf of a JSON document, as dotted paths."""
    if isinstance(node, dict):
        for key, value in node.items():
            for found in leaf_keys(value, prefix + (key,)):
                yield found
    elif isinstance(node, list):
        for index, value in enumerate(node):
            for found in leaf_keys(value, prefix + (index,)):
                yield found
    else:
        yield prefix


class ReceiptTamperProperties(unittest.TestCase):
    """A receipt whose integrity-bearing leaves changed must not validate."""

    # The receipt deliberately does not bind these leaves. review-receipt.py's
    # module docstring scopes out forgery by the filesystem owner, and none of
    # them changes WHICH content was reviewed -- the artifact hashes do that.
    # `check` only requires the reviewer fields to be a string or null, and the
    # captured policy gates nothing for a 'passed' outcome. Every other leaf is
    # integrity-bearing and must be refused.
    # Keyed by container path, not by a dotted string: a changed path is itself a
    # dict key and carries dots of its own (artifact.changed_modes['code.txt']).
    AUDIT_METADATA = frozenset(
        {
            ("policy", "tier1_max_lines"),
            ("reviewer", "executable"),
            ("reviewer", "model_evidence"),
            ("reviewer", "observed_model"),
            ("reviewer", "requested_model"),
        }
    )

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.repo = Path(cls.tmp) / "repo"
        cls.repo.mkdir()
        cls._git("init", "-q", "-b", "main")
        cls._git("config", "user.name", "fixture")
        cls._git("config", "user.email", "fixture@example.test")
        (cls.repo / "code.txt").write_text("base\n")
        cls._git("add", "code.txt")
        cls._git("commit", "-qm", "base")
        cls._git("checkout", "-qb", "feature")
        (cls.repo / "code.txt").write_text("changed\n")
        cls._git("commit", "-qam", "work")

        output = Path(cls.tmp) / "result.json"
        output.write_text('{"verdict":"approve","findings":[]}')
        run = cls._helper(
            "begin",
            "--repo",
            str(cls.repo),
            "--base",
            "main",
            "--scope",
            "committed",
            "--reviewer",
            "codex",
        )
        assert run.returncode == 0, run.stdout + run.stderr
        snapshot = Path(run.stdout.strip()) / "snapshot.json"
        run = cls._helper(
            "complete", "--snapshot", str(snapshot), "--outcome", "passed", "--output", str(output)
        )
        assert run.returncode == 0, run.stdout + run.stderr

        cls.head = cls._git("rev-parse", "HEAD")
        receipts = Path(cls._git("rev-parse", "--git-path", "review-receipts"))
        if not receipts.is_absolute():
            receipts = cls.repo / receipts
        cls.receipt_path = receipts / "codex.json"
        cls.original = cls.receipt_path.read_bytes()
        record = json.loads(cls.original)
        cls.leaves = sorted(
            (leaf for leaf in leaf_keys(record) if leaf not in cls.AUDIT_METADATA),
            key=lambda leaf: tuple(str(part) for part in leaf),
        )
        assert cls.leaves, "no integrity-bearing receipt leaves were found"
        assert cls._check().returncode == 0, "the untampered fixture receipt must validate"

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def _git(cls, *args):
        return (
            subprocess.check_output(
                ["git", "-C", str(cls.repo), *args],
                stderr=subprocess.PIPE,
            )
            .decode()
            .strip()
        )

    @classmethod
    def _helper(cls, *args):
        return subprocess.run(
            [sys.executable, str(HELPER), *args],
            capture_output=True,
            text=True,
            check=False,
        )

    @classmethod
    def _check(cls):
        return cls._helper(
            "check", "--repo", str(cls.repo), "--head", cls.head, "--reviewer", "codex"
        )

    @staticmethod
    def _perturb(value, replacement):
        if isinstance(value, bool):
            return not value
        if isinstance(value, int):
            return value + 1
        if isinstance(value, float):
            return value + 1.0
        if isinstance(value, str):
            return value + replacement
        return replacement

    # The fixture is built once per class and every example restores it, so the
    # subprocess cost is one `check` per example rather than a whole repository.
    # The leaf is chosen by index because the leaf list only exists once
    # setUpClass has run, after the strategies are built.
    @given(
        index=st.integers(min_value=0, max_value=2**16),
        replacement=st.text(alphabet="xyz123", min_size=1, max_size=4),
    )
    @settings(deadline=None, max_examples=60, suppress_health_check=[HealthCheck.too_slow])
    def test_perturbing_an_integrity_leaf_is_refused(self, index, replacement):
        leaf = self.leaves[index % len(self.leaves)]
        record = json.loads(self.original)
        target = record
        for key in leaf[:-1]:
            target = target[key]
        target[leaf[-1]] = self._perturb(target[leaf[-1]], replacement)

        self.receipt_path.write_bytes(json.dumps(record).encode() + b"\n")
        try:
            run = self._check()
        finally:
            self.receipt_path.write_bytes(self.original)
        leaf_name = ".".join(str(part) for part in leaf)
        self.assertNotEqual(
            run.returncode,
            0,
            f"check accepted a receipt whose {leaf_name} was changed: {run.stdout}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
