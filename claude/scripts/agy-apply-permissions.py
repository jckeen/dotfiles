#!/usr/bin/env python3
"""Merge the Antigravity permission baseline into the machine-local settings.

antigravity/permissions.json (public, curated) is the source of truth for the
allow/ask/deny rules and the two execution-mode keys. The live file
~/.gemini/antigravity-cli/settings.json is never symlinked: it also carries
trustedWorkspaces and grants the user saves from approval prompts.

  apply  ensure every baseline rule is present and seed the mode keys when
         absent; user-added rules are kept, but rules the baseline has
         retired are deleted (exit 0; 2 on unreadable input)
  check  exit 1 when a baseline rule or mode key is missing, the mode
         differs, or a retired rule is still live; print the count of
         non-baseline rules as drift information
  prune  back up the settings file, then replace the permissions with the
         baseline exactly and force the mode keys (the one-time cleanup)
"""
import argparse
import json
import os
import re
import sys
import tempfile
import time

RULE_RE = re.compile(r'^(command|unsandboxed|read_file|write_file|read_url|execute_url|mcp)\(.+\)$')
BUCKETS = ('allow', 'ask', 'deny')


def load_json(path, required):
    if not os.path.exists(path):
        if required:
            sys.exit(f'error: {path} does not exist')
        return {}
    try:
        with open(path, encoding='utf-8') as stream:
            data = json.load(stream)
    except (OSError, ValueError) as exc:
        sys.exit(f'error: cannot parse {path}: {exc}')
    if not isinstance(data, dict):
        sys.exit(f'error: {path} must hold a JSON object')
    return data


def load_baseline(path):
    data = load_json(path, required=True)
    rules = data.get('permissions')
    settings = data.get('settings')
    if not isinstance(rules, dict) or not isinstance(settings, dict):
        sys.exit(f'error: {path} needs "permissions" and "settings" objects')
    for bucket in BUCKETS:
        entries = rules.get(bucket, [])
        if not isinstance(entries, list) or not all(isinstance(e, str) and RULE_RE.match(e) for e in entries):
            sys.exit(f'error: {path}: every "{bucket}" entry must be a rule like command(prefix)')
        if any('/home/' in e or '/Users/' in e for e in entries):
            sys.exit(f'error: {path}: rules must not embed a user home path')
    # Rules the baseline has withdrawn. apply is additive, so a grant deleted
    # from "permissions" would otherwise survive on every machine that already
    # installed it; listing it here makes apply delete it and check fail.
    retired = data.get('retired', [])
    if not isinstance(retired, list) or not all(isinstance(e, str) and RULE_RE.match(e) for e in retired):
        sys.exit(f'error: {path}: every "retired" entry must be a rule like command(prefix)')
    baseline = {b: list(rules.get(b, [])) for b in BUCKETS}
    both = sorted(set(retired) & {r for entries in baseline.values() for r in entries})
    if both:
        sys.exit(f'error: {path}: rule(s) both current and retired: {", ".join(both)}')
    return baseline, settings, retired


def write_atomic(path, data):
    directory = os.path.dirname(path) or '.'
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.settings-', dir=directory)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(data, stream, indent=2)
            stream.write('\n')
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def expand_rule(rule, home):
    m = re.match(r'^(read_file|write_file)\(~(/.*)?\)$', rule)
    if m:
        action, subpath = m.group(1), m.group(2)
        if subpath:
            target_path = subpath if home == '/' else f'{home}{subpath}'
        else:
            target_path = home
        return f'{action}({target_path})'
    return rule


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('mode', choices=('apply', 'check', 'prune'))
    parser.add_argument('--settings', required=True, help='live ~/.gemini/antigravity-cli/settings.json')
    parser.add_argument('--rules', required=True, help='antigravity/permissions.json baseline')
    parser.add_argument('--home', default=os.path.expanduser('~'), help='user home directory to expand in file rules (default: ~)')
    args = parser.parse_args()

    if not os.path.isabs(args.home):
        sys.exit(f'error: --home must be an absolute path: {args.home}')
    home = args.home.rstrip('/') or '/'
    baseline, mode_keys, retired = load_baseline(args.rules)
    expanded_baseline = {b: [expand_rule(r, home) for r in baseline[b]] for b in BUCKETS}
    retired_set = {expand_rule(r, home) for r in retired}
    settings = load_json(args.settings, required=False)
    live = settings.get('permissions')
    if live is None:
        live = {}
    if not isinstance(live, dict):
        sys.exit(f'error: {args.settings}: "permissions" must be an object')
    live_lists = {}
    legacy_repaired = False
    for bucket in BUCKETS:
        entries = live.get(bucket, [])
        if not isinstance(entries, list):
            sys.exit(f'error: {args.settings}: permissions.{bucket} must be a list')
        cleaned = []
        for e in entries:
            if isinstance(e, str):
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

    retired_live = {b: [r for r in live_lists[b] if r in retired_set] for b in BUCKETS}
    n_retired = sum(len(v) for v in retired_live.values())
    missing = {b: [r for r in expanded_baseline[b] if r not in live_lists[b]] for b in BUCKETS}
    extras = {b: [r for r in live_lists[b] if r not in expanded_baseline[b] and r not in retired_set]
              for b in BUCKETS}
    mode_missing = [k for k in mode_keys if k not in settings]
    mode_drift = {k: settings[k] for k, v in mode_keys.items() if k in settings and settings[k] != v}
    n_missing = sum(len(v) for v in missing.values())
    n_extra = sum(len(v) for v in extras.values())

    if args.mode == 'check':
        problems = []
        if n_missing:
            problems.append(f'{n_missing} baseline rule(s) missing')
        if legacy_repaired:
            problems.append('unexpanded "~" rule(s) in settings (re-run apply)')
        if n_retired:
            named = ', '.join(r for b in BUCKETS for r in retired_live[b])
            problems.append(f'{n_retired} retired rule(s) still granted: {named} (re-run apply)')
        if mode_missing:
            problems.append('unset: ' + ', '.join(mode_missing))
        if problems:
            print('; '.join(problems))
            return 1
        notes = [f'{k}={v!r} is a local override (baseline {mode_keys[k]!r})' for k, v in mode_drift.items()]
        print(f'baseline present; {n_extra} machine-local rule(s) beyond the baseline'
              + ('; ' + '; '.join(notes) if notes else ''))
        return 0

    if args.mode == 'prune':
        if os.path.exists(args.settings):
            backup = f'{args.settings}.bak-{time.strftime("%Y%m%d-%H%M%S")}'
            with open(args.settings, 'rb') as src, open(backup, 'wb') as dst:
                dst.write(src.read())
            os.chmod(backup, 0o600)
            print(f'backed up previous settings to {backup}')
        settings['permissions'] = {b: list(expanded_baseline[b]) for b in BUCKETS}
        settings.update(mode_keys)
        write_atomic(args.settings, settings)
        print(f'pruned: permissions replaced with the baseline; {n_extra} machine-local rule(s) removed')
        return 0

    # apply
    changed = n_missing > 0 or legacy_repaired or n_retired > 0
    for bucket in BUCKETS:
        for rule in retired_live[bucket]:
            print(f'retired: removed {rule} from {bucket} (withdrawn from the baseline)')
    kept = {b: [r for r in live_lists[b] if r not in retired_set] for b in BUCKETS}
    merged = {b: kept[b] + missing[b] for b in BUCKETS}
    for bucket in BUCKETS:
        if live.get(bucket) != merged[bucket]:
            changed = True
    settings['permissions'] = merged
    for key, value in mode_keys.items():
        if key not in settings:
            settings[key] = value
            changed = True
    if changed:
        write_atomic(args.settings, settings)
        print(f'applied: {n_missing} baseline rule(s) added; mode keys seeded when absent')
    else:
        print('baseline already applied')
    for key, value in mode_drift.items():
        print(f'note: {key}={value!r} is a local override (baseline {mode_keys[key]!r}); prune to reset')
    return 0


if __name__ == '__main__':
    sys.exit(main())
