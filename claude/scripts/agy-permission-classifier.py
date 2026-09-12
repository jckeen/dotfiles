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

import fnmatch
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

# Commands that are strictly read-only inspection and safe to auto-approve without options that execute code or write
SAFE_INSPECTION_COMMANDS = {
    'ls', 'dir', 'vdir', 'pwd', 'echo', 'printf',
    'cat', 'head', 'tail', 'less', 'more', 'wc',
    'file', 'stat', 'cmp',
    'which', 'whereis', 'type',
    'date', 'uptime', 'whoami', 'id', 'uname',
    'true', 'false', 'test', '[',
    'uniq', 'cut', 'column', 'jq',
}

# Standard directories containing system binaries
SYSTEM_BIN_DIRS = {'/bin', '/usr/bin', '/usr/local/bin', '/sbin', '/usr/sbin'}

# Safe git subcommands that only inspect state without options
SAFE_GIT_READ_SUBCOMMANDS = {
    'status', 'log', 'show', 'rev-parse',
    'rev-list', 'check-ref-format', 'ls-files',
    'describe', 'cat-file', 'shortlog', 'blame',
    'version',
}

# Subcommands / script prefixes for package managers that are safe to run
SAFE_RUN_PREFIXES = ('test', 'lint', 'check', 'typecheck', 'build', 'format', 'compile', 'verify', 'doc')

def get_sensitive_credential_prefixes():
    """Dynamically resolve sensitive credential prefixes against current HOME."""
    home = os.path.expanduser('~')
    return (
        os.path.join(home, '.ssh'),
        os.path.join(home, '.aws'),
        os.path.join(home, '.gnupg'),
        os.path.join(home, '.netrc'),
        os.path.join(home, '.codex'),
        os.path.join(home, '.claude'),
        os.path.join(home, '.gemini', 'antigravity-cli'),
        '/etc/shadow',
        '/etc/sudoers',
    )

SENSITIVE_FILENAMES = {
    'antigravity-oauth-token',
    'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa',
    '.bashrc', '.bash_profile', '.zshrc', '.profile',
    'hosts.yml',
}

# Glob patterns that match sensitive files
SENSITIVE_PATTERNS = (
    '.env*', 'id_*', '*.pem', '*.key', 'antigravity-oauth-token',
    '*shadow*', '*sudoers*', 'hosts.yml',
)

# System directories that should never be modified/written to
SYSTEM_WRITE_PREFIXES = (
    '/etc', '/boot', '/sys', '/proc', '/dev', '/usr', '/bin', '/sbin', '/var', '/lib',
)

# Dangerous environment variables that alter binary loading, paths, or runtime execution
DANGEROUS_ENV_PREFIXES = (
    'LD_', 'DYLD_', 'GIT_', 'BASH_',
)
DANGEROUS_ENV_VARS = {
    'PATH', 'ENV', 'IFS', 'SHELL', 'SHLVL',
    'NODE_OPTIONS', 'NODE_PATH',
    'PYTHONPATH', 'PYTHONSTARTUP', 'PYTHONHOME', 'PYTHONEXECUTABLE',
    'PERL5OPT', 'PERL5LIB', 'PERLLIB',
    'RUBYOPT', 'RUBYLIB',
}

PROTECTED_BRANCHES = {'main', 'master', 'release', 'prod', 'production'}

# Redirection operators (ordered by descending length for greedy matching)
REDIRECTION_OPERATORS = ('&>>', '>|', '&>', '>>', '>&', '>', '<>', '<')


def is_dangerous_env_var(var_name):
    if var_name in DANGEROUS_ENV_VARS:
        return True
    return any(var_name.startswith(p) for p in DANGEROUS_ENV_PREFIXES)


def expand_path(p_str, cwd=None):
    """Safely expand user, variables, and relative paths against cwd."""
    if not p_str or not isinstance(p_str, str):
        return ''
    expanded = os.path.expanduser(os.path.expandvars(p_str))
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    if not os.path.isabs(expanded):
        expanded = os.path.join(effective_cwd, expanded)
    try:
        return str(Path(expanded).resolve())
    except Exception:
        return os.path.abspath(expanded)


def matches_sensitive_pattern(filename):
    """Check if a filename or glob pattern matches sensitive credential patterns."""
    if not filename or not isinstance(filename, str):
        return False
    basename = os.path.basename(filename)
    if basename in SENSITIVE_FILENAMES:
        return True
    for pat in SENSITIVE_PATTERNS:
        if fnmatch.fnmatch(basename, pat):
            return True
    return False


def expand_braces(text):
    """Expand simple shell brace expressions like ~/{.aws,.ssh}/credentials."""
    m = re.search(r'\{([^{}]+)\}', text)
    if not m:
        return [text]
    prefix = text[:m.start()]
    suffix = text[m.end():]
    options = m.group(1).split(',')
    results = []
    for opt in options:
        results.extend(expand_braces(prefix + opt + suffix))
    return results


def is_sensitive_credential_path(path_str, cwd=None):
    """Check if a path targets credentials, private keys, or tokens (including globs and braces)."""
    if not path_str or not isinstance(path_str, str):
        return False
    if path_str == '/dev/null':
        return False

    # Check for brace expansion like ~/{.aws,.ssh}/credentials
    if '{' in path_str and '}' in path_str:
        for exp in expand_braces(path_str):
            if is_sensitive_credential_path(exp, cwd):
                return True

    # Check for glob/bracket tricks like .en[v] or ~/.s[s]h/id_*
    clean = re.sub(r'\[(.)\]', r'\1', path_str)
    if matches_sensitive_pattern(clean) or matches_sensitive_pattern(path_str):
        return True

    norm = expand_path(clean, cwd)
    if matches_sensitive_pattern(os.path.basename(norm)) or matches_sensitive_pattern(norm):
        return True

    # Check for process environment reads (/proc/*/environ, /proc/self/environ, etc.)
    norm_proc = norm.replace('\\', '/')
    clean_proc = clean.replace('\\', '/')
    if (norm_proc.startswith('/proc/') and ('/environ' in norm_proc or os.path.basename(norm_proc) == 'environ')) or \
       (clean_proc.startswith('/proc/') and ('/environ' in clean_proc or os.path.basename(clean_proc) == 'environ')):
        return True
    try:
        resolved = str(Path(norm).resolve()).replace('\\', '/')
        if resolved.startswith('/proc/') and ('/environ' in resolved or os.path.basename(resolved) == 'environ'):
            return True
    except Exception:
        pass
    for prefix in get_sensitive_credential_prefixes():
        prefixes_to_check = {os.path.abspath(prefix)}
        if os.path.exists(prefix):
            try:
                prefixes_to_check.add(str(Path(prefix).resolve()))
            except Exception:
                pass
        for norm_prefix in prefixes_to_check:
            # Direct exact or prefix match
            if norm == norm_prefix or norm.startswith(norm_prefix + os.sep):
                return True
            # Wildcard pattern match (e.g. ~/.a?s/credentials or ~/.s*h/id_rsa or /home/*/.ssh)
            if any(c in norm for c in ('*', '?', '[')):
                if fnmatch.fnmatch(norm_prefix, norm) or fnmatch.fnmatch(norm, norm_prefix):
                    return True
                norm_parts = norm.strip(os.sep).split(os.sep)
                prefix_parts = norm_prefix.strip(os.sep).split(os.sep)
                if len(norm_parts) >= len(prefix_parts):
                    if all(fnmatch.fnmatch(p_part, n_part) or fnmatch.fnmatch(n_part, p_part)
                           for p_part, n_part in zip(prefix_parts, norm_parts[:len(prefix_parts)])):
                        return True
    return False


def is_system_write_path(path_str, cwd=None):
    """Check if path targets system directories for writing."""
    if not path_str or not isinstance(path_str, str):
        return False
    if path_str == '/dev/null':
        return False
    clean = re.sub(r'\[(.)\]', r'\1', path_str)
    norm = expand_path(clean, cwd)
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
    if not workspace_paths:
        return False
    # If target has unexpanded shell variables, brace expansions, command substitutions, or wildcards
    if any(c in target_path for c in ('$', '{', '}', '`', '*', '?', '[', ']')):
        return False
    try:
        norm_target = expand_path(target_path, cwd)
        for ws in workspace_paths:
            if not ws or not isinstance(ws, str):
                continue
            norm_ws = expand_path(ws, cwd)
            if norm_target == norm_ws or norm_target.startswith(norm_ws + os.sep):
                return True
    except Exception:
        return False
    return False


def check_directory_descendants(target_dir, cwd=None):
    """Inspect directory for sensitive descendant files or sensitive symlinks.

    Returns (verdict, reason) where verdict is 'deny', 'ask', or 'allow'.
    """
    if not target_dir or not isinstance(target_dir, str):
        return 'allow', 'Not a directory'
    norm = expand_path(target_dir, cwd)
    if not os.path.isdir(norm):
        return 'allow', 'Not a directory'

    try:
        for root, dirs, files in os.walk(norm):
            # Prune VCS and dependency caches
            if '.git' in dirs:
                dirs.remove('.git')
            if 'node_modules' in dirs:
                dirs.remove('node_modules')

            # Check symlinked subdirectories
            for d in list(dirs):
                d_full = os.path.join(root, d)
                if os.path.islink(d_full):
                    try:
                        link_target = str(Path(d_full).resolve())
                        if is_sensitive_credential_path(link_target, cwd):
                            return 'deny', f"contains symlink to sensitive directory ({d} -> {link_target})"
                    except Exception:
                        pass

            # Pass 1: check symlinked files for sensitive targets (hard deny)
            for f in files:
                f_full = os.path.join(root, f)
                if os.path.islink(f_full):
                    try:
                        link_target = str(Path(f_full).resolve())
                        if matches_sensitive_pattern(os.path.basename(link_target)) or is_sensitive_credential_path(link_target, cwd):
                            return 'deny', f"contains symlink to sensitive file ({f} -> {link_target})"
                    except Exception:
                        pass

            # Pass 2: check files for sensitive patterns (ask)
            for f in files:
                if matches_sensitive_pattern(f):
                    return 'ask', f"contains sensitive descendant file ({f})"
    except Exception:
        pass

    return 'allow', 'Directory clean'


def git_has_external_diff_configured(cwd=None):
    """Check if git has an external diff or textconv driver configured that executes programs."""
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    try:
        res = subprocess.run(
            ['git', 'config', '--get-regexp', r'^diff\.(external|.*\.command|.*\.textconv)$'],
            cwd=effective_cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=1,
        )
        if res.returncode == 0 and res.stdout.strip():
            return True
    except Exception:
        pass
    return False


def git_has_fsmonitor_configured(cwd=None):
    """Check if git has a core.fsmonitor hook configured that executes programs."""
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    try:
        res = subprocess.run(
            ['git', 'config', '--get', 'core.fsmonitor'],
            cwd=effective_cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=1,
        )
        if res.returncode == 0 and res.stdout.strip():
            val = res.stdout.strip().lower()
            if val not in ('false', '0', 'no', 'off'):
                return True
    except Exception:
        pass
    return False


def is_git_admin_path(path_str, cwd=None):
    """Check if path targets git internal administrative files (.git, .git/config, .git/hooks, bare repo .git, etc.)."""
    if not path_str or not isinstance(path_str, str):
        return False
    norm = expand_path(path_str, cwd)
    parts = norm.split(os.sep)
    for p in parts:
        if p == '.git' or p.endswith('.git'):
            return True
    try:
        resolved = str(Path(norm).resolve())
        res_parts = resolved.split(os.sep)
        for p in res_parts:
            if p == '.git' or p.endswith('.git'):
                return True
    except Exception:
        pass
    return False


def tokenize_command_line(line):
    """Tokenize a single shell command line without stripping comments prematurely."""
    try:
        s = shlex.shlex(line, posix=True, punctuation_chars=True)
        s.whitespace_split = True
        s.commenters = ''
        raw_tokens = list(s)
        refined = []
        for tok in raw_tokens:
            # Only split pure punctuation tokens (e.g. ;> or ;>> or ;|)
            # Quoted strings like 'README;echo' or word tokens must never be split
            if len(tok) > 1 and ';' in tok and all(c in '();<>|&' for c in tok):
                parts = re.split(r'(;+)', tok)
                refined.extend(p for p in parts if p)
            else:
                refined.append(tok)
        return refined
    except Exception:
        return None


def split_into_subcommands(tokens):
    """Split tokens on command chaining and pipeline operators."""
    subcommands = []
    current = []
    pipeline_links = []

    separators = {'&&', '||', ';', '|&', '|', '&'}

    i = 0
    while i < len(tokens):
        tok = tokens[i]
        # Check two-character operator |&
        if tok == '|' and i + 1 < len(tokens) and tokens[i + 1] == '&':
            if current:
                subcommands.append(current)
                pipeline_links.append((len(subcommands) - 1, '|&'))
                current = []
            i += 2
            continue

        if tok in separators:
            if current:
                subcommands.append(current)
                if tok in ('|', '|&'):
                    pipeline_links.append((len(subcommands) - 1, tok))
                current = []
        else:
            current.append(tok)
        i += 1

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
        if is_dangerous_env_var(var_name):
            return 'deny', f"Setting execution-altering environment variable is forbidden: {var_name}"
        idx += 1

    cmd_tokens = tokens[idx:]
    if not cmd_tokens:
        return 'allow', 'Environment assignment'

    raw_cmd = cmd_tokens[0]
    args = cmd_tokens[1:]

    # Check for redirection operators and their destination targets
    for i, tok in enumerate(tokens):
        if tok in REDIRECTION_OPERATORS and i + 1 < len(tokens):
            target = tokens[i + 1]
            if target == '/dev/null':
                continue
            # Network pseudo-devices in bash /dev/tcp/... or /dev/udp/...
            if target.startswith(('/dev/tcp/', '/dev/udp/')):
                return 'ask', f"Network communication via redirection requires confirmation: {target}"
            # If target has unexpanded variable or glob, we cannot verify containment safely
            if '$' in target or '*' in target or '?' in target:
                return 'ask', f"Redirection with unexpanded variable or glob requires approval: {target}"
            if is_sensitive_credential_path(target, cwd):
                return 'deny', f"Redirect targeting sensitive path is forbidden: {target}"
            if tok != '<':
                if is_system_write_path(target, cwd):
                    return 'deny', f"Redirect targeting system write path is forbidden: {target}"
                if is_git_admin_path(target, cwd):
                    return 'ask', f"Redirect modifying git repository configuration or hooks requires confirmation: {target}"
                if not is_path_in_workspaces(target, workspace_paths, cwd):
                    return 'ask', f"Redirecting output outside workspace requires approval: {target}"

    # Resolve executable: prevent ./malicious/ls or workspace PATH overrides
    if '/' in raw_cmd:
        resolved_exe = expand_path(raw_cmd, cwd)
        exe_dir = os.path.dirname(resolved_exe)
        if exe_dir not in SYSTEM_BIN_DIRS:
            return 'ask', f"Running non-system executable requires confirmation: {raw_cmd}"
        base_cmd = os.path.basename(resolved_exe)
    else:
        resolved_path = shutil.which(raw_cmd)
        if resolved_path:
            resolved_norm = expand_path(resolved_path, cwd)
            if is_path_in_workspaces(resolved_norm, workspace_paths, cwd):
                return 'ask', f"Running workspace-controlled executable requires confirmation: {raw_cmd} ({resolved_path})"
        base_cmd = raw_cmd

    # Check for sensitive files being targeted in arguments
    # Skip known text payloads (e.g. git commit messages, echo strings, grep search patterns)
    skip_next = False
    for i, arg in enumerate(args):
        if skip_next:
            skip_next = False
            continue
        # For git commit/tag, skip the commit message string operand
        if base_cmd == 'git' and len(args) > 0 and args[0] in {'commit', 'tag'}:
            if arg in ('-m', '--message'):
                skip_next = True
                continue
            if arg.startswith(('-m', '--message=')):
                continue
        # For echo / printf, positional text operands are output payloads
        if base_cmd in {'echo', 'printf'}:
            continue
        # For grep / rg / ag, skip the search pattern operand
        if base_cmd in {'grep', 'egrep', 'fgrep', 'rg', 'ag'}:
            has_pat_flag = any(a in ('-e', '-f') or a.startswith(('-e', '-f')) for a in args)
            positionals = [a for a in args if not a.startswith('-')]
            if not has_pat_flag and positionals and arg == positionals[0]:
                continue
        val = arg.split('=', 1)[1] if arg.startswith('--') and '=' in arg else arg
        if val != '/dev/null' and is_sensitive_credential_path(val, cwd):
            return 'deny', f"Access to sensitive credential or key is forbidden: {arg}"
        if arg.startswith(('-o', '-t')) and len(arg) > 2 and not arg.startswith('--'):
            sub_val = arg[2:].lstrip('=')
            if sub_val != '/dev/null' and is_sensitive_credential_path(sub_val, cwd):
                return 'deny', f"Access to sensitive credential or key is forbidden: {arg}"

    # 1. Privilege Escalation (Hard Deny)
    if base_cmd in {'sudo', 'su', 'doas', 'pkexec', 'chroot'}:
        return 'deny', f"Privilege escalation command is forbidden: {base_cmd}"

    # 2. Destructive Disk Operations (Hard Deny)
    if base_cmd.startswith('mkfs') or base_cmd in {'fdisk', 'gdisk', 'parted', 'wipefs'}:
        return 'deny', f"Destructive disk partitioning or formatting is forbidden: {base_cmd}"
    if base_cmd == 'dd':
        for arg in args:
            if arg.startswith('of=/dev/') and arg != 'of=/dev/null':
                return 'deny', f"Direct device overwrite with dd is forbidden: {arg}"

    # 3. Reverse Shells & Network Exfiltration (Hard Deny)
    if base_cmd in {'nc', 'ncat', 'socat'}:
        if any(a in ('-e', '-c', 'exec') for a in args):
            return 'deny', f"Reverse shell execution is forbidden: {base_cmd}"

    # 4. Destructive Deletions (rm)
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
        if targets and all(is_path_in_workspaces(t, workspace_paths, cwd) and not is_sensitive_credential_path(t, cwd) and not is_git_admin_path(t, cwd) for t in targets):
            return 'allow', f"Safe workspace file deletion: {' '.join(cmd_tokens)}"
        return 'ask', f"File deletion requires confirmation: {' '.join(cmd_tokens)}"

    # 5. Git Operations
    if base_cmd == 'git':
        if not args:
            return 'allow', 'git command query'
        git_sub = args[0]

        # Check for git output options across all git commands
        git_out = None
        for i, a in enumerate(args):
            if a in ('--output', '-o', '--output-directory') and i + 1 < len(args):
                git_out = args[i + 1]
            elif a.startswith(('--output=', '--output-directory=')):
                git_out = a.split('=', 1)[1]
            elif a.startswith('-o') and len(a) > 2 and not a.startswith('--'):
                git_out = a[2:].lstrip('=')
        if git_out:
            if is_sensitive_credential_path(git_out, cwd) or is_system_write_path(git_out, cwd):
                return 'deny', f"git {git_sub} --output targeting sensitive or system path is forbidden: {git_out}"
            if is_git_admin_path(git_out, cwd):
                return 'ask', f"git {git_sub} --output targeting git administrative file requires confirmation: {git_out}"
            if not is_path_in_workspaces(git_out, workspace_paths, cwd):
                return 'ask', f"git {git_sub} --output outside workspace requires approval: {git_out}"

        # External diff/textconv drivers can execute arbitrary commands configured in gitconfig/attributes
        for a in args:
            if a in ('--ext-diff', '--textconv') or a.startswith(('--ext-diff=', '--textconv=')):
                return 'ask', f"Git command with external diff/filter driver requires confirmation: {' '.join(cmd_tokens)}"

        # Check git arguments for <rev>:<path> expressions targeting sensitive files
        for a in args:
            if not a.startswith('-') and ':' in a and not a.startswith(('http:', 'https:', 'ssh:', 'git:')):
                git_path = a.split(':', 1)[1]
                if git_path and (matches_sensitive_pattern(git_path) or is_sensitive_credential_path(git_path, cwd)):
                    return 'deny', f"Git command targeting sensitive object path is forbidden: {a}"

        # Force push or direct push to protected branch detection
        if git_sub == 'push':
            has_force = any(a in ('--force', '-f', '--force-with-lease') or a.startswith('+') for a in args)
            refspecs = [a for a in args[1:] if not a.startswith('-') and a != 'origin']
            for spec in refspecs:
                dest = parse_refspec_dest(spec)
                if dest in PROTECTED_BRANCHES:
                    return 'deny', f"Push targeting protected branch '{dest}' is forbidden: {' '.join(cmd_tokens)}"
            if has_force:
                if not refspecs:
                    return 'deny', f"Unscoped force push is forbidden: {' '.join(cmd_tokens)}"
                return 'ask', f"Force push requires confirmation: {' '.join(cmd_tokens)}"
            return 'ask', f"Git push modifies remote repository: {' '.join(cmd_tokens)}"

        # Fetch with refspecs: can overwrite local branch references
        if git_sub == 'fetch':
            refspecs = [a for a in args[1:] if not a.startswith('-') and a != 'origin']
            if refspecs or any(a.startswith('+') for a in args):
                return 'ask', f"Git fetch with refspecs requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git fetch'

        # Destructive or state-discarding git commands
        if git_sub in {'clean', 'reset', 'restore'}:
            return 'ask', f"Git {git_sub} alters working tree: {' '.join(cmd_tokens)}"

        # Git checkout: disallow file checkouts (which discard changes) and forced checkouts
        if git_sub == 'checkout':
            return 'ask', f"Git checkout requires confirmation: {' '.join(cmd_tokens)}"

        # Git switch: only allow without discarding changes or creating/resetting branches
        if git_sub == 'switch':
            if any(a.startswith(('-c', '-C', '-f', '--create', '--force-create', '--force', '--discard-changes')) for a in args):
                return 'ask', f"Switching with branch creation, reset, or discard requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git switch'

        # Git branch: only allow read-only queries
        if git_sub == 'branch':
            MUTATING_BRANCH_FLAGS = (
                '-d', '-D', '-m', '-M', '-c', '-C', '-f', '--force',
                '--delete', '--move', '--copy', '--set-upstream-to',
                '-u', '--unset-upstream', '--edit-description',
            )
            for a in args[1:]:
                if a in MUTATING_BRANCH_FLAGS:
                    return 'ask', f"Mutating branches requires confirmation: {' '.join(cmd_tokens)}"
                if any(a.startswith(opt + '=') for opt in MUTATING_BRANCH_FLAGS if opt.startswith('--')):
                    return 'ask', f"Mutating branches requires confirmation: {' '.join(cmd_tokens)}"
                if any(a.startswith(opt) for opt in MUTATING_BRANCH_FLAGS if not opt.startswith('--')):
                    return 'ask', f"Mutating branches requires confirmation: {' '.join(cmd_tokens)}"
            positionals = [a for a in args[1:] if not a.startswith('-')]
            # Positional arguments in git branch create/reset branches unless --list is explicitly used
            # Note: -l means --create-reflog when creating a branch, so only --list is safe with positionals
            if positionals and not any(a == '--list' or a.startswith('--list=') for a in args):
                return 'ask', f"Branch creation or modification requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git branch query'

        # Git tag: only allow listing
        if git_sub == 'tag':
            if any(a in ('-d', '--delete', '-a', '-f', '--force', '-m', '-s', '-u') for a in args):
                return 'ask', f"Creating or deleting tags requires confirmation: {' '.join(cmd_tokens)}"
            positionals = [a for a in args[1:] if not a.startswith('-')]
            if positionals and not any(a in ('-l', '--list') for a in args):
                return 'ask', f"Creating tags requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git tag query'

        # Git remote: only allow read queries
        if git_sub == 'remote':
            if any(a in ('add', 'rename', 'remove', 'rm', 'set-head', 'set-branches', 'set-url', 'update', 'prune') for a in args):
                return 'ask', f"Mutating git remotes requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git remote query'

        # Git commands that inspect or refresh the index/working tree execute core.fsmonitor if configured
        if git_sub in {'status', 'diff', 'ls-files', 'stash', 'add', 'commit', 'checkout', 'restore', 'reset', 'worktree', 'describe'}:
            has_no_fsmonitor = any(a == '--no-optional-locks' for a in args)
            if not has_no_fsmonitor and git_has_fsmonitor_configured(cwd):
                return 'ask', f"git {git_sub} with configured core.fsmonitor hook requires confirmation: {' '.join(cmd_tokens)}"

        # Git diff
        if git_sub == 'diff':
            has_no_ext = any(a == '--no-ext-diff' for a in args)
            has_no_textconv = any(a == '--no-textconv' for a in args)
            if (not has_no_ext or not has_no_textconv) and git_has_external_diff_configured(cwd):
                return 'ask', f"git diff with configured external diff/textconv driver requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git diff'

        if git_sub == 'stash':
            # Only strictly read-only queries are auto-approved
            if len(args) > 1:
                stash_sub = args[1]
                if stash_sub == 'list':
                    return 'allow', 'Safe git stash list'
                if stash_sub == 'show':
                    has_no_ext = any(a == '--no-ext-diff' for a in args)
                    has_no_textconv = any(a == '--no-textconv' for a in args)
                    if (not has_no_ext or not has_no_textconv) and git_has_external_diff_configured(cwd):
                        return 'ask', f"git stash show with configured external diff/textconv driver requires confirmation: {' '.join(cmd_tokens)}"
                    return 'allow', 'Safe git stash show'
            return 'ask', f"Git stash modification requires confirmation: {' '.join(cmd_tokens)}"

        if git_sub == 'worktree':
            if any(a in ('add', 'remove', 'prune', 'lock', 'unlock', 'move', 'repair') for a in args):
                if 'add' in args:
                    if any(a in ('-B', '-f', '--force') or a.startswith(('-B', '-f', '--force')) for a in args):
                        return 'ask', f"git worktree add with branch reset or force requires confirmation: {' '.join(cmd_tokens)}"
                    sub_args = args[args.index('add') + 1:]
                    dir_operands = []
                    skip_next = False
                    for a in sub_args:
                        if skip_next:
                            skip_next = False
                            continue
                        if a in ('-b', '-B', '--reason'):
                            skip_next = True
                            continue
                        if a.startswith(('-b', '-B', '--reason=')):
                            continue
                        if not a.startswith('-'):
                            dir_operands.append(a)
                    if dir_operands:
                        target_dir = dir_operands[0]
                        if not is_path_in_workspaces(target_dir, workspace_paths, cwd) or is_system_write_path(target_dir, cwd):
                            return 'ask', f"git worktree add outside workspace requires approval: {target_dir}"
                    return 'allow', 'Safe git worktree add within workspace'
                return 'ask', f"Git worktree modification requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git worktree query'

        # Git show, log, blame, etc. run configured textconv drivers by default
        if git_sub in {'show', 'log', 'blame', 'whatchanged', 'format-patch'}:
            has_no_textconv = any(a == '--no-textconv' for a in args)
            if not has_no_textconv and git_has_external_diff_configured(cwd):
                return 'ask', f"git {git_sub} with configured external diff/textconv driver requires confirmation: {' '.join(cmd_tokens)}"


        if git_sub in SAFE_GIT_READ_SUBCOMMANDS:
            return 'allow', f"Safe git read query: git {git_sub}"

        if git_sub == 'config':
            if any(a in ('--get', '--get-all', '--list', '-l') for a in args):
                return 'allow', 'Safe git config query'
            return 'ask', 'Git config modification requires confirmation'

        if git_sub == 'add':
            return 'allow', 'Safe git add'

        if git_sub == 'commit':
            if any(a in ('--amend', '--fixup', '--squash', '--reset-author') or a.startswith(('--amend', '--fixup=', '--squash=')) for a in args):
                return 'ask', f"git commit with history rewriting requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git commit'

    # 6. Inspection Commands
    if base_cmd in SAFE_INSPECTION_COMMANDS:
        # File inspection commands must prompt if args contain variable, command substitutions, or wildcards
        if base_cmd in {'cat', 'head', 'tail', 'less', 'more', 'wc', 'file', 'stat', 'cmp', 'uniq', 'cut', 'column', 'jq'}:
            for a in args:
                if not a.startswith('-') and any(c in a for c in ('$', '`', '*', '?', '[', ']')):
                    return 'ask', f"Inspection command with wildcard, variable, or substitution requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'less':
            if any(a.startswith('+') or a in ('-o', '-O', '--log-file', '--LOG-FILE', '-T', '--tag-file') or a.startswith(('-o', '-O', '--log-file=', '--LOG-FILE=', '-T', '--tag-file=')) for a in args):
                return 'ask', f"less with command execution (+), log file, or tag file option requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'date':
            if any(a in ('-s', '--set') or a.startswith(('-s', '--set=')) for a in args):
                return 'ask', f"date with system clock setting requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'printf':
            if any(a == '-v' or a.startswith('-v') for a in args):
                var_name = None
                for i, a in enumerate(args):
                    if a == '-v' and i + 1 < len(args):
                        var_name = args[i + 1]
                        break
                    elif a.startswith('-v') and len(a) > 2:
                        var_name = a[2:]
                        break
                if var_name and is_dangerous_env_var(var_name):
                    return 'deny', f"Setting execution-altering environment variable via printf is forbidden: {var_name}"
                return 'ask', f"printf with variable assignment (-v) requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'uniq':
            positionals = [a for a in args if not a.startswith('-')]
            if len(positionals) > 1:
                return 'ask', f"uniq with output file operand requires confirmation: {' '.join(cmd_tokens)}"
        return 'allow', f"Safe inspection command: {base_cmd}"

    # Ripgrep: safe unless using --pre which runs external programs, searching hidden/symlink, or searching sensitive paths
    if base_cmd in {'rg', 'ag'}:
        if any(a.startswith('--pre') for a in args):
            return 'ask', f"rg with --pre option requires confirmation: {' '.join(cmd_tokens)}"
        # Check for unexpanded variables
        for a in args:
            if not a.startswith('-') and ('$' in a or '`' in a):
                return 'ask', f"rg with unexpanded variable requires confirmation: {' '.join(cmd_tokens)}"
        # Check for hidden files, un-ignoring, or symlink following (including bundled short flags like -iL, -Lu)
        if any(a.startswith(('--hidden', '--no-ignore', '--follow')) or (a.startswith('-') and not a.startswith('--') and any(c in a for c in ('L', 'u'))) for a in args):
            return 'ask', f"rg with hidden files or symlink following requires confirmation: {' '.join(cmd_tokens)}"
        positionals = [a for a in args if not a.startswith('-')]
        has_pattern_flag = any(a == '-e' or a.startswith('-e') for a in args)
        search_paths = positionals if has_pattern_flag else positionals[1:]
        if not search_paths:
            search_paths = [cwd]
        for p in search_paths:
            if is_sensitive_credential_path(p, cwd):
                return 'deny', f"Searching sensitive credential path is forbidden: {p}"
            p_norm = expand_path(p, cwd)
            p_dir = p_norm if p_norm.endswith(os.sep) else p_norm + os.sep
            for prefix in get_sensitive_credential_prefixes():
                prefix_norm = str(Path(prefix).resolve()) if os.path.exists(prefix) else os.path.abspath(prefix)
                if prefix_norm == p_norm or prefix_norm.startswith(p_dir):
                    return 'deny', f"Recursive search over path containing sensitive credentials is forbidden: {p}"
            if not is_path_in_workspaces(p, workspace_paths, cwd):
                return 'ask', f"Searching outside workspace requires confirmation: {p}"
            if os.path.isdir(p_norm):
                desc_verdict, desc_reason = check_directory_descendants(p_norm, cwd)
                if desc_verdict != 'allow':
                    return desc_verdict, f"Directory search {desc_reason}: {p}"
        return 'allow', 'Safe grep query'

    # Grep: safe unless searching sensitive directories or recursive search
    if base_cmd in {'grep', 'egrep', 'fgrep'}:
        # Check for unexpanded variables
        for a in args:
            if not a.startswith('-') and ('$' in a or '`' in a):
                return 'ask', f"grep with unexpanded variable requires confirmation: {' '.join(cmd_tokens)}"
        positionals = [a for a in args if not a.startswith('-')]
        has_pattern_flag = any(a in ('-e', '-f') or a.startswith(('-e', '-f')) for a in args)
        search_paths = positionals if has_pattern_flag else positionals[1:]
        for p in search_paths:
            if is_sensitive_credential_path(p, cwd):
                return 'deny', f"Searching sensitive credential path is forbidden: {p}"
            p_norm = expand_path(p, cwd)
            p_dir = p_norm if p_norm.endswith(os.sep) else p_norm + os.sep
            for prefix in get_sensitive_credential_prefixes():
                prefix_norm = str(Path(prefix).resolve()) if os.path.exists(prefix) else os.path.abspath(prefix)
                if prefix_norm == p_norm or prefix_norm.startswith(p_dir):
                    return 'deny', f"Recursive search over path containing sensitive credentials is forbidden: {p}"

        is_recursive = any(a in ('-r', '-R', '--recursive') or (a.startswith('-') and any(c in a for c in ('r', 'R'))) for a in args)
        if is_recursive:
            return 'ask', f"Recursive grep may expose sensitive workspace files or traverse symlinks: {' '.join(cmd_tokens)}"

        for p in search_paths:
            if not is_path_in_workspaces(p, workspace_paths, cwd):
                return 'ask', f"Searching outside workspace requires confirmation: {p}"
        return 'allow', 'Safe grep query'

    # Sort: check --compress-program, -o / --output option, and unexpanded variables
    if base_cmd == 'sort':
        if any(a == '--compress-program' or a.startswith(('--compress-program=', '--compress-program')) for a in args):
            return 'ask', f"sort with execution helper requires confirmation: {' '.join(cmd_tokens)}"
        for a in args:
            if not a.startswith('-') and any(c in a for c in ('$', '`', '*', '?', '[', ']')):
                return 'ask', f"sort with wildcard, variable, or substitution requires confirmation: {' '.join(cmd_tokens)}"
        out_target = None
        for i, a in enumerate(args):
            if a in ('-o', '--output') and i + 1 < len(args):
                out_target = args[i + 1]
            elif a.startswith('-o') and len(a) > 2:
                out_target = a[2:]
            elif a.startswith('--output='):
                out_target = a.split('=', 1)[1]
        if out_target:
            if is_sensitive_credential_path(out_target, cwd) or is_system_write_path(out_target, cwd):
                return 'deny', f"sort output targeting sensitive or system path is forbidden: {out_target}"
            if is_git_admin_path(out_target, cwd):
                return 'ask', f"sort modifying git repository configuration or hooks requires confirmation: {out_target}"
            if not is_path_in_workspaces(out_target, workspace_paths, cwd):
                return 'ask', f"sort output outside workspace requires approval: {out_target}"
        return 'allow', 'Safe sort command'

    # Find: safe ONLY without destructive, execution, or file writing options
    if base_cmd == 'find':
        for a in args:
            if not a.startswith('-') and ('$' in a or '`' in a):
                return 'ask', f"find with unexpanded variable requires confirmation: {' '.join(cmd_tokens)}"
        if any(a in ('-delete', '-exec', '-execdir', '-ok', '-okdir', '-fls', '-fprint', '-fprint0', '-fprintf') or a.startswith(('-exec', '-ok', '-fls', '-fprint')) for a in args):
            return 'ask', f"find with execution or write options requires confirmation: {' '.join(cmd_tokens)}"
        # Check search root
        for a in args:
            if not a.startswith('-') and is_sensitive_credential_path(a, cwd):
                return 'deny', f"find searching sensitive path is forbidden: {a}"
        return 'allow', 'Safe find command'

    # 7. Test, Lint, and Build Runners
    if base_cmd in {'npm', 'pnpm', 'yarn', 'bun'}:
        if any(a in ('--script-shell', '--shell') or a.startswith(('--script-shell=', '--shell=')) for a in args):
            return 'ask', f"{base_cmd} with custom script shell requires confirmation: {' '.join(cmd_tokens)}"
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

    # npx: only safe when run with --no-install to avoid downloading unverified packages
    if base_cmd == 'npx':
        if args:
            # Reject package overrides or auto-install flags that bypass --no-install
            if any(a in ('-y', '--yes', '-p', '--package') or a.startswith(('-y', '--yes', '-p', '--package=', '--package')) for a in args):
                return 'ask', f"npx with package download or auto-install options requires confirmation: {' '.join(cmd_tokens)}"
            has_no_install = '--no-install' in args
            tools = [a for a in args if not a.startswith('-')]
            if has_no_install and tools:
                tool = tools[0]
                if tool in {'tsc', 'eslint', 'prettier', 'jest', 'vitest'}:
                    return 'allow', f"Safe static tool via npx --no-install: {tool}"
            return 'ask', f"npx execution without --no-install requires confirmation: {' '.join(cmd_tokens)}"
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
        return 'ask', f"Executing Python script requires confirmation: {' '.join(cmd_tokens)}"

    if base_cmd == 'go':
        if args and args[0] in {'test', 'vet', 'fmt', 'build'}:
            if any(a in ('-exec', '--exec') or a.startswith(('-exec=', '--exec=')) for a in args):
                return 'ask', f"go {args[0]} with custom exec program requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', f"Safe Go tool: go {args[0]}"

    if base_cmd == 'make':
        if not args or all(a in {'test', 'check', 'lint', 'build', 'clean', 'all'} for a in args):
            return 'allow', f"Safe make target: {' '.join(args) or 'default'}"

    # 8. Safe Local File Operations (cp / mv)
    if base_cmd in {'cp', 'mv'}:
        if base_cmd == 'cp':
            if any(a in ('--recursive', '--dereference', '--archive') or (a.startswith('-') and not a.startswith('--') and any(c in a for c in ('r', 'R', 'L', 'a', 'H'))) or a.startswith(('--recursive', '--dereference', '--archive')) for a in args):
                return 'ask', f"Recursive or symlink-dereferencing cp requires confirmation: {' '.join(cmd_tokens)}"
        for a in args:
            if not a.startswith('-') and ('$' in a or '`' in a):
                return 'ask', f"{base_cmd} with unexpanded variable requires confirmation: {' '.join(cmd_tokens)}"
        target_dir = None
        positionals = []
        end_of_options = False
        i = 0
        while i < len(args):
            a = args[i]
            if end_of_options:
                positionals.append(a)
            elif a == '--':
                end_of_options = True
            elif a.startswith('--target-directory='):
                target_dir = a.split('=', 1)[1]
            elif a == '--target-directory' and i + 1 < len(args):
                target_dir = args[i + 1]
                i += 1
            elif a.startswith('-') and not a.startswith('--') and 't' in a:
                t_idx = a.index('t')
                rest = a[t_idx + 1:]
                if rest:
                    target_dir = rest.lstrip('=')
                elif i + 1 < len(args):
                    target_dir = args[i + 1]
                    i += 1
            elif not a.startswith('-'):
                positionals.append(a)
            i += 1

        if not positionals and not target_dir:
            return 'ask', f"{base_cmd} missing operands"

        if target_dir:
            dest_dir = target_dir
            sources = positionals
        elif len(positionals) >= 2:
            dest_dir = positionals[-1]
            sources = positionals[:-1]
        else:
            return 'ask', f"{base_cmd} requires at least source and destination"

        effective_dests = []
        dest_norm = expand_path(dest_dir, cwd)
        is_dest_dir = os.path.isdir(dest_norm) or dest_dir.endswith(os.sep) or len(sources) > 1

        for src in sources:
            if is_dest_dir:
                effective_dest = os.path.join(dest_dir, os.path.basename(src.rstrip(os.sep)))
            else:
                effective_dest = dest_dir
            effective_dests.append(effective_dest)

        all_paths = list(sources) + [dest_dir] + effective_dests
        for p in all_paths:
            if is_sensitive_credential_path(p, cwd) or is_system_write_path(p, cwd):
                return 'deny', f"{base_cmd} targeting sensitive or system path is forbidden: {p}"
            if not is_path_in_workspaces(p, workspace_paths, cwd):
                return 'ask', f"{base_cmd} path outside workspace requires approval: {p}"

        for ed in [dest_dir] + effective_dests:
            if is_git_admin_path(ed, cwd):
                return 'ask', f"{base_cmd} destination targeting git administrative file requires confirmation: {ed}"
        if base_cmd == 'mv':
            for src in sources:
                if is_git_admin_path(src, cwd):
                    return 'ask', f"mv removing git administrative file requires confirmation: {src}"

        for ed in effective_dests:
            ed_norm = expand_path(ed, cwd)
            if os.path.islink(ed_norm):
                link_target = str(Path(ed_norm).resolve())
                if not is_path_in_workspaces(link_target, workspace_paths, cwd) or is_sensitive_credential_path(link_target, cwd) or is_system_write_path(link_target, cwd):
                    return 'deny', f"{base_cmd} destination is a symlink pointing to sensitive or external target: {ed}"
                return 'ask', f"{base_cmd} destination is an existing symlink: {ed}"

        return 'allow', f"Safe file {base_cmd} within workspace"

    if base_cmd in {'mkdir', 'touch'}:
        targets = [a for a in args if not a.startswith('-')]
        if any(is_git_admin_path(t, cwd) for t in targets):
            return 'ask', f"{base_cmd} targeting git administrative path requires confirmation: {' '.join(cmd_tokens)}"
        if targets and all(is_path_in_workspaces(t, workspace_paths, cwd) and not is_system_write_path(t, cwd) for t in targets):
            return 'allow', f"Safe directory/file creation within workspace: {base_cmd}"

    return 'ask', f"Command requires confirmation: {' '.join(cmd_tokens)}"


def classify_command_line(cmd_str, workspace_paths, cwd):
    """Classify an entire shell command line string across lines, chains, and pipelines."""
    if not isinstance(cmd_str, str) or not cmd_str.strip():
        return 'ask', 'Empty command line or invalid type'

    # Check for command substitutions $(...) or `...` or process substitutions <(...) >(...)
    if re.search(r'(\$\(|\`|<(?=\()|>(?=\())', cmd_str):
        return 'ask', 'Command contains command or process substitution'

    lines = [line.strip() for line in cmd_str.splitlines() if line.strip()]
    if not lines:
        return 'allow', 'Empty command'

    subcommands_all = []
    pipeline_links_all = []

    for line in lines:
        tokens = tokenize_command_line(line)
        if tokens is None:
            return 'ask', 'Unable to safely parse command tokens'
        subcmds, pipe_links = split_into_subcommands(tokens)
        offset = len(subcommands_all)
        subcommands_all.extend(subcmds)
        for sub_idx, op in pipe_links:
            pipeline_links_all.append((offset + sub_idx, op))

    if not subcommands_all:
        return 'allow', 'No subcommands found'

    # If a compound command has a standalone variable assignment before other commands,
    # the environment is stateful across the command line.
    if len(subcommands_all) > 1:
        for sub in subcommands_all[:-1]:
            if sub and all('=' in tok and not tok.startswith('-') and tok.split('=', 1)[0].isidentifier() for tok in sub):
                return 'ask', f"Compound command with stateful variable assignment requires confirmation: {cmd_str}"

    # Check for network downloads piped into interpreters
    for sub_idx, op in pipeline_links_all:
        if sub_idx + 1 < len(subcommands_all):
            left_sub = subcommands_all[sub_idx]
            right_sub = subcommands_all[sub_idx + 1]

            left_base = os.path.basename(left_sub[0]) if left_sub else ''
            right_base = os.path.basename(right_sub[0]) if right_sub else ''

            if left_base in {'curl', 'wget', 'fetch'} and right_base in {'sh', 'bash', 'zsh', 'python', 'python3', 'node', 'perl', 'ruby'}:
                return 'deny', f"Piping remote download ({left_base}) directly into interpreter ({right_base}) is forbidden"

    # Evaluate all subcommands; deny strictly takes precedence over ask
    verdicts = []
    for sub in subcommands_all:
        verdict, reason = classify_subcommand(sub, workspace_paths, cwd)
        verdicts.append((verdict, reason))

    for v, r in verdicts:
        if v == 'deny':
            return 'deny', r

    for v, r in verdicts:
        if v == 'ask':
            return 'ask', r

    return 'allow', 'Safe command auto-approved by classifier'


def classify_file_modification(target_file, workspace_paths, cwd):
    """Classify file write or replacement tools."""
    if not target_file or not isinstance(target_file, str):
        return 'ask', 'No target file specified or invalid type'

    if is_sensitive_credential_path(target_file, cwd) or is_system_write_path(target_file, cwd):
        return 'deny', f"Modifying sensitive or system path is forbidden: {target_file}"

    if is_git_admin_path(target_file, cwd):
        return 'ask', f"Modifying git repository configuration or hooks requires confirmation: {target_file}"

    if is_path_in_workspaces(target_file, workspace_paths, cwd):
        return 'allow', f"File modification within workspace auto-approved: {os.path.basename(target_file)}"

    return 'ask', f"File modification outside workspace requires approval: {target_file}"


def classify_file_read(target_file, cwd):
    """Classify read-only file access tools."""
    if not target_file or not isinstance(target_file, str):
        return 'allow', 'File read query'
    if is_sensitive_credential_path(target_file, cwd):
        return 'deny', f"Reading sensitive credentials is forbidden: {target_file}"
    norm = expand_path(target_file, cwd)
    norm_dir = norm if norm.endswith(os.sep) else norm + os.sep
    for prefix in get_sensitive_credential_prefixes():
        norm_prefix = str(Path(prefix).resolve()) if os.path.exists(prefix) else os.path.abspath(prefix)
        if norm_prefix.startswith(norm_dir):
            return 'ask', f"Searching directory containing sensitive credentials requires approval: {target_file}"
    return 'allow', f"Safe file read: {os.path.basename(target_file)}"


def classify_directory_search(target_dir, args, cwd):
    """Classify recursive directory search tools (grep_search, find_by_name)."""
    if not target_dir or not isinstance(target_dir, str):
        target_dir = cwd

    # If searching sensitive credential path: hard deny
    if is_sensitive_credential_path(target_dir, cwd):
        return 'deny', f"Searching sensitive credentials is forbidden: {target_dir}"

    norm = expand_path(target_dir, cwd)
    norm_dir = norm if norm.endswith(os.sep) else norm + os.sep

    # Ancestor check for fixed credential prefixes
    for prefix in get_sensitive_credential_prefixes():
        norm_prefix = str(Path(prefix).resolve()) if os.path.exists(prefix) else os.path.abspath(prefix)
        if norm_prefix.startswith(norm_dir):
            return 'ask', f"Searching directory containing sensitive credentials requires approval: {target_dir}"

    # Check search filter options (Includes, Pattern) for sensitive patterns
    includes = args.get('Includes')
    if isinstance(includes, list):
        for inc in includes:
            if isinstance(inc, str) and (matches_sensitive_pattern(inc) or any(c in inc for c in ('.env', 'id_', '.key', '.pem'))):
                return 'deny', f"Search targeting sensitive pattern is forbidden: {inc}"

    pattern = args.get('Pattern')
    if isinstance(pattern, str) and (matches_sensitive_pattern(pattern) or any(c in pattern for c in ('.env', 'id_', '.key', '.pem'))):
        return 'deny', f"Search targeting sensitive pattern is forbidden: {pattern}"

    # If target is a directory, inspect if it contains descendant sensitive files or symlinks
    if os.path.isdir(norm):
        desc_verdict, desc_reason = check_directory_descendants(norm, cwd)
        if desc_verdict != 'allow':
            return desc_verdict, f"Directory search {desc_reason}: {target_dir}"

    return 'allow', f"Safe directory search: {os.path.basename(target_dir) or target_dir}"


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

    # Environment and session overrides
    mode = os.environ.get('ANTIGRAVITY_CLASSIFIER_MODE', '').lower()
    if mode in ('disabled', 'off'):
        print(json.dumps({'decision': 'ask', 'reason': 'Classifier disabled via ANTIGRAVITY_CLASSIFIER_MODE'}))
        return
    if mode in ('allow_all', 'bypass'):
        print(json.dumps({'decision': 'allow', 'reason': 'Auto-approved via ANTIGRAVITY_CLASSIFIER_MODE'}))
        return

    try:
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

        raw_cwd = args.get('Cwd') or args.get('cwd')
        if isinstance(raw_cwd, str) and raw_cwd.strip():
            cwd = raw_cwd
        else:
            cwd = os.getcwd()

        if tool_name == 'run_command':
            cmd = args.get('CommandLine') or args.get('command')
            if cmd is None or not isinstance(cmd, str):
                decision, reason = 'ask', 'run_command CommandLine argument is missing or invalid'
            else:
                decision, reason = classify_command_line(cmd, workspace_paths, cwd)
        elif tool_name in ('write_to_file', 'replace_file_content', 'multi_replace_file_content'):
            target = args.get('TargetFile') or args.get('path') or ''
            decision, reason = classify_file_modification(target, workspace_paths, cwd)
        elif tool_name == 'view_file':
            target = args.get('AbsolutePath') or args.get('TargetFile') or ''
            decision, reason = classify_file_read(target, cwd)
        elif tool_name in ('grep_search', 'find_by_name'):
            target = args.get('SearchPath') or args.get('SearchDirectory') or args.get('AbsolutePath') or ''
            decision, reason = classify_directory_search(target, args, cwd)
        else:
            decision, reason = 'ask', f"Tool {tool_name} requires confirmation"

        print(json.dumps({'decision': decision, 'reason': reason}))
    except Exception as e:
        # Failsafe: never crash unhandled, always emit a valid JSON decision
        print(json.dumps({'decision': 'ask', 'reason': f"Permission classifier internal error: {e}"}))


if __name__ == '__main__':
    main()
