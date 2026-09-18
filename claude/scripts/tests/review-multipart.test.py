#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("transport", SCRIPTS / "review-multipart.py")
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


class TransportTests(unittest.TestCase):
    def test_complete_utf8_packet_and_fences(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            text = "gate instructions\n" + ("😀\nUNTRUSTED_DIFF_marker\n" * 60000) + "last byte\n"
            packet = directory / "request"
            packet.write_text(text)
            (directory / "catalog.json").write_text("{}")
            transport.prepare(packet, directory)
            manifest = json.loads((directory / "manifest.json").read_text())
            fragments = []
            for index, part in enumerate(manifest["parts"], 1):
                value = (directory / f"part-{index}.txt").read_bytes().decode("utf-8")
                fence = value.split("Fragment fence: ", 1)[1].split("\n", 1)[0]
                self.assertEqual(value.count("\n" + fence + "\n"), 2)
                fragment = value.split("\n" + fence + "\n")[1]
                self.assertEqual(transport.digest(fragment.encode()), part["sha256"])
                self.assertLess(len(value.encode()), 1048576)
                fragments.append(fragment)
            self.assertEqual("".join(fragments), text)
            self.assertEqual(manifest["sha256"], transport.digest(packet.read_bytes()))

    def test_fragments_are_bounded_by_utf8_bytes_not_characters(self):
        # A character-sliced fragment of 4-byte characters reaches four times
        # the intended size; the receiving model is sized in tokens, so the
        # bound has to be UTF-8 bytes (#420).
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            packet = directory / "request"
            text = "\U0001f600" * transport.FRAGMENT_BYTES
            packet.write_text(text)
            (directory / "catalog.json").write_text("{}")
            transport.prepare(packet, directory)
            manifest = json.loads((directory / "manifest.json").read_text())
            self.assertGreater(len(manifest["parts"]), 1)
            fragments = []
            for index, part in enumerate(manifest["parts"], 1):
                value = (directory / f"part-{index}.txt").read_bytes().decode("utf-8")
                fence = value.split("Fragment fence: ", 1)[1].split("\n", 1)[0]
                fragment = value.split("\n" + fence + "\n")[1]
                self.assertLessEqual(len(fragment.encode()), transport.FRAGMENT_BYTES)
                self.assertEqual(transport.digest(fragment.encode()), part["sha256"])
                fragments.append(fragment)
            self.assertEqual("".join(fragments), text)

    def test_fragment_boundary_never_splits_a_multibyte_character(self):
        # The cap lands two bytes into a 4-byte character: the split backs off
        # to the character boundary instead of emitting invalid UTF-8.
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            packet = directory / "request"
            text = "a" * (transport.FRAGMENT_BYTES - 2) + "\U0001f600" * 100
            packet.write_text(text)
            (directory / "catalog.json").write_text("{}")
            transport.prepare(packet, directory)
            manifest = json.loads((directory / "manifest.json").read_text())
            fragments = []
            for index in range(1, len(manifest["parts"]) + 1):
                value = (directory / f"part-{index}.txt").read_bytes().decode("utf-8")
                fence = value.split("Fragment fence: ", 1)[1].split("\n", 1)[0]
                fragment = value.split("\n" + fence + "\n")[1]
                self.assertLessEqual(len(fragment.encode()), transport.FRAGMENT_BYTES)
                # Each fragment stands alone as valid UTF-8, so a split that
                # landed mid-character would round-trip differently.
                self.assertEqual(fragment.encode().decode("utf-8"), fragment)
                fragments.append(fragment)
            self.assertTrue(fragments[0].endswith("a"))
            self.assertEqual("".join(fragments), text)

    def test_native_input_check_preserves_crlf_and_bare_carriage_returns(self):
        for ending in ("\r\n", "\r"):
            with self.subTest(ending=repr(ending)), tempfile.TemporaryDirectory() as name:
                directory = Path(name)
                packet = directory / "request"
                raw = ("gate header\n" + ("changed line" + ending) * 100000 + "last byte\n").encode(
                    "utf-8"
                )
                self.assertGreater(len(raw), 1048576)
                packet.write_bytes(raw)
                catalog = {
                    "models": [
                        {
                            "slug": "fixture",
                            "max_context_window": 872000,
                            "effective_context_window_percent": 95,
                        }
                    ]
                }
                (directory / "catalog.json").write_bytes(json.dumps(catalog).encode("utf-8"))
                transport.prepare(packet, directory)
                manifest_bytes = (directory / "manifest.json").read_bytes()
                count = len(json.loads(manifest_bytes)["parts"])
                session = "11111111-1111-4111-8111-111111111111"
                records = []
                fragments = []
                for index in range(1, count + 1):
                    value = (directory / f"part-{index}.txt").read_bytes().decode("utf-8")
                    fence = value.split("Fragment fence: ", 1)[1].split("\n", 1)[0]
                    fragments.append(value.split("\n" + fence + "\n")[1])
                    records.extend(
                        [
                            {
                                "type": "response_item",
                                "payload": {
                                    "role": "user",
                                    "content": [{"type": "input_text", "text": value}],
                                },
                            },
                            {
                                "type": "turn_context",
                                "payload": {
                                    "model": "fixture",
                                    "sandbox_policy": {"type": "read-only"},
                                },
                            },
                            {
                                "type": "event_msg",
                                "payload": {
                                    "type": "token_count",
                                    "info": {"model_context_window": 828400},
                                },
                            },
                        ]
                    )
                self.assertEqual("".join(fragments).encode("utf-8"), raw)
                events = [
                    {"type": "thread.started", "thread_id": session},
                    {"type": "turn.completed"},
                ]
                (directory / "events.jsonl").write_bytes(
                    "\n".join(json.dumps(event) for event in events).encode("utf-8")
                )
                # Native JSON escapes carriage returns, so decoding it preserves
                # the exact input; neither fixture nor checker may normalize it.
                recorded = json.loads(json.dumps(records))
                with mock.patch.object(transport, "session_records", return_value=recorded):
                    transport.check(directory, count, session, transport.digest(manifest_bytes))
                recorded[0]["payload"]["content"][0]["text"] = (
                    recorded[0]["payload"]["content"][0]["text"]
                    .replace("\r\n", "\n")
                    .replace("\r", "\n")
                )
                with mock.patch.object(transport, "session_records", return_value=recorded):
                    with self.assertRaisesRegex(ValueError, "missing or substituted"):
                        transport.check(directory, count, session, transport.digest(manifest_bytes))

                for previous in range(1, count):
                    with self.subTest(previous_part=previous):
                        path = directory / f"part-{previous}.txt"
                        original = path.read_bytes()
                        changed = original + b"Injected replacement of earlier input"
                        recorded = json.loads(json.dumps(records))
                        recorded[(previous - 1) * 3]["payload"]["content"][0]["text"] = (
                            changed.decode("utf-8")
                        )
                        path.write_bytes(changed)
                        try:
                            self.assertEqual(
                                (directory / "manifest.json").read_bytes(), manifest_bytes
                            )
                            with mock.patch.object(
                                transport, "session_records", return_value=recorded
                            ):
                                with self.assertRaisesRegex(ValueError, "transport input changed"):
                                    transport.check(
                                        directory, count, session, transport.digest(manifest_bytes)
                                    )
                        finally:
                            path.write_bytes(original)

    def test_whitespace_check_is_linear_and_fail_closed(self):
        script = (SCRIPTS / "codex-review-gate.sh").read_text()
        block = script.split("<<'PYSPACE'\n", 1)[1].split("\nPYSPACE", 1)[0]
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "diff"
            for data, expected in ((b" \t\n\r\v\f" * 400000, "0"), (b" " * 2400000 + b"x", "1")):
                path.write_bytes(data)
                result = subprocess.run(
                    ["python3", "-c", block, str(path)], capture_output=True, text=True, timeout=5
                )
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), expected)
            path.unlink()
            result = subprocess.run(
                ["python3", "-c", block, str(path)], capture_output=True, timeout=5
            )
            self.assertNotEqual(result.returncode, 0)

    def test_native_history_missing_compacted_or_widened_cannot_pass(self):
        catalog = {
            "models": [
                {
                    "slug": "fixture",
                    "max_context_window": 872000,
                    "effective_context_window_percent": 95,
                }
            ]
        }
        records = [
            {
                "type": "response_item",
                "payload": {
                    "role": "user",
                    "content": [{"type": "input_text", "text": "exact input"}],
                },
            },
            {
                "type": "turn_context",
                "payload": {"model": "fixture", "sandbox_policy": {"type": "read-only"}},
            },
            {
                "type": "event_msg",
                "payload": {"type": "token_count", "info": {"model_context_window": 258400}},
            },
        ]
        self.assertEqual(transport.audit_history(records, ["exact input"], catalog), 872000)
        for corrupt in [
            records + [{"type": "compacted", "payload": {}}],
            records[1:],
            records + [{"type": "future_history_replacement"}],
        ]:
            with self.assertRaises(ValueError):
                transport.audit_history(corrupt, ["exact input"], catalog)
        records[1]["payload"]["sandbox_policy"] = {"type": "workspace-write"}
        with self.assertRaises(ValueError):
            transport.audit_history(records, ["exact input"], catalog)

    def test_fragment_fence_collision_is_lengthened(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            fence = "REVIEW_PART_" + "0" * 64
            packet = directory / "request"
            packet.write_text(fence + "\n" + fence + "_\n")
            (directory / "catalog.json").write_text("{}")
            with mock.patch.object(transport, "digest", return_value="0" * 64):
                transport.prepare(packet, directory)
            value = (directory / "part-1.txt").read_text()
            self.assertIn("Fragment fence: " + fence + "__\n", value)
            self.assertEqual(value.count("\n" + fence + "__\n"), 2)

    def test_invalid_utf8_fails_without_parts(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            packet = directory / "request"
            packet.write_bytes(b"\xff")
            with self.assertRaises(UnicodeDecodeError):
                transport.prepare(packet, directory)
            self.assertFalse(list(directory.glob("part-*")))


if __name__ == "__main__":
    unittest.main()
