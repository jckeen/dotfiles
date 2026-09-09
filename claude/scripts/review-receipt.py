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
AGENT_NAMESPACES = ('codex', '.codex', 'antigravity', '.antigravity', '.agents', '.claude', '.gemini')
EXCLUDED = ('*-lock.yaml', '*-lock.json', 'package-lock.json', '*.lock', 'bun.lockb',
            '*.png', '*.jpg', '*.jpeg', '*.gif', '*.ico', '*.pdf', '*.min.css', '*.map')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(',', ':')).encode()


def git(repo, *args):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_NO_REPLACE_OBJECTS='1')
    # The helper supplies its own literal pathspecs; inherited switches can
    # suppress their magic, expand their matches, or conflict with each other.
    for name in ('GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS'):
        env.pop(name, None)
    return subprocess.check_output(['git', '-c', 'core.fsmonitor=false', '-C', str(repo), *args], env=env, stderr=subprocess.PIPE)


def oid(repo, ref):
    return git(repo, 'rev-parse', '--verify', '--end-of-options', ref + '^{commit}').decode().strip()


def named_instruction(path):
    name = Path(path).name
    return re.search(r'(AGENTS|CLAUDE|GEMINI|FABLE|MULTI-AGENT).*\.md$', name) is not None or name == 'SKILL.md'


def source_instruction(path):
    parts = Path(path).parts
    layouts = (('agents', 'skills'), ('agents', 'canon'), ('claude', 'skills'), ('claude', 'agents'))
    # Bundles include references/support files, not just their SKILL.md entrypoint.
    return (any(pair in layouts for pair in zip(parts, parts[1:]))
            or parts[-2:] in (('claude', 'AgentPack.md'), ('claude', 'AGENTPACK.yaml'), ('claude', 'agentpack-meta.json')))


def instruction(path):
    parts = Path(path).parts
    name = parts[-1]
    return (any(p in AGENT_NAMESPACES for p in parts)
            or source_instruction(path)
            or any(p in ('githooks', '.githooks') for p in parts)
            or ('claude', 'hooks') in zip(parts, parts[1:])
            or named_instruction(path)
            or name in ('gate-lib.sh', 'review-receipt.py', 'codex-review-gate.sh', 'antigravity-review-gate.sh'))


def private_agent_data(path):
    parts = Path(path).parts
    name = parts[-1]
    if (any(part in AGENT_NAMESPACES for part in parts[:-1]) or source_instruction(path)) and name in (
            'auth.json', '.credentials.json', 'credentials.json', 'oauth_creds.json', 'google_accounts.json'):
        return True
    if named_instruction(path):
        return False
    state_directories = {
        '.codex': ('sessions', 'log', 'logs', 'cache', 'tmp', 'shell_snapshots'),
        '.claude': ('sessions', 'projects', 'session-env', 'debug', 'cache', 'tmp', 'telemetry', 'statsig'),
        '.gemini': ('tmp', 'cache'),
    }
    for index, part in enumerate(parts[:-1]):
        if part not in state_directories:
            continue
        relative = parts[index + 1:]
        if relative[0] in state_directories[part] or name == 'history.jsonl':
            return True
        if part == '.codex' and fnmatch.fnmatchcase(name, 'state*.sqlite*'):
            return True
        if part == '.gemini' and len(relative) > 1 and relative[:2] in (
                ('antigravity-cli', 'conversations'), ('antigravity-cli', 'brain'), ('antigravity-cli', 'logs')):
            return True
    return False


def risk(path):
    lower = path.lower()
    risk_patterns = ('*AGENTPACK*', '.github/*', '*/.github/*', '*hooks/*', '*.githooks*', '*scripts/*')
    return (instruction(path) or any(fnmatch.fnmatchcase(path, pattern) for pattern in risk_patterns)
            or any(word in lower for word in ('auth', 'token', 'secret', 'credential', 'password', 'session', 'sso', 'crypt', 'hash', 'host', 'schema', 'migration')))


def passive_modes(modes):
    # Both sides matter: deletion, chmod, or replacement must not hide active files.
    return all(mode in ('missing', '100644') for mode in modes)


def excluded(path, modes):
    return (not risk(path) and passive_modes(modes)
            and any(fnmatch.fnmatchcase(Path(path).name, pattern) for pattern in EXCLUDED))


def docsafe(path):
    return (not risk(path)
            and (path.endswith(('.md', '.markdown', '.rst')) or Path(path).name in ('LICENSE', 'LICENSE.txt')))


def file_bytes(repo, path, directory_is_missing=False):
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
        if instruction(path):
            raise ValueError('instruction symlink targets are unsupported; review separately: ' + path)
        return '120000', os.fsencode(os.readlink(file))
    if stat.S_ISDIR(info.st_mode) and directory_is_missing:
        return 'missing', b''
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('cannot snapshot non-file: ' + path)
    return ('100755' if info.st_mode & 0o111 else '100644'), file.read_bytes()


def layout(repo):
    # Remove only Git's output delimiter: trailing whitespace belongs to paths.
    repo = Path(os.fsdecode(git(repo, 'rev-parse', '--show-toplevel').removesuffix(b'\n'))).resolve()
    directory = Path(os.fsdecode(git(repo, 'rev-parse', '--absolute-git-dir').removesuffix(b'\n'))).resolve()
    receipts = Path(os.fsdecode(git(repo, 'rev-parse', '--git-path', 'review-receipts').removesuffix(b'\n')))
    if not receipts.is_absolute():
        receipts = repo / receipts
    receipts = receipts.absolute()
    if receipts.is_symlink():
        raise ValueError('receipt directory must not be a symlink')
    receipts.mkdir(mode=0o700, exist_ok=True)
    os.chmod(receipts, 0o700)
    return repo, directory, receipts


def tree_files(repo, ref):
    entries = {}
    for entry in git(repo, 'ls-tree', '-rz', '--full-tree', ref).split(b'\0'):
        if entry:
            meta, path = entry.split(b'\t', 1)
            mode, kind, obj = meta.decode().split()
            if kind != 'blob':
                raise ValueError('submodule snapshots are unsupported; review separately')
            entries[os.fsdecode(path)] = (mode, obj)
    return entries


def crlf_normalized_paths(repo):
    autocrlf = git(repo, 'config', '--default', 'false', '--get', 'core.autocrlf').decode().strip().lower()
    if autocrlf != 'input':
        autocrlf = git(repo, 'config', '--type=bool', '--default', 'false', '--get', 'core.autocrlf').decode().strip()
    paths = set()
    # Native EOL metadata applies attributes without invoking clean filters.
    for entry in git(repo, 'ls-files', '--eol', '-z').split(b'\0'):
        if not entry:
            continue
        metadata, path = entry.split(b'\t', 1)
        attrs = metadata.partition(b'attr/')[2].split()
        if b'-text' not in attrs and (any(value in attrs for value in (b'text', b'text=auto', b'eol=lf', b'eol=crlf'))
                                     or not attrs and autocrlf in ('true', 'input')):
            paths.add(os.fsdecode(path))
    return paths


def same_content(path, mode, original, content, crlf_paths):
    return (content == original or mode in ('100644', '100755') and path in crlf_paths and b'\r' not in original and b'\0' not in original
            and content.replace(b'\r\n', b'\n') == original)


def capture(repo, base, scope):
    head = oid(repo, 'HEAD')
    base_commit = oid(repo, base) if base else None
    if scope == 'committed' and base_commit is None:
        raise ValueError('base could not be resolved')
    merge = git(repo, 'merge-base', base_commit, head).decode().strip() if scope == 'committed' else None
    tree = git(repo, 'rev-parse', head + '^{tree}').decode().strip()
    index = git(repo, 'ls-files', '--stage', '-t', '-z')
    staged, skipped = {}, set()
    for entry in index.split(b'\0'):
        if not entry:
            continue
        metadata, path_bytes = entry.split(b'\t', 1)
        tag, mode, obj, stage = metadata.decode().split()
        path = os.fsdecode(path_bytes)
        if mode == '160000':
            raise ValueError('submodule snapshots are unsupported; review separately')
        if stage != '0':
            raise ValueError('unmerged index cannot be reviewed')
        staged[path] = (mode, obj)
        if tag == 'S':
            skipped.add(path)
    sparse = git(repo, 'config', '--type=bool', '--default', 'false', '--get', 'core.sparseCheckout').strip() == b'true'
    entries = tree_files(repo, head)
    for path, (mode, _) in list(entries.items()) + list(staged.items()):
        if mode == '120000' and instruction(path):
            raise ValueError('instruction symlink targets are unsupported; review separately: ' + path)
    base_entries = tree_files(repo, merge) if scope == 'committed' else entries
    tracked = set(staged)
    tracked_files = {path for path, (mode, _) in staged.items() if mode in ('100644', '100755', '120000')}
    untracked = {os.fsdecode(p) for p in git(repo, 'ls-files', '--others', '--exclude-standard', '-z').split(b'\0') if p}
    paths = []
    if scope == 'committed':
        args = ('diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--no-color', '--ignore-submodules=none')
        paths = [os.fsdecode(p) for p in git(repo, *args, '--name-only', '-z', merge, head, '--').split(b'\0') if p]
    private_inputs = [path for path in set(entries) | tracked | untracked | set(paths) if private_agent_data(path)]
    if private_inputs:
        raise ValueError('private agent runtime data cannot be sent for review: ' + ', '.join(sorted(private_inputs)))
    ignored_instructions = {os.fsdecode(p) for p in git(repo, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z').split(b'\0')
                            if p and not private_agent_data(os.fsdecode(p)) and instruction(os.fsdecode(p))}
    files, workspace, omitted, blobs = {}, {}, set(), {}

    def blob(obj):
        if obj is None:
            return b''
        if obj not in blobs:
            blobs[obj] = git(repo, 'cat-file', 'blob', obj)
        return blobs[obj]

    dirty_instructions = [p for p in entries if instruction(p) and p not in tracked]
    for path in sorted(set(entries) | tracked | untracked | ignored_instructions):
        mode, content = file_bytes(repo, path, path in entries or path in tracked_files)
        files[path] = (mode, digest(content))
        workspace[path] = (mode, content)
        if mode == 'missing' and sparse and path in skipped:
            omitted.add(path)
    # Keep semantic cleanliness separate from the raw bytes bound above.
    crlf_paths = crlf_normalized_paths(repo) if any(b'\r\n' in data for mode, data in workspace.values()) else set()
    for path, (mode, content) in workspace.items():
        if instruction(path):
            original_mode, obj = entries.get(path, ('missing', None))
            if path not in omitted and (mode != original_mode or not same_content(path, mode, blob(obj), content, crlf_paths)):
                dirty_instructions.append(path)
            if path in staged and entries.get(path) != staged[path]:
                dirty_instructions.append(path)
    if scope == 'committed' and dirty_instructions:
        raise ValueError('dirty instruction surface outside committed target: ' + ', '.join(sorted(set(dirty_instructions))))
    changed_modes = {}
    if scope == 'committed':
        changed_modes = {path: [base_entries.get(path, ('missing', None))[0], entries.get(path, ('missing', None))[0]]
                         for path in paths}
        full = git(repo, *args, '--binary', merge, head, '--')
        # --text keeps executable text covered even when attributes call it binary.
        review_paths = [path for path in paths if not excluded(path, changed_modes[path])]
        patch = git(repo, *args, '--text', merge, head, '--', *(':(literal)' + path for path in review_paths)) if review_paths else b''
    else:
        chunks, paths = [], []
        for path in sorted(workspace):
            original_mode, obj = entries.get(path, ('missing', None))
            staged_mode, staged_obj = staged.get(path, ('missing', None))
            if path in omitted and (original_mode, obj) == (staged_mode, staged_obj):
                continue
            original, staged_content = blob(obj), blob(staged_obj)
            mode, content = (staged_mode, staged_content) if path in omitted else workspace[path]
            staged_changed = (original_mode, obj) != (staged_mode, staged_obj)
            worktree_changed = mode != staged_mode or not same_content(path, mode, staged_content, content, crlf_paths)
            if not staged_changed and not worktree_changed:
                continue
            paths.append(path)
            changed_modes[path] = [original_mode, staged_mode, mode]
            if excluded(path, changed_modes[path]):
                continue
            for label, changed, before_mode, before_bytes, after_mode, after_bytes in (
                    ('staged', staged_changed, original_mode, original, staged_mode, staged_content),
                    ('worktree', worktree_changed, staged_mode, staged_content, mode, content)):
                if not changed:
                    continue
                before, after = before_bytes.decode('utf-8'), after_bytes.decode('utf-8')
                header = f'diff --git a/{path} b/{path}\nreview state {label}\nold mode {before_mode}\nnew mode {after_mode}\n'
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
                'diff_sha256': digest(full), 'review_diff_sha256': digest(patch), 'changed_paths': paths,
                'changed_modes': changed_modes}
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


def classify_tier(artifact, patch, policy):
    max_lines = policy['tier1_max_lines']
    if not isinstance(max_lines, str):
        raise ValueError('malformed tier-1 policy')
    if not re.fullmatch(r'[0-9]+', max_lines):
        return {'tier': 2, 'reason': 'full pass (captured tier-1 cap is not a number)'}
    try:
        limit = int(max_lines)
    except ValueError:
        return {'tier': 2, 'reason': 'full pass (captured tier-1 cap is not supported)'}
    lines = len(patch.splitlines())
    if lines > limit:
        return {'tier': 2, 'reason': f'full pass (diff is {lines} lines > tier-1 cap {max_lines})'}
    if not artifact['changed_paths']:
        return {'tier': 2, 'reason': 'full pass (could not enumerate changed paths)'}
    for path in artifact['changed_paths']:
        if not passive_modes(artifact['changed_modes'][path]) or not docsafe(path):
            return {'tier': 2, 'reason': 'full pass (active, risk, or unclassified path: ' + path + ')'}
    return {'tier': 1, 'reason': f'docs-only diff, {lines} lines ≤ {max_lines}'}


def exemption(outcome, artifact, patch, policy):
    classification = classify_tier(artifact, patch, policy)
    if outcome == 'no-diff' and (patch.strip() or any(not excluded(path, artifact['changed_modes'][path])
                                                    for path in artifact['changed_paths'])):
        raise ValueError('no-diff exemption has reviewable content')
    if outcome == 'tier-1' and classification['tier'] != 1:
        raise ValueError('tier-1 exemption is not a small docs-only artifact')


def classify(args):
    snapshot = Path(args.snapshot)
    record = read_json(snapshot)
    patch = validate_artifact(record)
    if (snapshot.parent / 'diff.patch').read_bytes() != patch:
        raise ValueError('review diff changed during review')
    print(json.dumps(classify_tier(record['artifact'], patch, record['policy'])))


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
              'policy': {'tier1_max_lines': args.tier1_max_lines},
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
    exemption(args.outcome, record['artifact'], patch, record['policy'])
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
            # Wall time is audit metadata; attempt and artifact checks establish
            # freshness even when the system clock steps backward during review.
            if started.tzinfo is None or completed.tzinfo is None:
                raise ValueError('malformed completion timestamps')
            if digest(completion['output'].encode()) != completion['output_sha256']:
                raise ValueError('malformed review output')
            if completion['outcome'] == 'passed' and not completion['output'].strip():
                raise ValueError('completed review output is empty')
            patch = validate_artifact(record)
            exemption(completion['outcome'], record['artifact'], patch, record['policy'])
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
            sub.add_argument('--tier1-max-lines', default='200')
        if name == 'check':
            sub.add_argument('--head', required=True)
    for name in ('verify', 'classify'):
        sub = commands.add_parser(name)
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
