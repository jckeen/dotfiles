#!/usr/bin/env python3
"""Release completed tasks for explicit, evidence-backed worktree retirement.

Inventory and retirement preview are read-only. Release is an owner's assertion
that its session is finished; the timer never releases or removes worktrees.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone


MARKER = 'worktree-release.json'


def run(argv, cwd=None):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, timeout=30,
        env=dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_NO_REPLACE_OBJECTS='1', GIT_TERMINAL_PROMPT='0'))
    if result.returncode:
        raise ValueError(f'{argv[0]} could not verify evidence (exit {result.returncode})')
    return result.stdout


def git(repo, *args):
    return run(['git', '-c', 'core.fsmonitor=false', '-C', str(repo), *args])


def text(data):
    return os.fsdecode(data.removesuffix(b'\n'))


def worktrees(repo):
    items = []
    for block in git(repo, 'worktree', 'list', '--porcelain', '-z').split(b'\0\0'):
        fields = {}
        for line in block.split(b'\0'):
            key, _, value = line.partition(b' ')
            if key: fields[os.fsdecode(key)] = os.fsdecode(value)
        if 'worktree' in fields:
            fields['path'] = fields.pop('worktree')
            items.append(fields)
    return items


def selected(repo, path):
    path = path.resolve(strict=True)
    item = next((entry for entry in worktrees(repo) if Path(entry['path']) == path), None)
    if item is None:
        raise ValueError('not a registered worktree in this repository')
    admin = Path(text(git(path, 'rev-parse', '--absolute-git-dir')))
    common = Path(text(git(path, 'rev-parse', '--path-format=absolute', '--git-common-dir')))
    if admin == common:
        raise ValueError('the primary checkout must be retained')
    if 'locked' in item or 'prunable' in item:
        raise ValueError('locked or missing worktree must be retained')
    return item, admin


def marker(admin):
    path = admin / MARKER
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('release record is not a private regular file')
    data = json.loads(path.read_text())
    if data.get('schema') != 1 or not isinstance(data.get('owner'), str) or not data['owner']:
        raise ValueError('invalid release record')
    return data


def clean(path):
    entries = git(path, 'ls-files', '-v', '-z').split(b'\0')
    if any(entry and (entry[:1].islower() or entry[:1] == b'S') for entry in entries):
        raise ValueError('index flags hide worktree contents; retain for separate inspection')
    status = git(path, 'status', '--porcelain=v1', '-z', '--untracked-files=all',
                 '--ignored=matching', '--ignore-submodules=none')
    if status:
        raise ValueError('dirty, untracked, ignored or submodule work must be retained')
    if any(row.startswith(b'160000 ') for row in git(path, 'ls-files', '--stage', '-z').split(b'\0')):
        raise ValueError('worktrees with submodules require separate retirement')


def active_processes(path, proc_root=Path('/proc')):
    """Fail closed when process cwd visibility cannot establish inactivity."""
    if not proc_root.is_dir():
        raise ValueError('automatic process inspection requires /proc; retain on this platform')
    for entry in proc_root.iterdir():
        if not entry.name.isdigit(): continue
        try:
            if entry.stat().st_uid != os.getuid(): continue
            cwd = Path(os.readlink(entry / 'cwd'))
        except FileNotFoundError:
            continue  # Process exited or has no cwd (e.g. zombie).
        except OSError as error:
            raise ValueError('cannot inspect a same-user process; retain worktree') from error
        if cwd == path or path in cwd.parents:
            raise ValueError(f'active process {entry.name} uses this worktree')


def release(repo, path, head, owner, pr, slug):
    item, admin = selected(repo, path)
    path = Path(item['path'])
    if item['HEAD'] != head:
        raise ValueError('HEAD changed; owner must release the current artifact explicitly')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', slug) or pr <= 0 or not owner.strip():
        raise ValueError('release needs an owner and valid GitHub repository/PR')
    clean(path)
    active_processes(path)
    if (admin / MARKER).exists():
        previous = marker(admin)
        if previous['owner'] != owner:
            raise ValueError('another owner holds the release record')
    data = dict(schema=1, path=str(path), head=head, branch=item.get('branch'), owner=owner,
                pr=pr, github_repo=slug, released_at=datetime.now(timezone.utc).isoformat())
    with tempfile.NamedTemporaryFile(mode='w', dir=admin, delete=False) as stream:
        json.dump(data, stream, indent=2)
        temporary = Path(stream.name)
    try:
        os.replace(temporary, admin / MARKER)
    finally:
        temporary.unlink(missing_ok=True)
    return data


def assess(repo, path):
    item, admin = selected(repo, path)
    path = Path(item['path'])
    try:
        record = marker(admin)
    except FileNotFoundError as error:
        raise ValueError('unreleased worktree: its owner must release it first') from error
    if (record.get('head'), record.get('path'), record.get('branch')) != (item['HEAD'], str(path), item.get('branch')):
        raise ValueError('HEAD, path or branch changed since release')
    clean(path)
    active_processes(path)
    if any(admin.glob('*.lock')):
        raise ValueError('Git operation is active; retain worktree')
    slug = record['github_repo']
    actual_slug = text(run(['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'], cwd=repo))
    if slug != actual_slug:
        raise ValueError('release record belongs to a different GitHub repository')
    default = text(run(['gh', 'api', f'repos/{slug}', '--jq', '.default_branch']))
    git(repo, 'check-ref-format', 'refs/heads/' + default)
    # Verify the local evidence is still the current remote default. No fetch
    # occurs during preview; callers can refresh explicitly and retry.
    cookie_flags = ['-c', 'http.saveCookies=false']
    keys = git(repo, 'config', '--null', '--name-only', '--list').split(b'\0')
    for key in keys:
        name = os.fsdecode(key)
        if name.lower().startswith('http.') and name.lower().endswith('.savecookies'):
            cookie_flags.extend(['-c', name + '=false'])
    remote = git(repo, *cookie_flags, 'ls-remote', '--exit-code', 'origin', 'refs/heads/' + default).split()
    base = text(git(repo, 'rev-parse', '--verify', 'refs/remotes/origin/' + default))
    if len(remote) != 2 or os.fsdecode(remote[0]) != base:
        raise ValueError('remote evidence is stale or unavailable; fetch and retry')
    pr = json.loads(run(['gh', 'pr', 'view', str(record['pr']), '--repo', slug, '--json',
                        'state,headRefOid,baseRefName,mergeCommit,isCrossRepository']))
    if (pr.get('state') != 'MERGED' or pr.get('isCrossRepository') is not False
            or pr.get('headRefOid') != item['HEAD'] or pr.get('baseRefName') != default):
        raise ValueError('no merged same-repository PR for the exact released HEAD and default branch')
    merge = (pr.get('mergeCommit') or {}).get('oid', '')
    if not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', merge):
        raise ValueError('missing merged artifact identity')
    git(repo, 'merge-base', '--is-ancestor', merge, base)
    return item, admin, dict(record, merge=merge, default_head=base, default_branch=default)


def retire(repo, path, apply, archive_dir):
    item, admin, record = assess(repo, path)
    if not apply:
        return dict(disposition='ready', path=item['path'], owner=record['owner'], head=item['HEAD'])
    if archive_dir is None:
        raise ValueError('--apply requires an explicit private --archive-dir')
    archive_dir = archive_dir.resolve()
    for entry in worktrees(repo):
        root = Path(entry['path'])
        if archive_dir == root or root in archive_dir.parents:
            raise ValueError('archive must be outside repository worktrees')
    archive_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = archive_dir.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('archive directory must be private to the current user')
    archive = Path(tempfile.mkdtemp(prefix='retired-', dir=archive_dir))
    # Include reflog-only detached work before its worktree metadata disappears.
    # This adds pack objects without creating recovery refs in the source repo.
    git(path, 'bundle', 'create', str(archive / 'repository.bundle'), '--all', '--reflog')
    git(repo, 'bundle', 'verify', str(archive / 'repository.bundle'))
    with tarfile.open(archive / 'worktree-metadata.tar', 'w') as stream:
        stream.add(admin, arcname='worktree-metadata', recursive=True)
    record['files'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in archive.iterdir()}
    (archive / 'recovery.json').write_text(json.dumps(record, indent=2) + '\n')
    # Recheck after archival; git's non-force removal independently refuses
    # dirty/locked worktrees. Released ownership is required to avoid new work.
    again, _, current = assess(repo, path)
    if current != {k: v for k, v in record.items() if k != 'files'} or again != item:
        raise ValueError(f'worktree changed during archival; retained; archive: {archive}')
    git(repo, 'worktree', 'remove', str(path))
    return dict(disposition='removed', path=item['path'], head=item['HEAD'], archive=str(archive),
                branch='retained for normal branch hygiene')


def inventory(repo):
    output = []
    for item in worktrees(repo):
        result = dict(path=item['path'], head=item.get('HEAD'), disposition='retained', owner=None)
        try:
            _, admin = selected(repo, Path(item['path']))
            data = marker(admin)
            result.update(owner=data['owner'], pr=data['pr'])
            if data.get('head') != item.get('HEAD'):
                result['reason'] = 'HEAD changed since release'
            else:
                result.update(disposition='released', reason='owner finished; verify merged PR before retirement')
        except FileNotFoundError:
            result['reason'] = 'unreleased; active ownership or task disposition unknown'
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            result['reason'] = str(error)
            if str(error) == 'the primary checkout must be retained':
                result['disposition'] = 'primary'
        output.append(result)
    return dict(worktrees=output, retained=sum(i['disposition'] == 'retained' for i in output),
                released=sum(i['disposition'] == 'released' for i in output))


def inventory_root(root):
    output, errors = [], []
    for repo in sorted(root.resolve(strict=True).iterdir()):
        if repo.is_symlink() or not (repo / '.git').is_dir():
            continue
        try:
            output.extend(inventory(repo)['worktrees'])
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            errors.append(dict(repo=str(repo), reason=str(error)))
    return dict(worktrees=output, errors=errors,
                retained=sum(i['disposition'] == 'retained' for i in output),
                released=sum(i['disposition'] == 'released' for i in output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('inventory', 'release', 'retire'))
    parser.add_argument('--repo', type=Path)
    parser.add_argument('--root', type=Path, help='inventory primary repositories directly under this directory')
    parser.add_argument('--worktree', type=Path)
    parser.add_argument('--head')
    parser.add_argument('--owner')
    parser.add_argument('--pr', type=int)
    parser.add_argument('--github-repo')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--archive-dir', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.action == 'inventory' and args.root is not None:
            if args.repo is not None: raise ValueError('choose --repo or --root')
            result = inventory_root(args.root)
        elif args.repo is None: raise ValueError('--repo is required')
        elif args.root is not None: raise ValueError('--root is only supported for inventory')
        elif args.action == 'inventory': result = inventory(args.repo)
        elif args.worktree is None: raise ValueError('--worktree is required')
        elif args.action == 'release':
            if not all((args.head, args.owner, args.pr, args.github_repo)):
                raise ValueError('release requires --head, --owner, --pr and --github-repo')
            result = release(args.repo, args.worktree, args.head, args.owner, args.pr, args.github_repo)
        else: result = retire(args.repo, args.worktree.resolve(), args.apply, args.archive_dir)
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'worktree-lifecycle: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
