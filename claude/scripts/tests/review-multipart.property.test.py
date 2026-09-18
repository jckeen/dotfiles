#!/usr/bin/env python3
"""Property tests for the multipart transport splitter (#419, #420, #444).

review-multipart.test.py pins specific packets. `fragment()` is pure -- bytes in,
UTF-8-safe text fragments out -- so the invariants below are stated for every
input instead: the fragments rejoin to the original, none exceeds the byte bound,
none is empty, and each is a contiguous slice of the original bytes rather than a
re-encoding. #444 changed the bound from characters to UTF-8 bytes, which is
exactly the kind of change a single hand-picked packet can pass by accident.
"""

import importlib.util
from pathlib import Path
import unittest
from unittest import mock

try:
    from hypothesis import given, settings
    from hypothesis import strategies as st
except ImportError:
    raise SystemExit(
        "Hypothesis is required by the property suites. Install it with:\n"
        "  python3 -m pip install --user -r claude/scripts/tests/requirements-property.txt"
    ) from None

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("transport", SCRIPTS / "review-multipart.py")
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)

# A UTF-8 character is at most 4 bytes, so 4 is the smallest bound that can hold
# any single character and the smallest that must always split successfully. The
# upper end stays small on purpose: it makes Hypothesis produce packets of many
# fragments, where the boundary arithmetic actually lives.
BOUNDS = st.integers(min_value=4, max_value=64)


class FragmentProperties(unittest.TestCase):
    """Invariants of the splitter for any text and any usable bound."""

    @given(text=st.text(), bound=BOUNDS)
    @settings(deadline=None)
    def test_fragments_rejoin_to_the_original(self, text, bound):
        with mock.patch.object(transport, "FRAGMENT_BYTES", bound):
            parts = transport.fragment(text.encode("utf-8"))
        self.assertEqual("".join(parts), text)

    @given(text=st.text(), bound=BOUNDS)
    @settings(deadline=None)
    def test_every_fragment_is_a_bounded_contiguous_byte_slice(self, text, bound):
        raw = text.encode("utf-8")
        with mock.patch.object(transport, "FRAGMENT_BYTES", bound):
            parts = transport.fragment(raw)
        offset = 0
        for position, part in enumerate(parts):
            chunk = part.encode("utf-8")
            self.assertNotEqual(chunk, b"", f"fragment {position} is empty")
            self.assertLessEqual(
                len(chunk),
                bound,
                f"fragment {position} exceeds the byte bound",
            )
            self.assertEqual(
                raw[offset : offset + len(chunk)],
                chunk,
                f"fragment {position} is not a contiguous slice of the packet",
            )
            offset += len(chunk)
        self.assertEqual(offset, len(raw), "the fragments do not cover the whole packet")

    @given(text=st.text(), bound=BOUNDS)
    @settings(deadline=None)
    def test_only_an_empty_packet_yields_no_fragments(self, text, bound):
        with mock.patch.object(transport, "FRAGMENT_BYTES", bound):
            parts = transport.fragment(text.encode("utf-8"))
        self.assertEqual(parts == [], text == "")


class FragmentBoundFailures(unittest.TestCase):
    """A bound too small for one character must fail closed."""

    # U+1F600 is 4 bytes, so a 1-3 byte bound cannot hold it. The splitter backs
    # off over continuation bytes to the fragment start and must raise there
    # rather than emit an empty fragment or cut the character in half.
    @given(bound=st.integers(min_value=1, max_value=3), tail=st.text(max_size=8))
    @settings(deadline=None)
    def test_a_bound_too_small_for_one_character_fails_closed(self, bound, tail):
        raw = ("\U0001f600" + tail).encode("utf-8")
        with mock.patch.object(transport, "FRAGMENT_BYTES", bound):
            with self.assertRaises(ValueError):
                transport.fragment(raw)


if __name__ == "__main__":
    unittest.main(verbosity=2)
