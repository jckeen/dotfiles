#!/usr/bin/env python3
"""Read an unambiguous Remote Control opt-in without managing a daemon."""

import json
from pathlib import Path
import sys


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate settings key")
        result[key] = value
    return result


def reject_constant(_value):
    raise ValueError("nonstandard JSON constant")


def enabled(path):
    try:
        with path.open(encoding="utf-8") as source:
            settings = json.load(
                source, object_pairs_hook=unique_object, parse_constant=reject_constant
            )
        return isinstance(settings, dict) and settings.get("remoteControlEnabled") is True
    except (OSError, ValueError):
        return False


if __name__ == "__main__":
    sys.exit(0 if len(sys.argv) == 2 and enabled(Path(sys.argv[1])) else 1)
