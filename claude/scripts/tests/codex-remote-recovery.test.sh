#!/usr/bin/env bash
# codex-remote-recovery.test.sh — pidfd recovery validates identity atomically.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PYTHONDONTWRITEBYTECODE=1 \
  python3 "$REPO_ROOT/codex/tests/test_remote_control_recover.py"
