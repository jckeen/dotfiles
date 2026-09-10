#!/usr/bin/env python3
"""Check declared semantic anchors in each runtime's shared workflow body.

The contract records small, reviewable regex anchors, not whole-file hashes or
proof of agent compliance. Frontmatter and HTML comments cannot satisfy an
instruction. Codex and Antigravity use agents/skills unless a runtime override
exists, in which case that body must satisfy the shared-agent anchors too.
"""
import argparse
import json
from pathlib import Path
import re
import sys


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate invariant contract key: ' + key)
        result[key] = value
    return result


def body(path, root):
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('skill path escapes repository')
    text = path.read_text()
    text = re.sub(r'\A---\s*\n.*?\n---\s*(?:\n|$)', '', text, count=1, flags=re.S)
    text = re.sub(r'<!--.*?(?:-->|$)', '', text, flags=re.S)
    # Formatting and line wrapping do not change the instruction's meaning.
    return ' '.join(re.sub(r'[`*_]', '', text).split())


def check(root):
    contract = json.loads((root / 'agents/workflow-invariants.json').read_text(), object_pairs_hook=unique_object)
    if not isinstance(contract, dict) or contract.get('version') != 1:
        raise ValueError('unsupported invariant contract version')
    workflows = contract.get('workflows')
    if not isinstance(workflows, dict):
        raise ValueError('workflow invariant map missing')
    shared = set()
    for line in (root / 'agents/skill-coverage.tsv').read_text().splitlines():
        if line and not line.startswith('#'):
            fields = line.split('\t')
            if len(fields) < 2 or not re.fullmatch(r'[a-z][a-z0-9-]*', fields[0]):
                raise ValueError('invalid skill coverage row')
            if fields[1] == 'shared':
                shared.add(fields[0])
    errors = [skill + ': invariant contract missing' for skill in sorted(shared - workflows.keys())]
    errors += [skill + ': no shared workflow in coverage contract' for skill in sorted(workflows.keys() - shared)]
    for skill in sorted(shared & workflows.keys()):
        invariants = workflows[skill]
        if not isinstance(invariants, dict) or not invariants:
            errors.append(skill + ': invariant set must be nonempty')
            continue
        compiled = {}
        for name, invariant in invariants.items():
            if not isinstance(invariant, dict) or not isinstance(invariant.get('description'), str) or not invariant['description'].strip():
                errors.append(skill + ': ' + name + ': description missing')
                continue
            compiled[name] = {}
            for side in ('claude', 'agents'):
                patterns = invariant.get(side)
                if not isinstance(patterns, list) or not patterns or not all(isinstance(p, str) and p.strip() for p in patterns):
                    errors.append(skill + ': ' + name + ': ' + side + ' patterns missing')
                    continue
                try:
                    compiled[name][side] = [re.compile(p, re.I) for p in patterns]
                except re.error:
                    errors.append(skill + ': ' + name + ': invalid ' + side + ' pattern')
        for runtime, side in (('claude', 'claude'), ('codex', 'agents'), ('antigravity', 'agents')):
            path = root / runtime / 'skills' / skill / 'SKILL.md'
            # A broken override must fail instead of silently falling back.
            if runtime != 'claude' and not path.exists() and not path.is_symlink():
                path = root / 'agents/skills' / skill / 'SKILL.md'
            try:
                text = body(path, root)
            except (ValueError, OSError, RuntimeError):
                errors.append(skill + '/' + runtime + ': skill body missing or unreadable')
                continue
            for name, patterns in compiled.items():
                if side in patterns and not all(pattern.search(text) for pattern in patterns[side]):
                    errors.append(skill + '/' + runtime + ': missing invariant ' + name)
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    try:
        errors = check(args.repo)
    except (ValueError, OSError, RuntimeError) as exc:
        errors = ['workflow invariant contract: ' + str(exc)]
    for error in errors:
        print('[ERR] ' + error, file=sys.stderr)
    if errors:
        return 1
    print('workflow-invariants: OK (declared body anchors; runtime compliance unverified)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
