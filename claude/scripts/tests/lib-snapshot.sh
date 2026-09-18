#!/usr/bin/env bash
# lib-snapshot.sh — the directory snapshot shared by the setup.sh suites.
# Sourced, never executed.
#
# Extracted verbatim from setup-dry-run.test.sh so setup-fuzz-layouts.test.sh
# asserts "zero mutations" with the identical comparison instead of a second,
# subtly different one. A weaker snapshot in either suite would silently stop
# catching the writes the no-writes contract (#133) exists to catch.

# shellcheck shell=bash

# Full-fidelity snapshot of a directory tree: every path, every regular-file
# hash, every symlink target. Two identical snapshots ⇒ zero mutations.
snapshot() {
  local root="$1"
  (
    cd "$root" || exit 1
    find . -mindepth 1 | sort
    find . -type f -print0 | sort -z | xargs -0 -r sha256sum
    find . -type l -print0 | sort -z | while IFS= read -r -d '' l; do
      printf 'link %s -> %s\n' "$l" "$(readlink "$l")"
    done
  )
}
