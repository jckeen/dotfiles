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
    staged = {}
    for row in git(path, 'ls-files', '--stage', '-z').split(b'\0'):
        if not row: continue
        metadata, name = row.split(b'\t', 1)
        mode, oid, stage = metadata.split()
        if stage != b'0': raise ValueError('unmerged index must be retained')
        staged[os.fsdecode(name)] = (mode, oid)
    committed = {}
    for row in git(path, 'ls-tree', '-r', '-z', 'HEAD').split(b'\0'):
        if not row: continue
        metadata, name = row.split(b'\t', 1)
        mode, _, oid = metadata.split()
        committed[os.fsdecode(name)] = (mode, oid)
    if staged != committed:
        raise ValueError('staged changes must be retained')
    if any(mode == b'160000' for mode, _ in staged.values()):
        raise ValueError('worktrees with submodules require separate retirement')
    # Git status applies clean/encoding filters and omits sockets, FIFOs and
    # empty directories. Inspect the actual filesystem and raw blob identities;
    # local bytes absent from the recovery bundle must never be discarded.
    algorithm = text(git(path, 'rev-parse', '--show-object-format'))
    if algorithm not in ('sha1', 'sha256'):
        raise ValueError('unsupported Git object format; retain worktree')
    parents = {str(parent) for name in staged for parent in Path(name).parents if str(parent) != '.'}
    seen = set()

    def scan_error(error):
        raise error

    for directory, dirs, files in os.walk(path, followlinks=False, onerror=scan_error):
        for name in dirs + files:
            file = Path(directory) / name
            relative = str(file.relative_to(path))
            info = file.lstat()
            if relative == '.git' and stat.S_ISREG(info.st_mode): continue
            if stat.S_ISDIR(info.st_mode):
                if relative not in parents:
                    raise ValueError('untracked or empty directory must be retained: ' + relative)
                continue
            expected = staged.get(relative)
            if expected is None:
                raise ValueError('untracked, ignored or special file must be retained: ' + relative)
            digest = hashlib.new(algorithm)
            if stat.S_ISREG(info.st_mode):
                mode = b'100755' if info.st_mode & stat.S_IXUSR else b'100644'
                with os.fdopen(os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as stream:
                    opened = os.fstat(stream.fileno())
                    if not stat.S_ISREG(opened.st_mode):
                        raise ValueError('file changed during inspection; retain worktree')
                    digest.update(f'blob {opened.st_size}\0'.encode())
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
            elif stat.S_ISLNK(info.st_mode):
                mode = b'120000'
                content = os.fsencode(os.readlink(file))
                digest.update(f'blob {len(content)}\0'.encode() + content)
            else:
                raise ValueError('special file must be retained: ' + relative)
            if (mode, digest.hexdigest().encode()) != expected:
                raise ValueError('raw local content or mode must be retained: ' + relative)
            seen.add(relative)
    if seen != staged.keys():
        raise ValueError('missing tracked files must be retained')
    # Even unchanged raw files can run configured drivers during Git's final
    # non-force removal. Retain active filter paths without executing a driver.
    if staged:
        attributes = git(path, 'check-attr', '-z', 'filter', '--', *staged).split(b'\0')
        if any(value not in (b'unspecified', b'unset') for value in attributes[2::3]):
            raise ValueError('active content filters require separate retirement')


def check_admin_metadata(admin):
    # Tar silently omits sockets, and an archived special-file node cannot
    # preserve a live endpoint. Never open these targets or follow symlinks.
    def scan_error(error):
        raise error

    for directory, dirs, files in os.walk(admin, followlinks=False, onerror=scan_error):
        for name in dirs + files:
            entry = Path(directory) / name
            mode = entry.lstat().st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
                raise ValueError('special Git metadata must be retained: ' + str(entry.relative_to(admin)))


def archived_metadata_matches(admin, archive):
    """Compare saved metadata with the final tree without following symlinks."""
    def scan_error(error):
        raise error

    paths = {'worktree-metadata': admin}
    for directory, dirs, files in os.walk(admin, followlinks=False, onerror=scan_error):
        for name in dirs + files:
            path = Path(directory) / name
            paths['worktree-metadata/' + path.relative_to(admin).as_posix()] = path
    with tarfile.open(archive) as saved:
        members = saved.getmembers()
        if {member.name for member in members} != paths.keys():
            return False
        for member in members:
            path = paths[member.name]
            info = path.lstat()
            if stat.S_IMODE(info.st_mode) != member.mode:
                return False
            if member.isdir():
                if not stat.S_ISDIR(info.st_mode): return False
            elif member.issym():
                if not stat.S_ISLNK(info.st_mode) or os.fsencode(os.readlink(path)) != os.fsencode(member.linkname):
                    return False
            elif member.isfile() or member.islnk():
                if not stat.S_ISREG(info.st_mode): return False
                # Hardlink entries resolve within the archive. The current
                # path must still be a regular file, opened without following
                # a replacement symlink or blocking on a replacement FIFO.
                with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as current:
                    opened = os.fstat(current.fileno())
                    if not stat.S_ISREG(opened.st_mode) or stat.S_IMODE(opened.st_mode) != member.mode:
                        return False
                    with saved.extractfile(member) as original:
                        while True:
                            chunk = original.read(1024 * 1024)
                            if current.read(1024 * 1024) != chunk: return False
                            if not chunk: break
            else:
                return False
    return True


def thread_exited(entry):
    """A dead task establishes only that thread's exit, never its group's."""
    try:
        status = (entry / 'status').read_bytes()
    except FileNotFoundError:
        try:
            entry.stat()
        except FileNotFoundError:
            return True
        raise
    state = next((line.split()[1:2] for line in status.split(b'\n') if line.startswith(b'State:')), [])
    if not state:
        raise OSError('process state unavailable')
    return state[0] in (b'Z', b'X')


def process_path_within(target, path):
    # Inspect link text only. Opening pipe/socket/anon-inode targets can block,
    # and resolving them as paths would invent filesystem evidence.
    if not target.startswith('/'):
        return False
    for candidate in (target, target.removesuffix(' (deleted)')):
        reference = Path(candidate)
        if reference == path or path in reference.parents:
            return True
    return False


def inspect_thread(path, entry):
    try:
        if thread_exited(entry): return
        identity = f'{entry.parent.parent.name} thread {entry.name}'
        for name in ('cwd', 'root', 'exe'):
            if process_path_within(os.readlink(entry / name), path):
                raise ValueError(f'active process {identity} uses this worktree ({name})')
        # Keep enumeration open: scanning our own descriptors otherwise
        # lists a temporary directory FD that is closed before readlink.
        with os.scandir(entry / 'fd') as descriptors:
            for descriptor in descriptors:
                if process_path_within(os.readlink(descriptor.path), path):
                    raise ValueError(f'active process {identity} uses this worktree (open descriptor)')
        # /proc maps escapes pathname newlines as literal \012. Compare
        # the encoded worktree path too, without decoding ambiguous names.
        mapped_path = Path(str(path).replace('\n', r'\012'))
        observed_mapping = False
        with (entry / 'maps').open('rb') as mappings:
            for line in mappings:
                fields = line.removesuffix(b'\n').split(maxsplit=5)
                if len(fields) < 5:
                    raise OSError('invalid process mapping evidence')
                observed_mapping = True
                if len(fields) == 6 and process_path_within(os.fsdecode(fields[5]), mapped_path):
                    raise ValueError(f'active process {identity} uses this worktree (memory mapping)')
        if not observed_mapping:
            raise OSError('process mapping evidence unavailable')
    except FileNotFoundError:
        if not thread_exited(entry): raise


def active_processes(path, proc_root=Path('/proc')):
    """Retain visible thread references; missing live-task evidence is unsafe."""
    if not proc_root.is_dir():
        raise ValueError('automatic process inspection requires /proc; retain on this platform')
    for entry in proc_root.iterdir():
        if not entry.name.isdigit(): continue
        try:
            if entry.stat().st_uid != os.getuid(): continue
            # The leader may be a zombie while workers still hold references.
            # Threads can also have private cwd/root and descriptor tables.
            tasks = entry / 'task'
            threads = {thread.name for thread in tasks.iterdir() if thread.name.isdigit()}
            if not threads:
                raise OSError('process thread evidence unavailable')
            for name in sorted(threads):
                inspect_thread(path, tasks / name)
            if threads != {thread.name for thread in tasks.iterdir() if thread.name.isdigit()}:
                raise OSError('process threads changed during inspection')
        except OSError as error:
            # Only disappearance of the group directory establishes group exit.
            # A zombie leader cannot excuse missing live-worker evidence.
            if isinstance(error, FileNotFoundError):
                try:
                    entry.stat()
                except FileNotFoundError:
                    continue
                except OSError:
                    pass
            raise ValueError('cannot inspect a same-user process; retain worktree') from error


def release(repo, path, head, owner, pr, slug):
    item, admin = selected(repo, path)
    path = Path(item['path'])
    if item['HEAD'] != head:
        raise ValueError('HEAD changed; owner must release the current artifact explicitly')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', slug) or pr <= 0 or not owner.strip():
        raise ValueError('release needs an owner and valid GitHub repository/PR')
    clean(path)
    check_admin_metadata(admin)
    active_processes(path)
    active_processes(admin)
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
    check_admin_metadata(admin)
    active_processes(path)
    active_processes(admin)
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
    common = Path(text(git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'))).resolve(strict=True)
    invoking_admin = Path(text(git(repo, 'rev-parse', '--absolute-git-dir'))).resolve(strict=True)
    if invoking_admin != common:
        raise ValueError('--apply requires --repo to identify the primary checkout')
    # worktree list can report the common metadata path as the primary when
    # --separate-git-dir is used. Resolve the actual primary from its checkout;
    # a metadata-only invocation cannot establish that top-level and must fail.
    primary = Path(text(git(repo, 'rev-parse', '--show-toplevel'))).resolve(strict=True)
    excluded = {primary, common, admin.resolve(strict=True)}
    excluded.update(Path(entry['path']).resolve() for entry in worktrees(repo))
    for root in excluded:
        if archive_dir == root or root in archive_dir.parents:
            raise ValueError('archive must be outside repository worktrees and Git metadata')
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
    # A completed writer no longer appears in process evidence. Bind the
    # final source state to the actual saved bytes, including archive hardlinks;
    # ignore access/modify timestamps that do not change recoverable content.
    try:
        if not archived_metadata_matches(admin, archive / 'worktree-metadata.tar'):
            raise ValueError('metadata differs from archive')
    except (OSError, ValueError, tarfile.TarError) as error:
        raise ValueError(f'Git metadata changed or could not be verified; retained; archive: {archive}') from error
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
            if (data.get('head'), data.get('path'), data.get('branch')) != (
                    item.get('HEAD'), item['path'], item.get('branch')):
                result['reason'] = 'HEAD, path or branch changed since release'
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
    seen = set()
    for repo in sorted(root.resolve(strict=True).iterdir()):
        if repo.is_symlink():
            continue
        try:
            if not repo.is_dir(): continue
            try:
                info = (repo / '.git').lstat()
            except FileNotFoundError:
                continue
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise ValueError('.git is not a regular file or directory')
            # Both primary separate-git-dir checkouts and linked worktrees
            # use Git files. Their canonical admin/common identities differ
            # only for linked worktrees; discover each primary repository once.
            admin = Path(text(git(repo, 'rev-parse', '--absolute-git-dir'))).resolve(strict=True)
            common = Path(text(git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'))).resolve(strict=True)
            if admin != common or common in seen:
                continue
            seen.add(common)
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
