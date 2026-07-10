#!/usr/bin/env bash
# gen-agentpack.sh — generate claude/AGENTPACK.yaml from live frontmatter (issue #207).
#
# AGENTPACK.yaml is GENERATED, NOT WRITTEN (its .doc-contract tier): the skill
# and subagent atoms are derived from the live frontmatter of
# claude/skills/*/SKILL.md and claude/agents/*.md — the same source of truth
# build-site.sh uses for the Pages catalogs — so the manifest cannot drift
# from the source. Everything not derivable from frontmatter (pack metadata,
# compatibility, profiles, exports, the instruction atoms, per-type atom
# defaults, and the pinned skill ordering) lives in the hand-maintained
# fragment claude/agentpack-meta.json.
#
# The output is a YAML document: one generated-banner comment line followed by
# a JSON body. JSON is a YAML subset, and the agent-pack CLI loads the
# manifest with a YAML parser (packages/core/src/parser/loadManifest.ts), so
# the banner comment is safe.
#
# Usage:
#   claude/scripts/gen-agentpack.sh           # regenerate claude/AGENTPACK.yaml
#   claude/scripts/gen-agentpack.sh --check   # exit 1 if the committed file is stale (CI)
#
# Deps: bash + python3 (stdlib only) — no network, no package installs.

set -euo pipefail

# Resolve the repo root from this script's REAL path, not the caller's cwd:
# setup.sh symlinks this into ~/.claude/scripts, where `git rev-parse` would
# find the wrong repo (or none) — issue #236. checker-lib.sh sits beside this
# script in both locations (setup.sh links them side-by-side).
# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/checker-lib.sh"
REPO_ROOT="$(checker_repo_root "${BASH_SOURCE[0]}")"
cd "$REPO_ROOT"

MANIFEST="claude/AGENTPACK.yaml"
META="claude/agentpack-meta.json"

MODE="${1:-generate}"
case "$MODE" in
  generate | --check) ;;
  *)
    echo "usage: gen-agentpack.sh [--check]" >&2
    exit 2
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "✖ gen-agentpack: python3 is required" >&2
  exit 1
fi
if [[ ! -f "$META" ]]; then
  echo "✖ gen-agentpack: meta fragment $META not found" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

python3 - "$META" > "$TMP" <<'PY'
import glob
import json
import os
import re
import sys

meta_path = sys.argv[1]
with open(meta_path, encoding="utf-8") as f:
    meta = json.load(f)


def die(msg):
    sys.exit(f"✖ gen-agentpack: {msg}")


def read_frontmatter(path):
    """Raw frontmatter extraction, matching build-site.sh semantics:
    top-level `key: value` pairs, with folded block scalars (`key: >-`)
    joined by single spaces. YAML forms this reader cannot represent fail
    loudly instead of silently mangling (issue #235): a blank line inside a
    block scalar (true YAML keeps the paragraph after it; this reader would
    drop it), quoted scalar values (the quotes and backslash escapes would
    leak into the output as literal content), literal block scalars
    (`key: |-`; their newlines are semantic and would be space-joined), and
    multi-line plain scalars (the indented continuation would be dropped)."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    if not lines or not re.match(r"^---\s*$", lines[0]):
        return {}
    fm = {}
    key = None
    block = False
    blank_in_block = False
    plain_key = None
    for line in lines[1:]:
        if re.match(r"^---\s*$", line):
            break
        m = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):(.*)$", line)
        if m:
            key = m.group(1)
            val = m.group(2).strip()
            if re.match(r"^[>|][+-]?\s*$", val):
                if val.startswith("|"):
                    die(
                        f"literal block scalar (|) for key '{key}' in {path} "
                        "frontmatter — its newlines are semantic and this "
                        "reader would space-join them; use a folded (>-) scalar"
                    )
                block = True
                blank_in_block = False
                plain_key = None
                fm[key] = ""
            else:
                if val[:1] in ('"', "'"):
                    die(
                        f"quoted scalar for key '{key}' in {path} frontmatter — "
                        "this reader would leak the quotes/escapes as literal "
                        "content; use a plain or folded (>-) scalar"
                    )
                block = False
                plain_key = key if val else None
                fm[key] = val
        elif block and re.match(r"^\s+\S", line):
            if blank_in_block:
                die(
                    f"blank line inside block scalar for key '{key}' in {path} "
                    "frontmatter — this reader would silently drop the text "
                    "after it; rewrap as one paragraph"
                )
            fm[key] = (fm[key] + " " if fm[key] else "") + line.strip()
        elif block and not line.strip():
            blank_in_block = True
        else:
            if plain_key and re.match(r"^\s+\S", line):
                die(
                    f"multi-line plain scalar for key '{plain_key}' in {path} "
                    "frontmatter — this reader would silently drop the "
                    "indented continuation; use a folded (>-) scalar"
                )
            block = False
    return fm


def require(fm, key, path):
    val = fm.get(key, "")
    if not val:
        die(f"no '{key}' in {path} frontmatter")
    return val


atoms = list(meta["instruction_atoms"])

skill_defaults = meta["atom_defaults"]["skill"]
skills = []
for path in sorted(glob.glob("claude/skills/*/SKILL.md")):
    fm = read_frontmatter(path)
    name = require(fm, "name", path)
    skills.append(
        {
            "id": f"skill:{name}",
            "type": "skill",
            "name": name,
            "description": require(fm, "description", path),
            "path": f"skills/{os.path.basename(os.path.dirname(path))}",
            "risk_level": skill_defaults["risk_level"],
            "permissions": list(skill_defaults["permissions"]),
            "skill_format": skill_defaults["skill_format"],
        }
    )
if not skills:
    die("no skills found under claude/skills/*/SKILL.md")

# Pinned skills (skill_order_first) lead in the given order; the rest sort
# alphabetically — this reproduces fable-mode's deliberate first position.
first = meta.get("skill_order_first", [])
skills.sort(key=lambda a: (first.index(a["name"]) if a["name"] in first else len(first), a["name"]))
atoms += skills

sub_defaults = meta["atom_defaults"]["subagent"]
subagents = []
for path in sorted(glob.glob("claude/agents/*.md")):
    fm = read_frontmatter(path)
    name = require(fm, "name", path)
    subagents.append(
        {
            "id": f"subagent:{name}",
            "type": "subagent",
            "name": name,
            "description": require(fm, "description", path),
            "path": f"agents/{os.path.basename(path)}",
            "risk_level": sub_defaults["risk_level"],
            "permissions": list(sub_defaults["permissions"]),
        }
    )
if not subagents:
    die("no agents found under claude/agents/*.md")
subagents.sort(key=lambda a: a["name"])
atoms += subagents

ids = [a["id"] for a in atoms]
dupes = sorted({i for i in ids if ids.count(i) > 1})
if dupes:
    die(f"duplicate atom ids: {', '.join(dupes)}")

pack = {
    "agentpack": meta["agentpack"],
    "metadata": meta["metadata"],
    "compatibility": meta["compatibility"],
    "permissions": meta["permissions"],
    "security": meta["security"],
    "profiles": meta["profiles"],
    "atoms": atoms,
    "exports": meta["exports"],
}

banner = (
    "# GENERATED from claude/skills/*/SKILL.md + claude/agents/*.md frontmatter"
    " and claude/agentpack-meta.json by claude/scripts/gen-agentpack.sh —"
    " do not edit by hand (CI asserts freshness)."
)
sys.stdout.write(banner + "\n" + json.dumps(pack, indent=2, ensure_ascii=False) + "\n")
PY

if [[ "$MODE" == "--check" ]]; then
  if ! diff -u "$MANIFEST" "$TMP"; then
    echo "" >&2
    echo "✖ gen-agentpack: $MANIFEST is stale — run claude/scripts/gen-agentpack.sh and commit the result" >&2
    exit 1
  fi
  echo "gen-agentpack: OK — $MANIFEST matches frontmatter + $META"
else
  cp "$TMP" "$MANIFEST"
  echo "gen-agentpack: wrote $MANIFEST"
fi
