#!/usr/bin/env python3
"""Antigravity Permission Classifier (PreToolUse Hook).

Evaluates proposed tool calls (shell commands and file writes) before execution
in Antigravity (agy). Mirrors the safety and auto-approval behavior of Claude
Code's `--permission-mode auto` and Codex's execution policies:

- Auto-approves safe read-only inspection, testing, linting, and standard dev commands.
- Hard-blocks dangerous/destructive operations, privilege escalation, and credential theft.
- Prompts for confirmation ('ask') on state-changing, dependency, network, or unfamiliar commands.

Contract:
- Input on stdin: JSON object with toolCall ({name, args}), workspacePaths, etc.
- Output on stdout: JSON object {"decision": "allow" | "deny" | "ask" | "force_ask", "reason": "..."}
- Always exits 0 to prevent wedging the agent loop on unhandled exceptions.
"""

import json
import os
from pathlib import Path
import re
import shlex
import sys

# Commands that are strictly read-only and safe to auto-approve
SAFE_INSPECTION_COMMANDS = {
    'ls', 'dir', 'vdir', 'pwd', 'echo', 'printf',
    'cat', 'head', 'tail', 'less', 'more', 'wc',
    'grep', 'egrep', 'fgrep', 'rg', 'ag',
    'find', 'fd', 'tree', 'file', 'stat', 'diff', 'cmp',
    'which', 'whereis', 'type', 'command',
    'date', 'uptime', 'whoami', 'id', 'uname',
    'true', 'false', 'test', '[',
    'sort', 'uniq', 'cut', 'column', 'jq', 'awk', 'sed',
}

# Safe git subcommands that only inspect state
SAFE_GIT_READ_SUBCOMMANDS = {
    'status', 'diff', 'log', 'show', 'branch', 'rev-parse',
    'rev-list', 'check-ref-format', 'ls-files', 'remote',
    'describe', 'cat-file', 'tag', 'shortlog', 'blame',
    'version',
}

# Safe git subcommands that modify local stage/working copy safely
SAFE_GIT_WORKFLOW_SUBCOMMANDS = {
    'add', 'commit', 'switch', 'stash', 'worktree', 'fetch',
}

# Subcommands / script prefixes for package managers that are safe to run
SAFE_RUN_PREFIXES = ('test', 'lint', 'check', 'typecheck', 'build', 'format', 'compile', 'verify', 'doc')

# Sensitive paths and prefixes that should never be read or written by arbitrary tools
SENSITIVE_PREFIXES = (
    '/etc', '/boot', '/sys', '/proc', '/dev', '/usr/bin', '/bin', '/sbin',
    os.path.expanduser('~/.ssh'),
    os.path.expanduser('~/.aws'),
    os.path.expanduser('~/.gnupg'),
    os.path.expanduser('~/.netrc'),
)

SENSITIVE_FILENAMES = {
    'antigravity-oauth-token',
    'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa',
    '.bashrc', '.bash_profile', '.zshrc', '.profile',
    'hosts.yml',
}


def is_sensitive_path(path_str):
    """Check if a path points to sensitive credentials, keys, or system directories."""
    if not path_str:
        return False
    try:
        norm = os.path.abspath(os.path.expanduser(path_str))
        for prefix in SENSITIVE_PREFIXES:
            if norm == prefix or norm.startswith(prefix + os.sep):
                return True
        if os.path.basename(norm) in SENSITIVE_FILENAMES:
            return True
        # Check token / credential patterns
        if re.search(r'(^|/)\.env(\..+)?$', norm):
            return True
    except Exception:
        return True
    return False


def is_path_in_workspaces(target_path, workspace_paths):
    """Check if target_path resides within one of the declared workspace directories."""
    if not target_path:
        return False
    try:
        norm_target = os.path.abspath(os.path.expanduser(target_path))
        effective_workspaces = workspace_paths or [os.getcwd()]
        for ws in effective_workspaces:
            norm_ws = os.path.abspath(os.path.expanduser(ws))
            if norm_target == norm_ws or norm_target.startswith(norm_ws + os.sep):
                return True
    except Exception:
        return False
    return False


def tokenize_command(cmd_str):
    """Tokenize a shell command line string safely while preserving quoted strings."""
    try:
        s = shlex.shlex(cmd_str, posix=True, punctuation_chars=True)
        s.whitespace_split = True
        s.commenters = ''
        return list(s)
    except Exception:
        return None


def split_into_subcommands(tokens):
    """Split tokens on command chaining and pipeline operators into subcommands and pipeline links."""
    subcommands = []
    current = []
    pipeline_links = []  # tuple of (subcmd_idx, operator)

    separators = {'&&', '||', ';', '|', '&', '\n'}

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


def classify_subcommand(tokens, workspace_paths):
    """Classify a single atomic subcommand (list of tokens).

    Returns (verdict, reason) where verdict is 'allow', 'deny', or 'ask'.
    """
    if not tokens:
        return 'allow', 'Empty subcommand'

    # Strip leading environment variable assignments (e.g. CI=1 NODE_ENV=test)
    idx = 0
    while idx < len(tokens) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', tokens[idx]):
        idx += 1

    cmd_tokens = tokens[idx:]
    if not cmd_tokens:
        return 'allow', 'Environment assignment'

    raw_cmd = cmd_tokens[0]
    base_cmd = os.path.basename(raw_cmd)
    args = cmd_tokens[1:]

    # 1. Check for redirects writing to sensitive targets
    for i, tok in enumerate(tokens):
        if tok in ('>', '>>', '>&') and i + 1 < len(tokens):
            target = tokens[i + 1]
            if is_sensitive_path(target):
                return 'deny', f"Redirect targeting sensitive path is forbidden: {target}"

    # 2. Check for sensitive files being read or targeted in arguments
    for arg in args:
        if is_sensitive_path(arg):
            # Checking if argument explicitly touches sensitive credentials
            return 'deny', f"Access to sensitive path or key is forbidden: {arg}"

    # 3. Privilege Escalation (Hard Deny)
    if base_cmd in {'sudo', 'su', 'doas', 'pkexec', 'chroot'}:
        return 'deny', f"Privilege escalation command is forbidden: {base_cmd}"

    # 4. Destructive Disk Operations (Hard Deny)
    if base_cmd.startswith('mkfs') or base_cmd in {'fdisk', 'gdisk', 'parted', 'wipefs'}:
        return 'deny', f"Destructive disk partitioning or formatting is forbidden: {base_cmd}"
    if base_cmd == 'dd':
        for arg in args:
            if arg.startswith('of=/dev/'):
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
                t_norm = os.path.abspath(os.path.expanduser(t))
                if t in ('/', '/*', '~', '~/*', '$HOME') or t_norm in ('/', os.path.expanduser('~')):
                    return 'deny', f"Recursive deletion targeting system or home directory is forbidden: rm {t}"
                if not is_path_in_workspaces(t, workspace_paths):
                    return 'deny', f"Recursive deletion outside workspace is forbidden: rm {t}"
        # Non-recursive rm inside workspace is safe
        if all(is_path_in_workspaces(t, workspace_paths) for t in targets):
            return 'allow', f"Safe workspace deletion: {' '.join(cmd_tokens)}"
        return 'ask', f"File deletion requires confirmation: {' '.join(cmd_tokens)}"

    # 7. Git Operations
    if base_cmd == 'git':
        if not args:
            return 'allow', 'git command query'
        git_sub = args[0]

        # Dangerous: force pushes to primary branches
        if git_sub == 'push':
            has_force = any(a in ('--force', '-f', '--force-with-lease') for a in args)
            if has_force:
                protected = {'main', 'master', 'release', 'prod', 'production'}
                target_branches = [a for a in args[1:] if not a.startswith('-') and a != 'origin']
                if not target_branches or any(b in protected for b in target_branches):
                    return 'deny', f"Force push to protected branch is forbidden: {' '.join(cmd_tokens)}"
                return 'ask', f"Force push requires confirmation: {' '.join(cmd_tokens)}"
            return 'ask', f"Git push modifies remote repository: {' '.join(cmd_tokens)}"

        # Dangerous: git clean -fdx
        if git_sub == 'clean' and any('f' in a for a in args if a.startswith('-')):
            return 'ask', f"Git clean removes untracked files: {' '.join(cmd_tokens)}"

        # Dangerous: git reset --hard
        if git_sub == 'reset' and any(a in ('--hard', '-q') for a in args):
            return 'ask', f"Git hard reset alters working tree: {' '.join(cmd_tokens)}"

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

        # Git checkout (safe branch or file checkout, ask on forced)
        if git_sub == 'checkout':
            if any(a in ('-f', '--force') for a in args):
                return 'ask', 'Forced checkout requires confirmation'
            return 'allow', 'Safe git checkout'

        # Git branch creation or deletion (local)
        if git_sub == 'branch':
            return 'allow', 'Safe local branch operation'

    # 8. Inspection Commands
    if base_cmd in SAFE_INSPECTION_COMMANDS:
        return 'allow', f"Safe inspection command: {base_cmd}"

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
            if tool in {'tsc', 'eslint', 'prettier', 'jest', 'vitest', 'playwright', 'standard'}:
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
            if module in {'unittest', 'pytest', 'mypy', 'ruff', 'flake8', 'venv'}:
                return 'allow', f"Safe python module: {module}"
        # Running local check script in workspace
        if args and args[0].endswith(('.py', '.sh')) and is_path_in_workspaces(args[0], workspace_paths):
            return 'allow', f"Safe workspace python script: {args[0]}"

    if base_cmd == 'go':
        if args and args[0] in {'test', 'vet', 'fmt', 'build'}:
            return 'allow', f"Safe Go tool: go {args[0]}"

    if base_cmd == 'make':
        if not args or all(a in {'test', 'check', 'lint', 'build', 'clean', 'all'} for a in args):
            return 'allow', f"Safe make target: {' '.join(args) or 'default'}"

    # 10. Local Repository Health Checks
    if raw_cmd.startswith('./') or raw_cmd.startswith('../'):
        script_name = os.path.basename(raw_cmd)
        if re.match(r'^(check-.*\.sh|git-hygiene\.sh|hygiene-status\.sh|setup\.sh)$', script_name):
            return 'allow', f"Safe local repository health check: {script_name}"

    # 11. Safe Local Directory Operations
    if base_cmd in {'mkdir', 'touch'}:
        targets = [a for a in args if not a.startswith('-')]
        if all(is_path_in_workspaces(t, workspace_paths) for t in targets):
            return 'allow', f"Safe filesystem operation within workspace: {base_cmd}"

    if base_cmd in {'cp', 'mv'}:
        targets = [a for a in args if not a.startswith('-')]
        if all(is_path_in_workspaces(t, workspace_paths) for t in targets):
            return 'allow', f"Safe file move/copy within workspace: {base_cmd}"

    # Fallback to interactive confirmation for unknown or state-changing commands
    return 'ask', f"Command requires confirmation: {' '.join(cmd_tokens)}"


def classify_command_line(cmd_str, workspace_paths):
    """Classify an entire shell command line string (including chains and pipelines)."""
    if not cmd_str or not cmd_str.strip():
        return 'allow', 'Empty command line'

    # Check for unquoted dangerous command substitutions
    if '$(' in cmd_str or '`' in cmd_str:
        # Check if substitution contains dangerous commands
        if re.search(r'(\$\(|`)\s*(sudo|rm|curl|wget|chmod)\b', cmd_str):
            return 'deny', "Command substitution with dangerous command is forbidden"
        # Safe command substitutions commonly used in dev: $(git ...), $(basename ...)
        if not re.search(r'(\$\(|`)\s*(git|basename|dirname|pwd|which|whoami)\b', cmd_str):
            return 'ask', "Command substitution requires confirmation"

    tokens = tokenize_command(cmd_str)
    if tokens is None:
        return 'ask', "Unable to safely parse command tokens"

    subcommands, pipeline_links = split_into_subcommands(tokens)
    if not subcommands:
        return 'allow', 'No subcommands found'

    # Check for network commands piped directly into shells (curl ... | bash)
    for sub_idx, op in pipeline_links:
        if sub_idx + 1 < len(subcommands):
            left_sub = subcommands[sub_idx]
            right_sub = subcommands[sub_idx + 1]

            left_base = os.path.basename(left_sub[0]) if left_sub else ''
            right_base = os.path.basename(right_sub[0]) if right_sub else ''

            if left_base in {'curl', 'wget', 'fetch'} and right_base in {'sh', 'bash', 'zsh', 'python', 'python3', 'node', 'perl', 'ruby'}:
                return 'deny', f"Piping remote download ({left_base}) directly into interpreter ({right_base}) is forbidden"

    # Evaluate each subcommand
    has_ask = False
    ask_reasons = []

    for sub in subcommands:
        verdict, reason = classify_subcommand(sub, workspace_paths)
        if verdict == 'deny':
            # Hard deny takes precedence over everything
            return 'deny', reason
        elif verdict == 'ask':
            has_ask = True
            ask_reasons.append(reason)

    if has_ask:
        return 'ask', '; '.join(ask_reasons)

    return 'allow', 'Safe command auto-approved by classifier'


def classify_file_modification(target_file, workspace_paths):
    """Classify file write or replacement tools."""
    if not target_file:
        return 'ask', 'No target file specified'

    if is_sensitive_path(target_file):
        return 'deny', f"Modifying sensitive path or credentials is forbidden: {target_file}"

    if is_path_in_workspaces(target_file, workspace_paths):
        return 'allow', f"File modification within workspace auto-approved: {os.path.basename(target_file)}"

    return 'ask', f"File modification outside workspace requires approval: {target_file}"


def main():
    try:
        raw_input = sys.stdin.read()
    except Exception:
        raw_input = ''

    if not raw_input.strip():
        # Fallback safe: prompt if input is missing
        print(json.dumps({'decision': 'ask', 'reason': 'Permission classifier: empty input payload'}))
        return

    try:
        data = json.loads(raw_input)
    except Exception as e:
        print(json.dumps({'decision': 'ask', 'reason': f"Permission classifier: payload JSON parse error: {e}"}))
        return

    # Environment overrides
    mode = os.environ.get('ANTIGRAVITY_CLASSIFIER_MODE', '').lower()
    if mode in ('disabled', 'off'):
        print(json.dumps({'decision': 'ask', 'reason': 'Classifier disabled via ANTIGRAVITY_CLASSIFIER_MODE'}))
        return
    if mode in ('allow_all', 'bypass'):
        print(json.dumps({'decision': 'allow', 'reason': 'Bypassed via ANTIGRAVITY_CLASSIFIER_MODE=allow_all'}))
        return
    if os.environ.get('ANTIGRAVITY_GATE') == '1':
        print(json.dumps({'decision': 'allow', 'reason': 'Antigravity review gate run'}))
        return

    tool_call = data.get('toolCall') or {}
    tool_name = tool_call.get('name') or data.get('toolName') or ''
    args = tool_call.get('args') or {}
    workspace_paths = data.get('workspacePaths') or []

    if tool_name == 'run_command':
        cmd = args.get('CommandLine') or args.get('command') or ''
        decision, reason = classify_command_line(cmd, workspace_paths)
    elif tool_name in ('write_to_file', 'replace_file_content'):
        target = args.get('TargetFile') or args.get('path') or ''
        decision, reason = classify_file_modification(target, workspace_paths)
    else:
        # Non-modifying tools (view_file, list_dir, grep_search, etc.) are safe
        decision, reason = 'allow', f"Tool {tool_name} auto-approved"

    print(json.dumps({'decision': decision, 'reason': reason}))


if __name__ == '__main__':
    main()
