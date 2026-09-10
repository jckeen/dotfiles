#!/usr/bin/env python3
"""Validate dispositions and read-only probes; never launch a runtime or hook.

Default mode checks public files only. --live-home additionally reports installed
provider drift and unmodeled skill directories as JSON; live differences are
advisory. Presence/configuration is not proof of runtime execution or hook trust.
"""
import argparse
import json
from pathlib import Path
import shutil
import sys

RUNTIMES = ('claude', 'codex', 'antigravity')
CAPABILITIES = ('review', 'simplify', 'commit-pr', 'github', 'browser-runtime',
                'handoff-injection', 'formatting', 'secret-scanning',
                'notifications', 'docs-lookup', 'private-memory')
KINDS = {'skill', 'cli', 'plugin', 'mcp', 'hook', 'git-hook', 'instruction', 'unsupported'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def relative_path(value):
    require(isinstance(value, str) and value.strip(), 'path must be nonempty')
    path = Path(value)
    require(not path.is_absolute() and '..' not in path.parts, 'path must stay relative to its root')
    return path


def public_file(root, value):
    path = root / relative_path(value)
    require(path.resolve().is_relative_to(root.resolve()), 'public path escapes repository')
    return path


def validate_probe(probe, public):
    require(isinstance(probe, dict), 'probe must be an object')
    kind = probe.get('kind')
    allowed = {'file', 'text', 'json-key'} if public else {'file', 'text', 'json-key', 'executable'}
    require(isinstance(kind, str) and kind in allowed,
            'probe kind must be a read-only file/configuration check or live executable lookup')
    if kind == 'executable':
        require(isinstance(probe.get('name'), str) and probe['name'].strip(), 'executable name missing')
        return
    relative_path(probe.get('path'))
    if kind == 'text':
        require(isinstance(probe.get('contains'), str) and probe['contains'].strip(), 'text probe needs contains')
    if kind == 'json-key':
        key = probe.get('key')
        require(isinstance(key, list) and key and all(isinstance(k, str) and k for k in key),
                'JSON probe needs a nonempty key path')


def probe_present(root, probe, public=False):
    kind = probe['kind']
    if kind == 'executable':
        return shutil.which(probe['name']) is not None
    path = public_file(root, probe['path']) if public else root / relative_path(probe['path'])
    if not path.is_file():
        return False
    if kind == 'file':
        return True
    # Never return file content or configuration values in a report.
    if path.stat().st_size > 1024 * 1024:
        return False
    content = path.read_text()
    if kind == 'text':
        return probe['contains'] in content
    value = json.loads(content)
    for key in probe['key']:
        if not isinstance(value, dict) or key not in value:
            return False
        value = value[key]
    return bool(value)


def check_row(root, row):
    require(isinstance(row, dict), 'disposition must be an object')
    for field, allowed in (('kind', KINDS), ('scope', {'required', 'optional', 'project'}),
                           ('owner', {'public', 'private'}), ('status', {'supported', 'advisory', 'unsupported'})):
        require(isinstance(row.get(field), str) and row[field] in allowed, field + ' missing or invalid')
    for name in ('compatibility_floor', 'reason'):
        require(isinstance(row.get(name), str) and row[name].strip(), name + ' missing')
    unsupported = row['kind'] == 'unsupported'
    require(unsupported == (row['status'] == 'unsupported'), 'unsupported provider/status must agree')
    for name in ('probe', 'live_probe'):
        require(isinstance(row.get(name), list), name + ' missing or invalid')
        require(bool(row[name]) != unsupported, name + ' must be populated for supported/advisory providers only')
    if unsupported:
        require(row['scope'] != 'required', 'required capability cannot be unsupported')
        require(row.get('provider') is None, 'unsupported capability must not claim a provider')
        return
    relative_path(row.get('provider'))
    public = row['owner'] == 'public'
    for probe in row['probe']:
        validate_probe(probe, public)
    for probe in row['live_probe']:
        validate_probe(probe, False)
    if public:
        require(public_file(root, row['provider']).is_file(), 'public provider missing')
        for probe in row['probe']:
            require(probe_present(root, probe, True), 'public probe failed: ' + probe['path'])


def check_contract(root, manifest):
    require(isinstance(manifest, dict) and manifest.get('version') == 1, 'unsupported capability contract version')
    capabilities = manifest.get('capabilities')
    require(isinstance(capabilities, dict), 'capabilities must be an object')
    errors = [cap + ': capability disposition missing' for cap in CAPABILITIES if cap not in capabilities]
    for cap, runtimes in capabilities.items():
        if not isinstance(runtimes, dict):
            errors.append(cap + ': runtime dispositions must be an object')
            continue
        for runtime in RUNTIMES:
            label = cap + '/' + runtime
            try:
                require(runtime in runtimes, 'runtime disposition missing')
                check_row(root, runtimes[runtime])
            except (ValueError, OSError, RuntimeError) as exc:
                # Do not expose configuration values through JSON decode errors.
                reason = 'unreadable provider configuration' if isinstance(exc, json.JSONDecodeError) else str(exc)
                errors.append(label + ': ' + reason)
        for runtime in runtimes.keys() - set(RUNTIMES):
            errors.append(cap + '/' + runtime + ': unknown runtime')
    return errors


def live_report(root, home, manifest):
    rows = []
    modeled = set()
    for cap, runtimes in manifest['capabilities'].items():
        for runtime, row in runtimes.items():
            status = 'unsupported'
            if row['status'] != 'unsupported':
                try:
                    present = all(probe_present(home, probe) for probe in row['live_probe'])
                    status = 'present' if present else 'drift'
                except (ValueError, OSError, RuntimeError):
                    status = 'unreadable'
            rows.append(dict(capability=cap, runtime=runtime, scope=row['scope'],
                             status=status, disposition=row['status']))
            for probe in row['live_probe']:
                if probe.get('path', '').endswith('/SKILL.md'):
                    modeled.add(str(Path(probe['path']).parent))
    installed = set()
    for location, sources in (('.claude/skills', ('claude/skills',)),
                              ('.agents/skills', ('agents/skills', 'codex/skills')),
                              ('.gemini/config/skills', ('agents/skills', 'antigravity/skills'))):
        for source in sources:
            if (root / source).is_dir():
                modeled.update(str(Path(location) / child.name) for child in (root / source).iterdir()
                               if child.is_dir())
        folder = home / location
        if folder.is_dir():
            installed.update(str(Path(location) / child.name) for child in folder.iterdir()
                             if child.is_dir())
    return dict(live=rows, local_additions=sorted(installed - modeled),
                limits='Read-only provider presence/configuration and skill inventory only; '
                       'does not verify execution, authentication, hook trust, plugin caches, '
                       'project configuration, or injected tools. Local additions are allowed.')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate contract key: ' + key)
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--live-home', type=Path, help='Report only; read this home without running providers')
    args = parser.parse_args()
    try:
        manifest = json.loads((args.repo / 'agents/capabilities.json').read_text(), object_pairs_hook=unique_object)
        errors = check_contract(args.repo, manifest)
    except (ValueError, OSError, RuntimeError) as exc:
        errors = ['capability contract: ' + str(exc)]
    if errors:
        for error in errors:
            print('[ERR] ' + error, file=sys.stderr)
        return 1
    if args.live_home:
        print(json.dumps(live_report(args.repo, args.live_home, manifest), indent=2))
    else:
        print('capability-parity: OK (public contract; runtime execution unverified)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
