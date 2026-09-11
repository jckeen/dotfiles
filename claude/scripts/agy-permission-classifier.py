#!/usr/bin/env python3
"""Antigravity Permission Classifier (PreToolUse Hook).

Evaluates proposed tool calls (shell commands, file reads, and file writes)
before execution in Antigravity (agy). Mirrors the safety and auto-approval
behavior of Claude Code's `--permission-mode auto` and Codex's execution policies:

- Auto-approves safe read-only inspection, testing, linting, and standard dev commands.
- Hard-blocks dangerous/destructive operations, privilege escalation, credential theft,
  and destructive git commands on protected branches.
- Prompts for confirmation ('ask') on state-changing, dependency, network, or unfamiliar commands.

Contract:
- Input on stdin: JSON object with toolCall ({name, args}), workspacePaths, etc.
- Output on stdout: JSON object {"decision": "allow" | "deny" | "ask" | "force_ask", "reason": "..."}
- Always exits 0 with a valid JSON decision to prevent wedging the agent loop.
"""

import json
import os
from pathlib import Path
import re
import shlex
import sys

# Commands that are strictly read-only inspection and safe to auto-approve
SAFE_INSPECTION_COMMANDS = {
    'ls', 'dir', 'vdir', 'pwd', 'echo', 'printf',
    'cat', 'head', 'tail', 'less', 'more', 'wc',
    'grep', 'egrep', 'fgrep', 'rg', 'ag',
    'file', 'stat', 'diff', 'cmp',
    'which', 'whereis', 'type',
    'date', 'uptime', 'whoami', 'id', 'uname',
    'true', 'false', 'test', '[',
    'sort', 'uniq', 'cut', 'column', 'jq',
}

# Standard directories containing system binaries
SYSTEM_BIN_DIRS = {'/bin', '/usr/bin', '/usr/local/bin', '/sbin', '/usr/sbin'}

# Safe git subcommands that only inspect state
SAFE_GIT_READ_SUBCOMMANDS = {
    'status', 'diff', 'log', 'show', 'branch', 'rev-parse',
    'rev-list', 'check-ref-format', 'ls-files', 'remote',
    'describe', 'cat-file', 'tag', 'shortlog', 'blame',
    'version',
}

# Safe git subcommands that modify local stage/working copy without destroying work
SAFE_GIT_WORKFLOW_SUBCOMMANDS = {
    'add', 'commit', 'fetch',
}

# Subcommands / script prefixes for package managers that are safe to run
SAFE_RUN_PREFIXES = ('test', 'lint', 'check', 'typecheck', 'build', 'format', 'compile', 'verify', 'doc')

# Sensitive files and credential paths that should NEVER be read or written
SENSITIVE_CREDENTIAL_PREFIXES = (
    os.path.expanduser('~/.ssh'),
    os.path.expanduser('~/.aws'),
    os.path.expanduser('~/.gnupg'),
    os.path.expanduser('~/.netrc'),
    '/etc/shadow',
    '/etc/sudoers',
)

SENSITIVE_FILENAMES = {
    'antigravity-oauth-token',
    'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa',
    '.bashrc', '.bash_profile', '.zshrc', '.profile',
    'hosts.yml',
}

# System directories that should never be modified/written to
SYSTEM_WRITE_PREFIXES = (
    '/etc', '/boot', '/sys', '/proc', '/dev', '/usr', '/bin', '/sbin', '/var', '/lib',
)

# Dangerous environment variables that alter binary loading or runtime execution
DANGEROUS_ENV_VARS = {
    'LD_PRELOAD', 'LD_LIBRARY_PATH', 'DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH',
    'PYTHONPATH', 'NODE_OPTIONS', 'PERL5OPT', 'RUBYOPT', 'BASH_ENV', 'ENV',
}

PROTECTED_BRANCHES = {'main', 'master', 'release', 'prod', 'production'}


def expand_path(p_str, cwd=None):
    """Safely expand user, variables, and relative paths against cwd."""
    if not p_str or not isinstance(p_str, str):
        return ''
    # Expand ~ and environment variables ($HOME, etc.)
    expanded = os.path.expanduser(os.path.expandvars(p_str))
    effective_cwd = cwd or os.getcwd()
    if not os.path.isabs(expanded):
        expanded = os.path.join(effective_cwd, expanded)
    try:
        # Resolve symlinks to prevent path traversal via symlinks
        return str(Path(expanded).resolve())
    except Exception:
        return os.path.abspath(expanded)


def is_sensitive_credential_path(path_str, cwd=None):
    """Check if a path targets credentials, private keys, or tokens."""
    if not path_str or not isinstance(path_str, str):
        return False
    if path_str == '/dev/null':
        return False
    norm = expand_path(path_str, cwd)
    for prefix in SENSITIVE_CREDENTIAL_PREFIXES:
        norm_prefix = str(Path(prefix).resolve()) if os.path.exists(prefix) else os.path.abspath(prefix)
        if norm == norm_prefix or norm.startswith(norm_prefix + os.sep):
            return True
    if os.path.basename(norm) in SENSITIVE_FILENAMES:
        return True
    if re.search(r'(^|/)\.env(\..+)?$', norm):
        return True
    return False


def is_system_write_path(path_str, cwd=None):
    """Check if path targets system directories for writing."""
    if not path_str or not isinstance(path_str, str):
        return False
    if path_str == '/dev/null':
        return False
    norm = expand_path(path_str, cwd)
    for prefix in SYSTEM_WRITE_PREFIXES:
        norm_prefix = str(Path(prefix).resolve()) if os.path.exists(prefix) else os.path.abspath(prefix)
        if norm == norm_prefix or norm.startswith(norm_prefix + os.sep):
            return True
    return False


def is_path_in_workspaces(target_path, workspace_paths, cwd=None):
    """Check if target_path resides strictly within one of the declared workspace directories."""
    if not target_path or not isinstance(target_path, str):
        return False
    if target_path == '/dev/null':
        return True
    try:
        norm_target = expand_path(target_path, cwd)
        effective_workspaces = workspace_paths or [cwd or os.getcwd()]
        for ws in effective_workspaces:
            norm_ws = expand_path(ws, cwd)
            if norm_target == norm_ws or norm_target.startswith(norm_ws + os.sep):
                return True
    except Exception:
        return False
    return False


def tokenize_command_line(line):
    """Tokenize a single shell command line without stripping comments prematurely."""
    try:
        s = shlex.shlex(line, posix=True, punctuation_chars=True)
        s.whitespace_split = True
        s.commenters = ''
        return list(s)
    except Exception:
        return None


def split_into_subcommands(tokens):
    """Split tokens on command chaining and pipeline operators."""
    subcommands = []
    current = []
    pipeline_links = []

    separators = {'&&', '||', ';', '|', '&'}

    for tok in tokens:
        if tok in separators:
            if current:
                subcommands.append(current)
                if tok == '|':
                    pipeline_links.append((len(subcommands) - 1, '|'))
                current = []
        else:
            current.append(tok)

    if current:
        subcommands.append(current)

    return subcommands, pipeline_links


def parse_refspec_dest(refspec):
    """Extract the destination branch name from a git refspec."""
    spec = refspec.lstrip('+')
    if ':' in spec:
        dest = spec.split(':', 1)[1]
    else:
        dest = spec
    # Strip leading refs/heads/ or refs/remotes/
    dest = re.sub(r'^refs/(heads|remotes/[^/]+)/', '', dest)
    return dest


def classify_subcommand(tokens, workspace_paths, cwd):
    """Classify a single atomic subcommand (list of tokens).

    Returns (verdict, reason) where verdict is 'allow', 'deny', or 'ask'.
    """
    if not tokens:
        return 'allow', 'Empty subcommand'

    # Unwrap shell builtins like 'command' or 'builtin'
    while tokens and tokens[0] in ('command', 'builtin'):
        tokens = tokens[1:]

    # Check for leading environment variable assignments
    idx = 0
    while idx < len(tokens) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', tokens[idx]):
        var_name = tokens[idx].split('=', 1)[0]
        if var_name in DANGEROUS_ENV_VARS:
            return 'deny', f"Setting dangerous runtime execution variable is forbidden: {var_name}"
        idx += 1

    cmd_tokens = tokens[idx:]
    if not cmd_tokens:
        return 'allow', 'Environment assignment'

    raw_cmd = cmd_tokens[0]
    args = cmd_tokens[1:]

    # Resolve executable: prevent ./malicious/ls by checking if path is explicit
    if '/' in raw_cmd:
        resolved_exe = expand_path(raw_cmd, cwd)
        exe_dir = os.path.dirname(resolved_exe)
        if exe_dir not in SYSTEM_BIN_DIRS:
            # Running an arbitrary script or binary outside system PATH
            # Exception: designated local test/hygiene scripts in workspace
            script_name = os.path.basename(resolved_exe)
            if re.match(r'^(check-.*\.sh|git-hygiene\.sh|hygiene-status\.sh)$', script_name) and is_path_in_workspaces(resolved_exe, workspace_paths, cwd):
                base_cmd = script_name
            else:
                return 'ask', f"Running non-system executable requires confirmation: {raw_cmd}"
        else:
            base_cmd = os.path.basename(resolved_exe)
    else:
        base_cmd = raw_cmd

    # 1. Output redirections: verify redirection targets
    for i, tok in enumerate(tokens):
        if tok in ('>', '>>', '>&') and i + 1 < len(tokens):
            target = tokens[i + 1]
            if target == '/dev/null':
                continue
            if is_sensitive_credential_path(target, cwd) or is_system_write_path(target, cwd):
                return 'deny', f"Redirect targeting sensitive or system path is forbidden: {target}"
            if not is_path_in_workspaces(target, workspace_paths, cwd):
                return 'ask', f"Redirecting output outside workspace requires approval: {target}"

    # 2. Check for sensitive files being read or targeted in arguments
    for arg in args:
        # Ignore options with values unless they specify paths
        val = arg.split('=', 1)[1] if arg.startswith('--') and '=' in arg else arg
        if val != '/dev/null' and is_sensitive_credential_path(val, cwd):
            return 'deny', f"Access to sensitive credential or key is forbidden: {arg}"

    # 3. Privilege Escalation (Hard Deny)
    if base_cmd in {'sudo', 'su', 'doas', 'pkexec', 'chroot'}:
        return 'deny', f"Privilege escalation command is forbidden: {base_cmd}"

    # 4. Destructive Disk Operations (Hard Deny)
    if base_cmd.startswith('mkfs') or base_cmd in {'fdisk', 'gdisk', 'parted', 'wipefs'}:
        return 'deny', f"Destructive disk partitioning or formatting is forbidden: {base_cmd}"
    if base_cmd == 'dd':
        for arg in args:
            if arg.startswith('of=/dev/') and arg != 'of=/dev/null':
                return 'deny', f"Direct device overwrite with dd is forbidden: {arg}"

    # 5. Reverse Shells & Network Exfiltration (Hard Deny)
    if base_cmd in {'nc', 'ncat', 'socat'}:
        if any(a in ('-e', '-c', 'exec') for a in args):
            return 'deny', f"Reverse shell execution is forbidden: {base_cmd}"

    # 6. Destructive Deletions (rm)
    if base_cmd == 'rm':
        is_recursive = any(a in ('-r', '-R', '-rf', '-fr') or (a.startswith('-') and 'r' in a) for a in args)
        targets = [a for a in args if not a.startswith('-')]
        if is_recursive:
            for t in targets:
                t_norm = expand_path(t, cwd)
                if t in ('/', '/*', '~', '~/*', '$HOME') or t_norm in ('/', expand_path('~', cwd)):
                    return 'deny', f"Recursive deletion targeting root or home directory is forbidden: rm {t}"
                for ws in (workspace_paths or [cwd]):
                    ws_norm = expand_path(ws, cwd)
                    if t_norm == ws_norm:
                        return 'deny', f"Recursive deletion of entire workspace root is forbidden: rm {t}"
            return 'ask', f"Recursive directory deletion requires confirmation: {' '.join(cmd_tokens)}"
        # Non-recursive rm on individual files inside workspace
        if targets and all(is_path_in_workspaces(t, workspace_paths, cwd) and not is_sensitive_credential_path(t, cwd) for t in targets):
            return 'allow', f"Safe workspace file deletion: {' '.join(cmd_tokens)}"
        return 'ask', f"File deletion requires confirmation: {' '.join(cmd_tokens)}"

    # 7. Git Operations
    if base_cmd == 'git':
        if not args:
            return 'allow', 'git command query'
        git_sub = args[0]

        # Force push detection (including refspecs and + prefixes)
        if git_sub == 'push':
            has_force = any(a in ('--force', '-f', '--force-with-lease') or a.startswith('+') for a in args)
            refspecs = [a for a in args[1:] if not a.startswith('-') and a != 'origin']
            for spec in refspecs:
                dest = parse_refspec_dest(spec)
                if dest in PROTECTED_BRANCHES:
                    return 'deny', f"Force push or direct push to protected branch '{dest}' is forbidden: {' '.join(cmd_tokens)}"
            if has_force:
                if not refspecs:
                    return 'deny', f"Unscoped force push is forbidden: {' '.join(cmd_tokens)}"
                return 'ask', f"Force push requires confirmation: {' '.join(cmd_tokens)}"
            return 'ask', f"Git push modifies remote repository: {' '.join(cmd_tokens)}"

        # Destructive git operations
        if git_sub == 'clean':
            return 'ask', f"Git clean alters working tree: {' '.join(cmd_tokens)}"
        if git_sub == 'reset':
            return 'ask', f"Git reset alters working tree: {' '.join(cmd_tokens)}"
        if git_sub == 'restore':
            return 'ask', f"Git restore discards working changes: {' '.join(cmd_tokens)}"
        if git_sub == 'checkout':
            if any(a in ('-f', '--force', '--') for a in args):
                return 'ask', f"Forced checkout or discard requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git checkout'
        if git_sub == 'switch':
            if any(a in ('--discard-changes', '-f', '--force') for a in args):
                return 'ask', f"Discarding changes via git switch requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git switch'
        if git_sub == 'stash':
            if any(a in ('clear', 'drop') for a in args):
                return 'ask', f"Dropping stash requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git stash'
        if git_sub == 'worktree':
            if any(a in ('remove', 'prune') for a in args):
                return 'ask', f"Removing worktree requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git worktree'

        # Safe read queries
        if git_sub in SAFE_GIT_READ_SUBCOMMANDS:
            return 'allow', f"Safe git read query: git {git_sub}"

        # Git config
        if git_sub == 'config':
            if any(a in ('--get', '--get-all', '--list', '-l') for a in args):
                return 'allow', 'Safe git config query'
            return 'ask', 'Git config modification requires confirmation'

        # Safe workflow
        if git_sub in SAFE_GIT_WORKFLOW_SUBCOMMANDS:
            return 'allow', f"Safe git workflow: git {git_sub}"

        if git_sub == 'branch':
            return 'allow', 'Safe local branch operation'

    # 8. Inspection Commands
    if base_cmd in SAFE_INSPECTION_COMMANDS:
        return 'allow', f"Safe inspection command: {base_cmd}"

    # find command: safe ONLY without destructive or execution options
    if base_cmd == 'find':
        if any(a in ('-delete', '-exec', '-execdir', '-ok', '-okdir') for a in args):
            return 'ask', f"find with action options requires confirmation: {' '.join(cmd_tokens)}"
        return 'allow', 'Safe find command'

    # Local Repository Health Checks
    if re.match(r'^(check-.*\.sh|git-hygiene\.sh|hygiene-status\.sh)$', base_cmd):
        return 'allow', f"Safe local repository health check: {base_cmd}"

    # 9. Test, Lint, and Build Runners
    if base_cmd in {'npm', 'pnpm', 'yarn', 'bun'}:
        if args:
            sub = args[0]
            if sub == 'test' or sub.startswith('test'):
                return 'allow', f"Safe package manager test: {base_cmd} {sub}"
            if sub == 'run' and len(args) > 1:
                run_target = args[1]
                if any(run_target.startswith(prefix) for prefix in SAFE_RUN_PREFIXES):
                    return 'allow', f"Safe package script: {base_cmd} run {run_target}"
            if sub in {'install', 'i', 'add', 'remove', 'uninstall', 'update', 'publish'}:
                return 'ask', f"Package management alters dependencies: {base_cmd} {sub}"
        return 'ask', f"Package manager command requires confirmation: {' '.join(cmd_tokens)}"

    if base_cmd == 'npx':
        if args:
            tool = args[0]
            # Disallow installation operations like npx playwright install
            if any(a in ('install', 'init', 'create', 'download') for a in args[1:]):
                return 'ask', f"npx tool installation requires confirmation: {' '.join(cmd_tokens)}"
            if tool in {'tsc', 'eslint', 'prettier', 'jest', 'vitest'}:
                return 'allow', f"Safe static tool via npx: {tool}"
        return 'ask', f"npx execution requires confirmation: {' '.join(cmd_tokens)}"

    if base_cmd == 'cargo':
        if args:
            sub = args[0]
            if sub in {'test', 'check', 'clippy', 'build', 'bench', 'fmt'}:
                return 'allow', f"Safe cargo command: cargo {sub}"
            if sub in {'install', 'publish', 'add', 'remove'}:
                return 'ask', f"Cargo dependency modification requires confirmation: cargo {sub}"
        return 'ask', f"Cargo command requires confirmation: {' '.join(cmd_tokens)}"

    if base_cmd in {'pytest', 'ruff', 'mypy', 'flake8', 'black', 'pylint'}:
        return 'allow', f"Safe Python dev tool: {base_cmd}"

    if base_cmd in {'python', 'python3'}:
        if args and args[0] == '-m' and len(args) > 1:
            module = args[1]
            if module in {'unittest', 'pytest', 'mypy', 'ruff', 'flake8'}:
                return 'allow', f"Safe python module: {module}"
        # Arbitrary python scripts should require approval to prevent write-and-execute bypasses
        return 'ask', f"Executing Python script requires confirmation: {' '.join(cmd_tokens)}"

    if base_cmd == 'go':
        if args and args[0] in {'test', 'vet', 'fmt', 'build'}:
            return 'allow', f"Safe Go tool: go {args[0]}"

    if base_cmd == 'make':
        if not args or all(a in {'test', 'check', 'lint', 'build', 'clean', 'all'} for a in args):
            return 'allow', f"Safe make target: {' '.join(args) or 'default'}"

    # 10. Safe Local File Operations (cp / mv)
    if base_cmd in {'cp', 'mv'}:
        # Check destinations inside options like --target-directory=...
        targets = []
        for a in args:
            if a.startswith('--target-directory='):
                targets.append(a.split('=', 1)[1])
            elif not a.startswith('-'):
                targets.append(a)
        if targets and all(is_path_in_workspaces(t, workspace_paths, cwd) and not is_sensitive_credential_path(t, cwd) and not is_system_write_path(t, cwd) for t in targets):
            return 'allow', f"Safe file move/copy within workspace: {base_cmd}"
        return 'ask', f"File copy/move outside workspace requires approval: {' '.join(cmd_tokens)}"

    if base_cmd in {'mkdir', 'touch'}:
        targets = [a for a in args if not a.startswith('-')]
        if targets and all(is_path_in_workspaces(t, workspace_paths, cwd) and not is_system_write_path(t, cwd) for t in targets):
            return 'allow', f"Safe directory/file creation within workspace: {base_cmd}"

    # Fallback to interactive confirmation for unknown or state-changing commands
    return 'ask', f"Command requires confirmation: {' '.join(cmd_tokens)}"


def classify_command_line(cmd_str, workspace_paths, cwd):
    """Classify an entire shell command line string across lines, chains, and pipelines."""
    if not isinstance(cmd_str, str) or not cmd_str.strip():
        return 'ask', 'Empty command line or invalid type'

    # Check for command substitutions $(...) or `...` or process substitutions <(...) >(...)
    if re.search(r'(\$\(|\`|<(?=\()|>(?=\())', cmd_str):
        return 'ask', 'Command contains command or process substitution'

    # Split on newlines first so newlines cannot hide subsequent commands
    lines = [line.strip() for line in cmd_str.splitlines() if line.strip()]
    if not lines:
        return 'allow', 'Empty command'

    for line in lines:
        tokens = tokenize_command_line(line)
        if tokens is None:
            return 'ask', 'Unable to safely parse command tokens'

        subcommands, pipeline_links = split_into_subcommands(tokens)
        if not subcommands:
            continue

        # Check for network commands piped directly into shells (curl ... | bash)
        for sub_idx, op in pipeline_links:
            if sub_idx + 1 < len(subcommands):
                left_sub = subcommands[sub_idx]
                right_sub = subcommands[sub_idx + 1]

                left_base = os.path.basename(left_sub[0]) if left_sub else ''
                right_base = os.path.basename(right_sub[0]) if right_sub else ''

                if left_base in {'curl', 'wget', 'fetch'} and right_base in {'sh', 'bash', 'zsh', 'python', 'python3', 'node', 'perl', 'ruby'}:
                    return 'deny', f"Piping remote download ({left_base}) directly into interpreter ({right_base}) is forbidden"

        for sub in subcommands:
            verdict, reason = classify_subcommand(sub, workspace_paths, cwd)
            if verdict == 'deny':
                return 'deny', reason
            elif verdict == 'ask':
                return 'ask', reason

    return 'allow', 'Safe command auto-approved by classifier'


def classify_file_modification(target_file, workspace_paths, cwd):
    """Classify file write or replacement tools."""
    if not target_file or not isinstance(target_file, str):
        return 'ask', 'No target file specified or invalid type'

    if is_sensitive_credential_path(target_file, cwd) or is_system_write_path(target_file, cwd):
        return 'deny', f"Modifying sensitive or system path is forbidden: {target_file}"

    if is_path_in_workspaces(target_file, workspace_paths, cwd):
        return 'allow', f"File modification within workspace auto-approved: {os.path.basename(target_file)}"

    return 'ask', f"File modification outside workspace requires approval: {target_file}"


def classify_file_read(target_file, cwd):
    """Classify read-only file access tools."""
    if not target_file or not isinstance(target_file, str):
        return 'allow', 'File read query'
    if is_sensitive_credential_path(target_file, cwd):
        return 'deny', f"Reading sensitive credentials is forbidden: {target_file}"
    return 'allow', f"Safe file read: {os.path.basename(target_file)}"


def main():
    try:
        raw_input = sys.stdin.read()
    except Exception:
        raw_input = ''

    if not raw_input.strip():
        print(json.dumps({'decision': 'ask', 'reason': 'Permission classifier: empty input payload'}))
        return

    try:
        data = json.loads(raw_input)
    except Exception as e:
        print(json.dumps({'decision': 'ask', 'reason': f"Permission classifier: payload JSON parse error: {e}"}))
        return

    if not isinstance(data, dict):
        print(json.dumps({'decision': 'ask', 'reason': 'Permission classifier: payload must be a JSON object'}))
        return

    # Environment overrides
    mode = os.environ.get('ANTIGRAVITY_CLASSIFIER_MODE', '').lower()
    if mode in ('disabled', 'off'):
        print(json.dumps({'decision': 'ask', 'reason': 'Classifier disabled via ANTIGRAVITY_CLASSIFIER_MODE'}))
        return
    if mode in ('allow_all', 'bypass'):
        print(json.dumps({'decision': 'allow', 'reason': 'Bypassed via ANTIGRAVITY_CLASSIFIER_MODE=allow_all'}))
        return

    tool_call = data.get('toolCall')
    if not isinstance(tool_call, dict):
        print(json.dumps({'decision': 'ask', 'reason': 'Permission classifier: toolCall object missing or invalid'}))
        return

    tool_name = tool_call.get('name')
    if not isinstance(tool_name, str) or not tool_name:
        print(json.dumps({'decision': 'ask', 'reason': 'Permission classifier: tool name missing or invalid'}))
        return

    args = tool_call.get('args')
    if not isinstance(args, dict):
        print(json.dumps({'decision': 'ask', 'reason': 'Permission classifier: tool args must be an object'}))
        return

    workspace_paths = data.get('workspacePaths')
    if not isinstance(workspace_paths, list):
        workspace_paths = []

    cwd = args.get('Cwd') or args.get('cwd') or os.getcwd()

    if tool_name == 'run_command':
        cmd = args.get('CommandLine') or args.get('command')
        if cmd is None or not isinstance(cmd, str):
            decision, reason = 'ask', 'run_command CommandLine argument is missing or invalid'
        else:
            decision, reason = classify_command_line(cmd, workspace_paths, cwd)
    elif tool_name in ('write_to_file', 'replace_file_content', 'multi_replace_file_content'):
        target = args.get('TargetFile') or args.get('path') or ''
        decision, reason = classify_file_modification(target, workspace_paths, cwd)
    elif tool_name in ('view_file', 'grep_search', 'find_by_name'):
        target = args.get('AbsolutePath') or args.get('SearchPath') or args.get('SearchDirectory') or args.get('TargetFile') or ''
        decision, reason = classify_file_read(target, cwd)
    else:
        # Unknown or unspecified tools require confirmation
        decision, reason = 'ask', f"Tool {tool_name} requires confirmation"

    print(json.dumps({'decision': decision, 'reason': reason}))


if __name__ == '__main__':
    main()
