#!/usr/bin/env python3
"""Bind local gate results to Git objects and raw workspace state; fail closed.

Receipts are local evidence, not signatures against a malicious filesystem owner.
No Git worktree diff is used: clean filters can execute even with --no-textconv.
"""
import argparse
import difflib
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone

LANES = ('codex', 'antigravity')
EXCLUDED = ('*-lock.yaml', '*-lock.json', 'package-lock.json', '*.lock', 'bun.lockb',
            '*.png', '*.jpg', '*.jpeg', '*.gif', '*.ico', '*.pdf', '*.min.css', '*.map')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(',', ':')).encode()


def git(repo, *args):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_NO_REPLACE_OBJECTS='1')
    return subprocess.check_output(['git', '-C', str(repo), *args], env=env, stderr=subprocess.PIPE)


def oid(repo, ref):
    return git(repo, 'rev-parse', '--verify', '--end-of-options', ref + '^{commit}').decode().strip()


def instruction(path):
    parts = Path(path).parts
    name = parts[-1]
    return (any(p in ('codex', '.codex', 'antigravity', '.antigravity', '.agents', '.claude', '.gemini') for p in parts)
            or any(p in ('githooks', '.githooks') for p in parts)
            or ('claude', 'hooks') in zip(parts, parts[1:])
            or re.search(r'(AGENTS|CLAUDE|GEMINI|FABLE|MULTI-AGENT).*\.md$', name) is not None
            or name in ('SKILL.md', 'gate-lib.sh', 'review-receipt.py', 'codex-review-gate.sh', 'antigravity-review-gate.sh'))


def excluded(path):
    return any(fnmatch.fnmatchcase(Path(path).name, pattern) for pattern in EXCLUDED)


def docsafe(path):
    lower = path.lower()
    risk_patterns = ('*AGENTPACK*', '.github/*', '*/.github/*', '*hooks/*', '*.githooks*', '*scripts/*')
    return (not instruction(path) and not any(fnmatch.fnmatchcase(path, pattern) for pattern in risk_patterns)
            and not any(word in lower for word in ('auth', 'token', 'secret', 'credential', 'password', 'session', 'sso', 'crypt', 'hash', 'host', 'schema', 'migration'))
            and (path.endswith(('.md', '.markdown', '.rst')) or re.fullmatch(r'LICENSE(?:\..*)?', Path(path).name) is not None))


def file_bytes(repo, path):
    parent = repo
    for component in Path(path).parts[:-1]:
        parent = parent / component
        try:
            mode = parent.lstat().st_mode
        except (FileNotFoundError, NotADirectoryError):
            return 'missing', b''
        if stat.S_ISLNK(mode):
            raise ValueError('cannot snapshot through symlink ancestor: ' + path)
        if not stat.S_ISDIR(mode):
            return 'missing', b''
    file = repo / path
    try:
        info = file.lstat()
    except (FileNotFoundError, NotADirectoryError):
        return 'missing', b''
    if stat.S_ISLNK(info.st_mode):
        return '120000', os.fsencode(os.readlink(file))
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('cannot snapshot non-file: ' + path)
    return ('100755' if info.st_mode & 0o111 else '100644'), file.read_bytes()


def layout(repo):
    repo = Path(git(repo, 'rev-parse', '--show-toplevel').decode().strip()).resolve()
    directory = Path(git(repo, 'rev-parse', '--absolute-git-dir').decode().strip()).resolve()
    receipts = Path(git(repo, 'rev-parse', '--git-path', 'review-receipts').decode().strip())
    if not receipts.is_absolute():
        receipts = repo / receipts
    receipts = receipts.absolute()
    if receipts.is_symlink():
        raise ValueError('receipt directory must not be a symlink')
    receipts.mkdir(mode=0o700, exist_ok=True)
    os.chmod(receipts, 0o700)
    return repo, directory, receipts


def capture(repo, base, scope):
    head = oid(repo, 'HEAD')
    base_commit = oid(repo, base) if base else None
    if scope == 'committed' and base_commit is None:
        raise ValueError('base could not be resolved')
    merge = git(repo, 'merge-base', base_commit, head).decode().strip() if scope == 'committed' else None
    tree = git(repo, 'rev-parse', head + '^{tree}').decode().strip()
    index = git(repo, 'ls-files', '--stage', '-z')
    entries = {}
    for entry in git(repo, 'ls-tree', '-rz', '--full-tree', head).split(b'\0'):
        if entry:
            meta, path = entry.split(b'\t', 1)
            mode, kind, obj = meta.decode().split()
            if kind != 'blob':
                raise ValueError('submodule snapshots are unsupported; review separately')
            entries[os.fsdecode(path)] = (mode, obj)
    tracked = {os.fsdecode(e.split(b'\t', 1)[1]) for e in index.split(b'\0') if e}
    untracked = {os.fsdecode(p) for p in git(repo, 'ls-files', '--others', '--exclude-standard', '-z').split(b'\0') if p}
    ignored_instructions = {os.fsdecode(p) for p in git(repo, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z').split(b'\0') if p and instruction(os.fsdecode(p))}
    files = {}
    dirty_instructions = [p for p in entries if instruction(p) and p not in tracked]
    for path in sorted(set(entries) | tracked | untracked | ignored_instructions):
        mode, content = file_bytes(repo, path)
        files[path] = (mode, digest(content))
        if instruction(path):
            original_mode, obj = entries.get(path, ('missing', None))
            original = git(repo, 'cat-file', 'blob', obj) if obj else b''
            if (mode, content) != (original_mode, original):
                dirty_instructions.append(path)
    for entry in index.split(b'\0'):
        if not entry:
            continue
        meta, path_bytes = entry.split(b'\t', 1)
        mode, obj, stage = meta.decode().split()
        path = os.fsdecode(path_bytes)
        if stage != '0':
            raise ValueError('unmerged index cannot be reviewed')
        if instruction(path) and entries.get(path) != (mode, obj):
            dirty_instructions.append(path)
    if scope == 'committed' and dirty_instructions:
        raise ValueError('dirty instruction surface outside committed target: ' + ', '.join(sorted(set(dirty_instructions))))
    if scope == 'committed':
        args = ('diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--no-color')
        full = git(repo, *args, '--binary', merge, head, '--')
        paths = [os.fsdecode(p) for p in git(repo, *args, '--name-only', '-z', merge, head, '--').split(b'\0') if p]
        # --text keeps executable text covered even when attributes call it binary.
        patch = git(repo, *args, '--text', merge, head, '--', '.', *(':!' + p for p in EXCLUDED))
    else:
        chunks, paths = [], []
        for path in sorted(set(entries) | tracked | untracked):
            original_mode, obj = entries.get(path, ('missing', None))
            original = git(repo, 'cat-file', 'blob', obj) if obj else b''
            mode, content = file_bytes(repo, path)
            if (mode, content) == (original_mode, original):
                continue
            paths.append(path)
            if excluded(path):
                continue
            before = original.decode('utf-8')
            after = content.decode('utf-8')
            header = f'diff --git a/{path} b/{path}\nold mode {original_mode}\nnew mode {mode}\n'
            lines = difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile='a/' + path, tofile='b/' + path)
            body = ''.join(line if line.endswith('\n') else line + '\n\\ No newline at end of file\n' for line in lines)
            chunks.append((header + body).encode())
        patch = b'\n'.join(chunks)
        full = encoded({'head': head, 'files': files, 'index': digest(index)})
    if b'\0' in patch:
        raise ValueError('binary content cannot be delivered in a fenced text review')
    patch.decode('utf-8')
    artifact = {'head': head, 'tree': tree, 'base': {'ref': base, 'commit': base_commit, 'merge_base': merge},
                'scope': scope, 'index_sha256': digest(index), 'worktree_sha256': digest(encoded(files)),
                'untracked_sha256': digest(encoded(sorted(untracked | ignored_instructions))),
                'diff_sha256': digest(full), 'review_diff_sha256': digest(patch), 'changed_paths': paths}
    return artifact, patch


def stable_capture(repo, base, scope):
    first, patch = capture(repo, base, scope)
    second, patch2 = capture(repo, base, scope)
    if first != second or patch != patch2:
        raise ValueError('repository changed during review snapshot')
    return first, patch


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix='.receipt-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(encoded(value) + b'\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('missing or unsafe receipt: ' + str(path))
    return json.loads(path.read_bytes())


def invalidate(receipts, lane):
    attempt = uuid.uuid4().hex
    atomic_json(receipts / (lane + '.attempt.json'), {'attempt': attempt})
    (receipts / (lane + '.json')).unlink(missing_ok=True)
    return attempt


def assert_attempt(record):
    _, _, receipts = layout(record['repository'])
    marker = read_json(receipts / (record['reviewer']['name'] + '.attempt.json'))
    if marker['attempt'] != record['attempt']:
        raise ValueError('review attempt was superseded; rerun the gate')


def validate_artifact(record):
    assert_attempt(record)
    artifact = record['artifact']
    current, patch = stable_capture(Path(record['repository']), artifact['base']['ref'], artifact['scope'])
    if artifact != current:
        raise ValueError('repository changed during review or after approval; rerun the gate')
    assert_attempt(record)
    return patch


def exemption(outcome, artifact, patch):
    if outcome == 'no-diff' and patch.strip():
        raise ValueError('no-diff exemption has reviewable content')
    if outcome == 'tier-1' and (not artifact['changed_paths'] or len(patch.splitlines()) > 200 or not all(docsafe(p) for p in artifact['changed_paths'])):
        raise ValueError('tier-1 exemption is not a small docs-only artifact')


def resolve_base(repo, requested=None):
    if not requested:
        try:
            requested = git(repo, 'symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD').decode().strip().replace('refs/remotes/origin/', '', 1)
        except subprocess.CalledProcessError as exc:
            if exc.returncode != 1:
                raise
            requested = 'main'
    for ref in ('origin/' + requested, requested):
        try:
            oid(repo, ref)
            return ref
        except subprocess.CalledProcessError:
            continue
    raise ValueError('base could not be resolved: ' + requested)


def begin(args):
    repo, directory, receipts = layout(args.repo)
    attempt = invalidate(receipts, args.reviewer)
    scope = args.scope
    if scope == 'auto':
        scope = 'committed' if git(repo, 'rev-list', '--max-count=1', oid(repo, args.base) + '..HEAD').strip() else 'uncommitted'
    artifact, patch = stable_capture(repo, args.base, scope)
    if args.scope == 'auto' and scope == 'uncommitted' and not artifact['changed_paths']:
        artifact, patch = stable_capture(repo, args.base, 'committed')
    run = Path(tempfile.mkdtemp(prefix='run-', dir=str(receipts)))
    (run / 'diff.patch').write_bytes(patch)
    os.chmod(run / 'diff.patch', 0o600)
    record = {'version': 1, 'attempt': attempt, 'repository': str(repo), 'git_directory': str(directory), 'artifact': artifact,
              'reviewer': {'name': args.reviewer, 'executable': args.executable or None},
              'started_at': datetime.now(timezone.utc).isoformat()}
    atomic_json(run / 'snapshot.json', record)
    print(run)


def complete(args):
    snapshot = Path(args.snapshot)
    record = read_json(snapshot)
    patch = validate_artifact(record)
    if (snapshot.parent / 'diff.patch').read_bytes() != patch:
        raise ValueError('review diff changed during review')
    exemption(args.outcome, record['artifact'], patch)
    output = Path(args.output).read_text() if args.output else ''
    if args.outcome == 'passed' and not output.strip():
        raise ValueError('completed review must have output')
    record['reviewer'].update(requested_model=args.requested_model, observed_model=args.observed_model,
                              model_evidence=args.model_evidence)
    record['completion'] = {'status': 'completed', 'outcome': args.outcome,
                            'completed_at': datetime.now(timezone.utc).isoformat(),
                            'output_sha256': digest(output.encode()), 'output': output}
    repo, directory, receipts = layout(record['repository'])
    if str(directory) != record['git_directory']:
        raise ValueError('Git directory changed during review')
    validate_artifact(record)
    atomic_json(receipts / (record['reviewer']['name'] + '.json'), record)
    print('Review receipt recorded for ' + record['artifact']['head'])


def check(args):
    repo, directory, receipts = layout(args.repo)
    head = oid(repo, args.head)
    if head != oid(repo, 'HEAD') or args.head != head:
        raise ValueError('outgoing commit is not the reviewed worktree HEAD')
    expected_base = oid(repo, resolve_base(repo, args.base))
    errors = []
    for lane in (args.reviewer,) if args.reviewer else LANES:
        try:
            record = read_json(receipts / (lane + '.json'))
            if (type(record['version']) is not int or record['version'] != 1 or record['repository'] != str(repo) or record['git_directory'] != str(directory)
                    or record['reviewer']['name'] != lane or record['artifact']['scope'] != 'committed'
                    or record['artifact']['head'] != head or record['completion']['status'] != 'completed'
                    or record['completion']['outcome'] not in ('passed', 'tier-1', 'no-diff')):
                raise ValueError('receipt identity, scope, or completion does not match')
            reviewer = record['reviewer']
            for field in ('requested_model', 'observed_model', 'model_evidence', 'executable'):
                if reviewer[field] is not None and not isinstance(reviewer[field], str):
                    raise ValueError('malformed reviewer identity')
            if expected_base != record['artifact']['base']['commit']:
                raise ValueError('receipt does not cover the expected base')
            completion = record['completion']
            started = datetime.fromisoformat(record['started_at'])
            completed = datetime.fromisoformat(completion['completed_at'])
            if started.tzinfo is None or completed.tzinfo is None or completed < started:
                raise ValueError('malformed completion timestamps')
            if digest(completion['output'].encode()) != completion['output_sha256']:
                raise ValueError('malformed review output')
            if completion['outcome'] == 'passed' and not completion['output'].strip():
                raise ValueError('completed review output is empty')
            patch = validate_artifact(record)
            exemption(completion['outcome'], record['artifact'], patch)
            print('Valid ' + lane + ' review receipt for ' + head)
            return
        except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as exc:
            errors.append(lane + ': ' + str(exc))
    raise ValueError('no valid committed review receipt; ' + '; '.join(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('begin', 'invalidate', 'check'):
        sub = commands.add_parser(name)
        sub.add_argument('--repo', default='.')
        sub.add_argument('--reviewer', choices=LANES, required=name != 'check')
        if name != 'invalidate':
            sub.add_argument('--base')
        if name == 'begin':
            sub.add_argument('--scope', choices=('auto', 'committed', 'uncommitted'), required=True)
            sub.add_argument('--executable')
        if name == 'check':
            sub.add_argument('--head', required=True)
    sub = commands.add_parser('verify')
    sub.add_argument('--snapshot', required=True)
    sub = commands.add_parser('complete')
    sub.add_argument('--snapshot', required=True)
    sub.add_argument('--outcome', choices=('passed', 'tier-1', 'no-diff'), required=True)
    sub.add_argument('--output')
    sub.add_argument('--requested-model')
    sub.add_argument('--observed-model')
    sub.add_argument('--model-evidence')
    args = parser.parse_args()
    try:
        if args.command == 'invalidate':
            _, _, receipts = layout(args.repo)
            invalidate(receipts, args.reviewer)
        elif args.command == 'verify':
            validate_artifact(read_json(Path(args.snapshot)))
        else:
            globals()[args.command](args)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as exc:
        print('review-receipt: ' + str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
