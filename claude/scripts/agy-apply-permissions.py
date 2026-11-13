#!/usr/bin/env python3
"""Merge the Antigravity permission baseline into the machine-local settings.

antigravity/permissions.json (public, curated) is the source of truth for the
allow/ask/deny rules and the execution-mode keys. An optional private overlay
(e.g. ~/dev/agy-memory/permissions.local.json via --overlay) layers personal
standing-order grants and promotes selected baseline ask rules to allow.
The live file ~/.gemini/antigravity-cli/settings.json is never symlinked: it
also carries trustedWorkspaces and grants the user saves from approval prompts.

  apply  ensure every baseline/overlay rule is present and seed the mode keys
         when absent; user-added rules are kept, but rules the baseline has
         retired (from allow) or unasked (from ask) are deleted (exit 0; 2 on
         unreadable input)
  check  exit 1 when a baseline/overlay rule or mode key is missing, the mode
         differs, a retired rule is still in allow, or an unasked rule is still
         in ask; print the count of non-baseline rules as drift information
  prune  back up the settings file, then replace the permissions with the
         baseline (+ overlay) exactly and force the mode keys
"""

import argparse
import json
import os
import re
import sys
import tempfile
import time

RULE_RE = re.compile(r"^(command|read_file|write_file|read_url|execute_url|mcp)\(.+\)$")
UNSANDBOXED_RE = re.compile(r"^unsandboxed(?:\s*\((.*)\)\s*$|\s*\(.*|\s*$)", re.IGNORECASE)
BUCKETS = ("allow", "ask", "deny")
# Retirement withdraws a grant, never a restriction.
GRANT_BUCKET = "allow"
ASK_BUCKET = "ask"


def load_json(path, required):
    if not os.path.exists(path):
        if required:
            sys.exit(f"error: {path} does not exist")
        return {}
    try:
        with open(path, encoding="utf-8") as stream:
            data = json.load(stream)
    except (OSError, ValueError) as exc:
        sys.exit(f"error: cannot parse {path}: {exc}")
    if not isinstance(data, dict):
        sys.exit(f"error: {path} must hold a JSON object")
    return data


def _validate_rule_list(path, label, entries):
    if not isinstance(entries, list) or not all(
        isinstance(e, str) and RULE_RE.match(e) for e in entries
    ):
        sys.exit(f'error: {path}: every "{label}" entry must be a rule like command(prefix)')
    if any("/home/" in e or "/Users/" in e for e in entries):
        sys.exit(f"error: {path}: rules must not embed a user home path")


def load_baseline(path):
    data = load_json(path, required=True)
    rules = data.get("permissions")
    settings = data.get("settings")
    if not isinstance(rules, dict) or not isinstance(settings, dict):
        sys.exit(f'error: {path} needs "permissions" and "settings" objects')
    for bucket in BUCKETS:
        _validate_rule_list(path, bucket, rules.get(bucket, []))
    # Rules the baseline has withdrawn from allow. apply is additive, so a grant
    # deleted from "permissions" would otherwise survive on every machine that
    # already installed it; listing it here makes apply delete it and check fail.
    retired = data.get("retired", [])
    _validate_rule_list(path, "retired", retired)
    # Rules withdrawn from ask (or promoted by an overlay).
    unask = data.get("unask", [])
    _validate_rule_list(path, "unask", unask)
    baseline = {b: list(rules.get(b, [])) for b in BUCKETS}
    both = sorted(set(retired) & set(baseline[GRANT_BUCKET]))
    if both:
        sys.exit(f"error: {path}: rule(s) both granted and retired: {', '.join(both)}")
    both_ask = sorted(set(unask) & set(baseline[ASK_BUCKET]))
    if both_ask:
        sys.exit(f"error: {path}: rule(s) both in ask and unask: {', '.join(both_ask)}")
    return baseline, settings, list(retired), list(unask)


def load_overlay(path):
    data = load_json(path, required=True)
    rules = data.get("permissions", {})
    if not isinstance(rules, dict):
        sys.exit(f'error: {path}: "permissions" must be an object')
    for bucket in BUCKETS:
        _validate_rule_list(path, bucket, rules.get(bucket, []))
    retired = data.get("retired", [])
    _validate_rule_list(path, "retired", retired)
    unask = data.get("unask", [])
    _validate_rule_list(path, "unask", unask)
    overlay = {b: list(rules.get(b, [])) for b in BUCKETS}
    both = sorted(set(retired) & set(overlay[GRANT_BUCKET]))
    if both:
        sys.exit(f"error: {path}: rule(s) both granted and retired: {', '.join(both)}")
    both_ask = sorted(set(unask) & set(overlay[ASK_BUCKET]))
    if both_ask:
        sys.exit(f"error: {path}: rule(s) both in ask and unask: {', '.join(both_ask)}")
    # Any rule granted in overlay allow (and not also placed in overlay ask)
    # automatically promotes out of baseline ask.
    ask_set = set(overlay[ASK_BUCKET])
    effective_unask = list(unask)
    for r in overlay[GRANT_BUCKET]:
        if r not in ask_set and r not in effective_unask:
            effective_unask.append(r)
    return overlay, list(retired), effective_unask


def merge_overlay(baseline, retired, unask, overlay_path, promotable_ask=None):
    if promotable_ask is None:
        promotable_ask = set(baseline[ASK_BUCKET])
    overlay, ov_retired, ov_unask = load_overlay(overlay_path)
    ov_retired_set = set(ov_retired)
    promotable_ask.difference_update(ov_retired_set)
    baseline[GRANT_BUCKET] = [r for r in baseline[GRANT_BUCKET] if r not in ov_retired_set]
    unask[:] = [r for r in unask if r not in ov_retired_set]
    for r in ov_retired:
        if r not in retired:
            retired.append(r)
    ov_unask_set = set(ov_unask)
    # Promoting a rule currently gated in original baseline ask overrides its
    # baseline retirement from allow, while outright-retired rules remain blocked.
    promoted_from_ask = (set(overlay[GRANT_BUCKET]) & promotable_ask) - ov_retired_set
    retired[:] = [r for r in retired if r not in promoted_from_ask]
    baseline[ASK_BUCKET] = [r for r in baseline[ASK_BUCKET] if r not in ov_unask_set]
    for r in ov_unask:
        if r not in unask:
            unask.append(r)
    for bucket in BUCKETS:
        existing = set(baseline[bucket])
        for r in overlay[bucket]:
            if r not in existing:
                baseline[bucket].append(r)
                existing.add(r)
    deny_set = set(baseline["deny"])
    denied_conflict = sorted((set(baseline[GRANT_BUCKET]) | ov_unask_set) & deny_set)
    if denied_conflict:
        sys.exit(
            f"error: {overlay_path}: cannot allow or unask denied rule(s): "
            f"{', '.join(denied_conflict)}"
        )
    both = sorted(set(retired) & set(baseline[GRANT_BUCKET]))
    if both:
        sys.exit(f"error: {overlay_path}: rule(s) both granted and retired: {', '.join(both)}")
    both_ask = sorted(set(unask) & set(baseline[ASK_BUCKET]))
    if both_ask:
        sys.exit(f"error: {overlay_path}: rule(s) both in ask and unask: {', '.join(both_ask)}")


def write_atomic(path, data):
    if os.path.islink(path):
        sys.exit(f"error: refusing to write through a symlinked settings file: {path}")
    directory = os.path.dirname(path) or "."
    if os.path.islink(directory):
        sys.exit(f"error: refusing to write through a symlinked settings directory: {directory}")
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".settings-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def expand_rule(rule, home):
    m = re.match(r"^(read_file|write_file|command)\(~(/.*)?\)$", rule)
    if m:
        action, subpath = m.group(1), m.group(2)
        if subpath:
            target_path = subpath if home == "/" else f"{home}{subpath}"
        else:
            target_path = home
        return f"{action}({target_path})"
    return rule


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("mode", choices=("apply", "check", "prune"))
    parser.add_argument(
        "--settings", required=True, help="live ~/.gemini/antigravity-cli/settings.json"
    )
    parser.add_argument("--rules", required=True, help="antigravity/permissions.json baseline")
    parser.add_argument(
        "--overlay",
        action="append",
        default=[],
        help="optional private permission overlay JSON file (repeatable)",
    )
    parser.add_argument(
        "--home",
        default=os.path.expanduser("~"),
        help="user home directory to expand in file rules (default: ~)",
    )
    args = parser.parse_args()

    if not os.path.isabs(args.home):
        sys.exit(f"error: --home must be an absolute path: {args.home}")
    if os.path.islink(args.settings):
        sys.exit(f"error: refusing to use a symlinked settings file: {args.settings}")
    home = args.home.rstrip("/") or "/"
    baseline, mode_keys, retired, unask = load_baseline(args.rules)
    promotable_ask = set(baseline[ASK_BUCKET])
    for overlay_path in args.overlay:
        merge_overlay(baseline, retired, unask, overlay_path, promotable_ask)

    expanded_baseline = {b: [expand_rule(r, home) for r in baseline[b]] for b in BUCKETS}
    retired_set = {expand_rule(r, home) for r in retired}
    unask_set = {expand_rule(r, home) for r in unask}
    settings = load_json(args.settings, required=False)
    live = settings.get("permissions")
    if live is None:
        live = {}
    if not isinstance(live, dict):
        sys.exit(f'error: {args.settings}: "permissions" must be an object')
    live_lists = {}
    legacy_repaired = False
    unsandboxed_live = []
    for bucket in BUCKETS:
        entries = live.get(bucket, [])
        if not isinstance(entries, list):
            sys.exit(f"error: {args.settings}: permissions.{bucket} must be a list")
        cleaned = []
        for e in entries:
            if isinstance(e, str):
                m_unsandboxed = UNSANDBOXED_RE.match(e.strip())
                if m_unsandboxed:
                    unsandboxed_live.append(e)
                    inner = (m_unsandboxed.group(1) or "").strip()
                    if inner and not (bucket == GRANT_BUCKET and inner == "*"):
                        migrated = expand_rule(f"command({inner})", home)
                        if RULE_RE.match(migrated):
                            cleaned.append(migrated)
                    continue
                expanded = expand_rule(e, home)
                if expanded != e:
                    legacy_repaired = True
                cleaned.append(expanded)
        seen = set()
        deduped = []
        for e in cleaned:
            if e not in seen:
                seen.add(e)
                deduped.append(e)
        live_lists[bucket] = deduped

    # Retirement withdraws a grant, so it only ever touches "allow". The same
    # rule sitting in ask or deny is the operator's own hardening: deleting it
    # would turn a forbidden operation into an approvable one.
    retired_live = [r for r in live_lists[GRANT_BUCKET] if r in retired_set]
    n_retired = len(retired_live)
    # Unask withdraws a prompt from "ask" (either retired from baseline ask or
    # promoted to allow by an overlay).
    unasked_live = [r for r in live_lists[ASK_BUCKET] if r in unask_set]
    n_unasked = len(unasked_live)
    missing = {b: [r for r in expanded_baseline[b] if r not in live_lists[b]] for b in BUCKETS}
    extras = {
        b: [
            r
            for r in live_lists[b]
            if r not in expanded_baseline[b]
            and not (b == GRANT_BUCKET and r in retired_set)
            and not (b == ASK_BUCKET and r in unask_set)
        ]
        for b in BUCKETS
    }
    mode_missing = [k for k in mode_keys if k not in settings]
    mode_drift = {
        k: settings[k] for k, v in mode_keys.items() if k in settings and settings[k] != v
    }
    n_missing = sum(len(v) for v in missing.values())
    n_extra = sum(len(v) for v in extras.values())

    if args.mode == "check":
        problems = []
        if n_missing:
            problems.append(f"{n_missing} baseline rule(s) missing")
        if unsandboxed_live:
            problems.append(
                f"{len(unsandboxed_live)} invalid unsandboxed rule(s) in settings (re-run apply)"
            )
        if legacy_repaired:
            problems.append('unexpanded "~" rule(s) in settings (re-run apply)')
        if n_retired:
            named = ", ".join(retired_live)
            problems.append(f"{n_retired} retired rule(s) still granted: {named} (re-run apply)")
        if n_unasked:
            named = ", ".join(unasked_live)
            problems.append(f"{n_unasked} unasked rule(s) still in ask: {named} (re-run apply)")
        if mode_missing:
            problems.append("unset: " + ", ".join(mode_missing))
        if problems:
            print("; ".join(problems))
            return 1
        notes = [
            f"{k}={v!r} is a local override (baseline {mode_keys[k]!r})"
            for k, v in mode_drift.items()
        ]
        print(
            f"baseline present; {n_extra} machine-local rule(s) beyond the baseline"
            + ("; " + "; ".join(notes) if notes else "")
        )
        return 0

    if args.mode == "prune":
        if os.path.exists(args.settings):
            backup = f"{args.settings}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
            with open(args.settings, "rb") as src, open(backup, "wb") as dst:
                dst.write(src.read())
            os.chmod(backup, 0o600)
            print(f"backed up previous settings to {backup}")
        settings["permissions"] = {b: list(expanded_baseline[b]) for b in BUCKETS}
        settings.update(mode_keys)
        write_atomic(args.settings, settings)
        print(
            f"pruned: permissions replaced with the baseline; {n_extra} machine-local rule(s) removed"
        )
        return 0

    # apply
    changed = (
        n_missing > 0 or legacy_repaired or bool(unsandboxed_live) or n_retired > 0 or n_unasked > 0
    )
    if unsandboxed_live:
        print(f"migrated: converted/removed {len(unsandboxed_live)} legacy unsandboxed rule(s)")
    for rule in retired_live:
        print(f"retired: removed {rule} from {GRANT_BUCKET} (withdrawn from the baseline)")
    for rule in unasked_live:
        print(f"unasked: removed {rule} from {ASK_BUCKET}")
    kept = dict(live_lists)
    kept[GRANT_BUCKET] = [r for r in live_lists[GRANT_BUCKET] if r not in retired_set]
    kept[ASK_BUCKET] = [r for r in live_lists[ASK_BUCKET] if r not in unask_set]
    merged = {b: kept[b] + missing[b] for b in BUCKETS}
    for bucket in BUCKETS:
        if live.get(bucket) != merged[bucket]:
            changed = True
    settings["permissions"] = merged
    for key, value in mode_keys.items():
        if key not in settings:
            settings[key] = value
            changed = True
    if changed:
        write_atomic(args.settings, settings)
        print(f"applied: {n_missing} baseline rule(s) added; mode keys seeded when absent")
    else:
        if os.path.exists(args.settings):
            os.chmod(args.settings, 0o600)
        print("baseline already applied")
    for key, value in mode_drift.items():
        print(
            f"note: {key}={value!r} is a local override (baseline {mode_keys[key]!r}); prune to reset"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
