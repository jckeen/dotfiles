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
import time

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

# Subcommands / script prefixes for package managers that are safe to run (excluding test and build runners)
SAFE_RUN_PREFIXES = ('lint', 'check', 'typecheck', 'format', 'verify', 'doc')

def get_sensitive_credential_prefixes():
    """Dynamically resolve sensitive credential prefixes against current HOME."""
    home = os.path.expanduser('~')
    return (
        os.path.join(home, '.ssh'),
        os.path.join(home, '.aws'),
        os.path.join(home, '.gnupg'),
        os.path.join(home, '.netrc'),
        os.path.join(home, '.git-credentials'),
        os.path.join(home, '.npmrc'),
        os.path.join(home, '.pypirc'),
        os.path.join(home, '.docker'),
        os.path.join(home, '.codex'),
        os.path.join(home, '.claude'),
        os.path.join(home, '.gemini', 'antigravity-cli'),
        os.path.join(home, '.kube'),
        os.path.join(home, '.config', 'gcloud'),
        os.path.join(home, '.azure'),
        os.path.join(home, '.vault-token'),
        os.path.join(home, '.config', 'gh'),
        '/etc/shadow',
        '/etc/sudoers',
        '/run/secrets',
    )

SENSITIVE_FILENAMES = {
    'antigravity-oauth-token',
    'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa',
    '.bashrc', '.bash_profile', '.zshrc', '.profile',
    'hosts.yml',
    '.git-credentials', 'git-credentials',
    '.npmrc',
    '.pypirc',
    'application_default_credentials.json',
    '.vault-token',
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

SAFE_INLINE_ENV_VARS = {
    'CI', 'NODE_ENV', 'LANG', 'LC_ALL', 'LC_CTYPE',
    'PYTHONUNBUFFERED', 'TERM', 'NO_COLOR', 'FORCE_COLOR', 'TZ',
}

PROTECTED_BRANCHES = {'main', 'master', 'release', 'prod', 'production'}

# Redirection operators (ordered by descending length for greedy matching)
REDIRECTION_OPERATORS = ('&>>', '>|', '&>', '>>', '>&', '>', '<>', '<')


def is_dangerous_env_var(var_name):
    if var_name in DANGEROUS_ENV_VARS:
        return True
    return any(var_name.startswith(p) for p in DANGEROUS_ENV_PREFIXES)


def is_credential_var_name(var_name):
    """Check if variable name represents credentials, tokens, secrets, or keys."""
    if not var_name or not isinstance(var_name, str):
        return False
    v_upper = var_name.upper()
    return any(term in v_upper for term in ('KEY', 'TOKEN', 'SECRET', 'PASS', 'AUTH', 'CRED', 'COOKIE', 'BEARER', 'PRIVATE', 'SIGNATURE')) or \
           any(v_upper.startswith(prefix) for prefix in ('AWS_', 'GITHUB_', 'GH_', 'OPENAI_', 'ANTHROPIC_', 'GEMINI_', 'CODEX_', 'CLAUDE_', 'GIT_ASKPASS'))


def is_credential_env_var(text):
    """Check if text references credential environment variables."""
    if not text or not isinstance(text, str):
        return False
    vars_found = re.findall(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', text)
    for v in vars_found:
        if is_credential_var_name(v):
            return True
    return False


def unquote_token(tok):
    """Return token directly (POSIX tokenization already removes shell quoting)."""
    if not tok or not isinstance(tok, str):
        return ''
    return tok


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

    # Strip shell quotes and backslash escapes (e.g. /etc/sha""dow or /etc/sha\dow)
    clean = re.sub(r'[\"\'\\]', '', path_str)

    # Check for glob/bracket tricks like .en[v] or ~/.s[s]h/id_*
    clean = re.sub(r'\[(.)\]', r'\1', clean)
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

    # Check for Git config or common credential stores
    norm_slash = norm.replace('\\', '/')
    clean_slash = clean.replace('\\', '/')
    if (norm_slash.endswith('/.git/config') or clean_slash.endswith('/.git/config') or
        norm_slash == '.git/config' or clean_slash == '.git/config' or
        '/.git/config/' in norm_slash or
        norm_slash.endswith('/.git-credentials') or clean_slash.endswith('/.git-credentials') or
        norm_slash.endswith('/.docker/config.json') or clean_slash.endswith('/.docker/config.json')):
        return True

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

    Returns (verdict, reason) where verdict is 'deny', 'force_ask', or 'allow'.
    """
    if not target_dir or not isinstance(target_dir, str):
        return 'allow', 'Not a directory'
    norm = expand_path(target_dir, cwd)
    if not os.path.isdir(norm):
        return 'allow', 'Not a directory'

    start_time = time.monotonic()
    inspected_count = 0
    try:
        norm_parts_len = len(Path(norm).resolve().parts)
    except Exception:
        norm_parts_len = len(Path(norm).parts)
    MAX_DEPTH = 6
    MAX_ENTRIES = 5000
    MAX_ELAPSED = 0.8
    truncated = False

    try:
        for root, dirs, files in os.walk(norm):
            if time.monotonic() - start_time > MAX_ELAPSED or inspected_count > MAX_ENTRIES:
                truncated = True
                break
            # Prune VCS and dependency caches
            if '.git' in dirs:
                dirs.remove('.git')
            if 'node_modules' in dirs:
                dirs.remove('node_modules')

            # Depth bound: stop recursing beyond MAX_DEPTH
            try:
                current_depth = len(Path(root).resolve().parts) - norm_parts_len
            except Exception:
                current_depth = 0
            if current_depth >= MAX_DEPTH:
                if dirs:
                    truncated = True
                    dirs.clear()

            # Check symlinked subdirectories with per-entry limits
            for d in list(dirs):
                inspected_count += 1
                if inspected_count > MAX_ENTRIES or (time.monotonic() - start_time) > MAX_ELAPSED:
                    truncated = True
                    break
                d_full = os.path.join(root, d)
                if os.path.islink(d_full):
                    try:
                        link_target = str(Path(d_full).resolve())
                        if is_sensitive_credential_path(link_target, cwd):
                            return 'deny', f"contains symlink to sensitive directory ({d} -> {link_target})"
                    except Exception:
                        truncated = True
            if truncated:
                break

            # Single pass over files with per-entry bounds check
            for f in files:
                inspected_count += 1
                if inspected_count > MAX_ENTRIES or (time.monotonic() - start_time) > MAX_ELAPSED:
                    truncated = True
                    break
                f_full = os.path.join(root, f)
                if os.path.islink(f_full):
                    try:
                        link_target = str(Path(f_full).resolve())
                        if matches_sensitive_pattern(os.path.basename(link_target)) or is_sensitive_credential_path(link_target, cwd):
                            return 'deny', f"contains symlink to sensitive file ({f} -> {link_target})"
                    except Exception:
                        truncated = True
                elif matches_sensitive_pattern(f) or is_sensitive_credential_path(f_full, cwd):
                    return 'force_ask', f"contains sensitive descendant file ({f})"
            if truncated:
                break
    except Exception as e:
        return 'force_ask', f"Directory scan error ({e}) requires confirmation: {target_dir}"

    if truncated:
        return 'force_ask', f"Directory scan incomplete (depth, entry, or time limit reached) requires confirmation: {target_dir}"

    return 'allow', 'Directory clean'


def get_safe_git_executable():
    """Resolve trusted git executable to prevent executing shadowed binaries in probe subprocesses."""
    for candidate in ('/usr/bin/git', '/bin/git', '/usr/local/bin/git'):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    git_which = shutil.which('git')
    if git_which:
        norm = os.path.abspath(git_which)
        if not norm.startswith(('/tmp', '/var/tmp', '/dev/shm')):
            return norm
    return 'git'


_GIT_PROBE_CACHE = {}


def git_run_probe(args, cwd=None, timeout=1):
    """Run internal git probe command using a trusted git executable."""
    git_bin = get_safe_git_executable()
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    cache_key = (effective_cwd, tuple(args))
    if cache_key in _GIT_PROBE_CACHE:
        return _GIT_PROBE_CACHE[cache_key]
    try:
        res = subprocess.run(
            [git_bin] + args,
            cwd=effective_cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        _GIT_PROBE_CACHE[cache_key] = res
        return res
    except Exception:
        return None


def git_has_external_diff_configured(cwd=None):
    """Check if git has an external diff or textconv driver configured that executes programs."""
    res = git_run_probe(['config', '--get-regexp', r'^diff\.(external|.*\.command|.*\.textconv)$'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        return True
    return False


def git_has_fsmonitor_configured(cwd=None):
    """Check if git has a core.fsmonitor hook configured that executes programs."""
    res = git_run_probe(['config', '--get', 'core.fsmonitor'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        val = res.stdout.strip().lower()
        if val not in ('false', '0', 'no', 'off'):
            return True
    return False


def git_has_active_hooks(cwd=None, hook_names=()):
    """Check if git repository has active (executable) repository hooks."""
    if not hook_names:
        return False
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    res = git_run_probe(['rev-parse', '--git-path', 'hooks'], cwd=cwd)
    if not res or res.returncode != 0:
        return False
    hooks_dir = res.stdout.strip()
    if not hooks_dir:
        return False
    if not os.path.isabs(hooks_dir):
        hooks_dir = os.path.join(effective_cwd, hooks_dir)
    for h in hook_names:
        h_path = os.path.join(hooks_dir, h)
        if os.path.isfile(h_path) and os.access(h_path, os.X_OK):
            return True
    return False


def git_has_filter_configured(cwd=None):
    """Check if git has filter drivers (clean, process, smudge) configured that execute programs."""
    res = git_run_probe(['config', '--get-regexp', r'^filter\..*\.(clean|process|smudge)$'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        return True
    return False


def git_has_gpgsign_configured(cwd=None):
    """Check if git repository has commit.gpgSign configured to sign commits."""
    res = git_run_probe(['config', '--bool', 'commit.gpgsign'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip() == 'true':
        return True
    return False


def git_remotes_have_credentials(cwd=None):
    """Check if any git remote URL contains embedded user/password/token credentials."""
    res = git_run_probe(['config', '--get-regexp', r'^remote\..*\.url$'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout:
        for line in res.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                url = parts[1].strip()
                if '://' in url and '@' in url.split('://', 1)[1]:
                    return True
    return False


def git_has_transport_executable_configured(cwd=None):
    """Check if git repository has transport or remote execution helpers configured in local repo config."""
    res = git_run_probe(['config', '--local', '--get-regexp', r'^(core\.sshcommand|core\.askpass|core\.pager|credential\..*helper|credential\.helper|remote\..*\.vcs|remote\..*\.uploadpack|remote\..*\.receivepack|remote\..*\.proxy|http\..*proxy)$'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        return True
    return False


def git_has_pager_configured(cwd=None, git_sub=None):
    """Check if git repository or config has core.pager or pager.<cmd> configured."""
    patterns = [r'^core\.pager$']
    if git_sub:
        patterns.append(rf'^pager\.{re.escape(git_sub)}$')
    res = git_run_probe(['config', '--get-regexp', '|'.join(patterns)], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        for line in res.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if val.lower() in ('false', '0'):
                    continue
                return True
    return False


SAFE_GIT_REMOTE_SCHEMES = {'http', 'https', 'ssh', 'git', 'file', 'ftp', 'ftps'}


def is_unsafe_git_remote_url(url):
    """Check if a remote URL uses an external helper, custom scheme, or ext:: protocol."""
    if not url or not isinstance(url, str):
        return False
    url = url.strip()
    # Check for ext::, fd::, or any custom :: helper
    if '::' in url:
        return True
    # Check for custom scheme:// (Git invokes git-remote-<scheme> for non-standard schemes)
    if '://' in url:
        scheme = url.split('://', 1)[0].lower()
        if scheme not in SAFE_GIT_REMOTE_SCHEMES:
            return True
        return False
    # Check for SCP-style ssh syntax: [user@]host:path
    if ':' in url:
        prefix = url.split(':', 1)[0]
        # If prefix contains no slashes, it is SCP ssh syntax
        if '/' not in prefix and '\\' not in prefix:
            return False
    # Local path (relative or absolute)
    return False


def git_remotes_have_executable_helpers(cwd=None):
    """Check if any git remote URL or rewritten URL uses an external helper protocol or custom scheme."""
    # Check if any url.*.insteadof or url.*.pushinsteadof config rewrites to an unsafe scheme
    res_inst = git_run_probe(['config', '--get-regexp', r'^url\..*\.(insteadof|pushinsteadof)$'], cwd=cwd)
    if res_inst and res_inst.returncode == 0 and res_inst.stdout:
        for line in res_inst.stdout.splitlines():
            key = line.split(None, 1)[0].lower()
            if key.startswith('url.'):
                parts = key[4:].rsplit('.', 1)
                if len(parts) == 2:
                    base = parts[0]
                    if is_unsafe_git_remote_url(base):
                        return True

    # Check configured remotes
    res = git_run_probe(['remote'], cwd=cwd)
    remotes = []
    if res and res.returncode == 0 and res.stdout:
        remotes = [r.strip() for r in res.stdout.splitlines() if r.strip()]

    if not remotes:
        res_cfg = git_run_probe(['config', '--get-regexp', r'^remote\..*\.url$'], cwd=cwd)
        if res_cfg and res_cfg.returncode == 0 and res_cfg.stdout:
            for line in res_cfg.stdout.splitlines():
                parts = line.split(None, 1)
                if len(parts) == 2:
                    url = parts[1].strip()
                    if is_unsafe_git_remote_url(url):
                        return True

    for r in remotes:
        # Check resolved URL via ls-remote --get-url (which expands url.*.insteadOf without contacting network)
        res_url = git_run_probe(['ls-remote', '--get-url', r], cwd=cwd)
        if res_url and res_url.returncode == 0 and res_url.stdout.strip():
            resolved = res_url.stdout.strip()
            if is_unsafe_git_remote_url(resolved):
                return True
        else:
            res_raw = git_run_probe(['config', f'remote.{r}.url'], cwd=cwd)
            if res_raw and res_raw.returncode == 0 and res_raw.stdout.strip():
                if is_unsafe_git_remote_url(res_raw.stdout.strip()):
                    return True

    return False


def git_has_gpg_program_configured(cwd=None):
    """Check if git repository has a custom gpg.program or gpg.*.program configured."""
    res = git_run_probe(['config', '--get-regexp', r'^gpg\..*program$'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        return True
    return False


def git_get_current_branch(cwd=None):
    """Resolve current git branch name in repository."""
    res = git_run_probe(['rev-parse', '--abbrev-ref', 'HEAD'], cwd=cwd)
    if res and res.returncode == 0:
        return res.stdout.strip()
    return ''


def git_get_local_protected_branches(cwd=None):
    """List any local branches in repository that are in PROTECTED_BRANCHES."""
    res = git_run_probe(['for-each-ref', '--format=%(refname:short)', 'refs/heads/'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout:
        branches = [line.strip() for line in res.stdout.splitlines() if line.strip()]
        return [b for b in branches if b in PROTECTED_BRANCHES]
    return []


def git_probe_uncommitted_sensitive_files(cwd=None):
    """Check if repository contains modified or untracked sensitive files that broad git add would stage."""
    res = git_run_probe(['status', '--porcelain', '-uall'], cwd=cwd)
    if not res:
        return 'unknown'
    if res.returncode != 0:
        return 'safe'
    for line in res.stdout.splitlines():
        if len(line) >= 4:
            path_part = line[3:].strip()
            if ' -> ' in path_part:
                path_part = path_part.split(' -> ', 1)[1]
            if matches_sensitive_pattern(path_part) or is_sensitive_credential_path(path_part, cwd):
                return 'sensitive'
    return 'safe'


def git_probe_staged_sensitive_files(cwd=None, include_unstaged_tracked=False):
    """Check if git staged index (or unstaged tracked files if -a) contains sensitive files."""
    res = git_run_probe(['diff', '--cached', '--name-only'], cwd=cwd)
    if not res:
        return 'unknown'
    if res.returncode != 0:
        return 'safe'
    for path in res.stdout.splitlines():
        path = path.strip()
        if path and (matches_sensitive_pattern(path) or is_sensitive_credential_path(path, cwd)):
            return 'sensitive'

    if include_unstaged_tracked:
        res_unstaged = git_run_probe(['diff', '--name-only'], cwd=cwd)
        if res_unstaged and res_unstaged.returncode == 0:
            for path in res_unstaged.stdout.splitlines():
                path = path.strip()
                if path and (matches_sensitive_pattern(path) or is_sensitive_credential_path(path, cwd)):
                    return 'sensitive'
    return 'safe'


def is_trusted_executable_path(exe_path, workspace_paths, cwd):
    """Verify that resolved executable is in a system or user toolchain directory and not in workspace or tmp."""
    if not exe_path or not isinstance(exe_path, str):
        return False
    norm_exe = expand_path(exe_path, cwd)
    if is_path_in_workspaces(norm_exe, workspace_paths, cwd):
        return False
    untrusted_prefixes = ('/tmp', '/var/tmp', '/dev/shm')
    for p in untrusted_prefixes:
        if norm_exe == p or norm_exe.startswith(p + os.sep):
            return False
    exe_dir = os.path.dirname(norm_exe)
    if exe_dir in SYSTEM_BIN_DIRS or exe_dir in {'/bin', '/usr/bin', '/usr/local/bin', '/sbin', '/usr/sbin', '/snap/bin', '/usr/games'}:
        return True
    home = os.path.expanduser('~')
    trusted_home_dirs = (
        os.path.join(home, '.local', 'bin'),
        os.path.join(home, '.cargo', 'bin'),
        os.path.join(home, 'go', 'bin'),
        os.path.join(home, '.local', 'share'),
        os.path.join(home, '.npm-global', 'bin'),
        os.path.join(home, '.nvm'),
        os.path.join(home, '.fnm'),
        os.path.join(home, '.asdf'),
        os.path.join(home, '.pyenv'),
    )
    for td in trusted_home_dirs:
        if exe_dir == td or norm_exe.startswith(td + os.sep):
            return True
    if norm_exe.startswith('/opt/') or norm_exe.startswith(os.path.join(os.sep + 'home', 'linuxbrew', '')):
        return True
    return False


def strip_git_output_options(args_list):
    """Strip output redirection options (-o, --output, --output=..., etc.) and exit-code flags from probe arguments."""
    clean = []
    skip_next = False
    for a in args_list:
        if skip_next:
            skip_next = False
            continue
        if a in ('-o', '--output', '--output-directory'):
            skip_next = True
            continue
        if a.startswith(('-o=', '--output=', '--output-directory=')):
            continue
        if a.startswith('-o') and len(a) > 2 and not a.startswith('--'):
            continue
        if a.startswith('--o') and ('--output'.startswith(a.split('=', 1)[0]) or '--output-directory'.startswith(a.split('=', 1)[0])):
            if '=' not in a:
                skip_next = True
            continue
        if a == '--show-signature' or a.startswith(('--show-sig', '--show-signature=')):
            continue
        if a in ('--exit-code', '--quiet', '-q', '-z', '--null'):
            continue
        clean.append(a)
    return clean


def git_command_touches_sensitive_files(git_sub, args, cwd):
    """Check if git diff / show / log / format-patch touches sensitive files in repository changes.

    Returns:
        'sensitive' if sensitive files are touched in patch output,
        'safe' if verified clean,
        'unknown' if git probe failed, timed out, or encountered an error.
    """
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    try:
        safe_args = strip_git_output_options(args[1:])
        if git_sub == 'diff':
            cmd = ['git', 'diff', '--name-only'] + [a for a in safe_args if a != '--name-only']
        elif git_sub == 'show':
            cmd = ['git', 'show', '--name-only', '--format=', '--no-show-signature'] + [a for a in safe_args if not a.startswith('--format=') and a != '--name-only']
        elif git_sub in ('log', 'whatchanged') and any(a in ('-p', '-u', '--patch', '--stat', '--numstat', '--shortstat') or (a.startswith('-') and not a.startswith('--') and any(c in a for c in ('p', 'u'))) for a in args):
            cmd = ['git', 'log', '--name-only', '--format=', '--no-show-signature'] + [a for a in safe_args if not a.startswith('--format=') and a != '--name-only']
        elif git_sub == 'stash' and len(args) > 1 and args[1] == 'show':
            safe_stash = strip_git_output_options(args[2:])
            cmd = ['git', 'stash', 'show', '--name-only'] + [a for a in safe_stash if a != '--name-only']
        elif git_sub == 'format-patch':
            log_args = [a for a in safe_args if not a.startswith(('--stdout', '--numbered', '-n', '-N', '--keep-subject', '-k'))]
            cmd = ['git', 'log', '--name-only', '--format=', '--no-show-signature'] + log_args
        else:
            return 'safe'

        res = git_run_probe(cmd[1:], cwd=effective_cwd, timeout=2)
        if not res:
            return 'unknown'
        if res.returncode in (0, 1):
            if res.stdout:
                parts = []
                for chunk in res.stdout.split('\0'):
                    for line in chunk.splitlines():
                        f = line.strip().rstrip('\0')
                        if f:
                            parts.append(f)
                for f in parts:
                    if matches_sensitive_pattern(f) or is_sensitive_credential_path(f, effective_cwd):
                        return 'sensitive'
            return 'safe'
        if not res.stdout and res.returncode != 0:
            err = (res.stderr or '').lower()
            # Non-git directory or missing revision in empty repository: no patch is produced so no credentials leak
            if any(k in err for k in ('not a git repository', 'ambiguous argument', 'unknown revision', 'bad revision', 'does not have any commits yet')):
                return 'safe'
        return 'unknown'
    except Exception:
        return 'unknown'


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


def workspace_has_local_python_module(module_name, workspace_paths, cwd=None):
    """Check if cwd or any workspace contains a local python file or package shadowing module_name."""
    if not module_name or not isinstance(module_name, str):
        return False
    check_dirs = set()
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    check_dirs.add(effective_cwd)
    if workspace_paths:
        for ws in workspace_paths:
            if ws and isinstance(ws, str):
                check_dirs.add(expand_path(ws, cwd))

    for d in check_dirs:
        # Check <module>.py or <module>.pyc
        mod_file = os.path.join(d, f"{module_name}.py")
        if os.path.isfile(mod_file):
            return True
        # Check <module>/ directory with __init__.py or __main__.py
        mod_pkg = os.path.join(d, module_name)
        if os.path.isdir(mod_pkg):
            if os.path.isfile(os.path.join(mod_pkg, '__init__.py')) or os.path.isfile(os.path.join(mod_pkg, '__main__.py')):
                return True
    return False


DEV_TOOL_OUTPUT_FLAGS = (
    '-o', '--output', '--output-file', '--output-dir',
    '--target-dir', '--outDir', '-outDir', '--outFile', '-outFile',
    '--reporter-outfile', '--reporter-out-file', '--outputFile', '--report-dir',
    '--coverage-dir', '--coverage-directory', '--coverageDirectory', '--results-dir', '--resultsDir',
    '--junitxml', '--junit-xml', '--result-log',
    '--log-file', '--html-report', '--xml-report', '--txt-report',
    '--cobertura-xml-report', '--linecount-report', '--linecoverage-report',
)


def check_dev_tool_output(args, workspace_paths, cwd, tool_name='tool'):
    """Check if dev tool output options target valid destinations within workspace.

    Returns (verdict, reason) or None if safe.
    """
    i = 0
    while i < len(args):
        a = args[i]
        dest = None
        for flag in DEV_TOOL_OUTPUT_FLAGS:
            if a == flag:
                if i + 1 < len(args):
                    dest = args[i + 1]
                    i += 1
                break
            elif a.startswith(flag + '='):
                dest = a.split('=', 1)[1]
                break
            elif flag.startswith('-') and not flag.startswith('--') and len(flag) == 2 and a.startswith(flag):
                dest = a[2:]
                break

        if dest:
            if dest == '/dev/null':
                i += 1
                continue
            if is_sensitive_credential_path(dest, cwd):
                return 'deny', f"{tool_name} output targeting sensitive path is forbidden: {dest}"
            if is_system_write_path(dest, cwd):
                return 'deny', f"{tool_name} output targeting system path is forbidden: {dest}"
            if is_git_admin_path(dest, cwd):
                return 'force_ask', f"{tool_name} output modifying git repository metadata or hooks requires confirmation: {dest}"
            if not is_path_in_workspaces(dest, workspace_paths, cwd):
                return 'force_ask', f"{tool_name} output targeting destination outside workspace requires confirmation: {dest}"
        i += 1
    return None


DEV_TOOL_CONFIG_FLAGS = {
    '-c', '--config',
    '--manifest-path',
    '-p', '--project',
    '--rcfile',
    '--rootdir',
    '--rulesdir',
    '--resolve-plugins-relative-to',
    '--ignore-path',
    '--target-dir',
}


def check_dev_tool_inputs(args, workspace_paths, cwd, tool_name='tool'):
    """Validate that development runner inputs, configs, and target files remain within workspace."""
    if not is_path_in_workspaces(cwd, workspace_paths, cwd):
        return 'force_ask', f"{tool_name} with working directory outside workspace requires confirmation: {cwd}"

    i = 0
    while i < len(args):
        a = args[i]
        val = None
        for flag in DEV_TOOL_CONFIG_FLAGS:
            if a == flag:
                if i + 1 < len(args):
                    val = args[i + 1]
                    i += 1
                break
            elif a.startswith(flag + '='):
                val = a.split('=', 1)[1]
                break
            elif flag.startswith('-') and not flag.startswith('--') and len(flag) == 2 and a.startswith(flag):
                val = a[2:]
                break

        if val:
            if is_sensitive_credential_path(val, cwd):
                return 'deny', f"{tool_name} targeting sensitive config is forbidden: {val}"
            if is_system_write_path(val, cwd):
                return 'deny', f"{tool_name} targeting system path is forbidden: {val}"
            if not is_path_in_workspaces(val, workspace_paths, cwd):
                return 'force_ask', f"{tool_name} config outside workspace requires confirmation: {val}"
            i += 1
            continue

        # Check positional arguments for path targets outside workspace
        if not a.startswith('-'):
            # Ignore subcommands and flags
            if a not in {'test', 'check', 'lint', 'build', 'run', 'vet', 'fmt', 'clippy', 'bench', 'format', 'typecheck', 'verify', 'doc'}:
                # If argument appears to be a file/path target (has slash, dot, or exists)
                if '/' in a or '\\' in a or a.startswith('.') or os.path.isabs(a) or (os.path.exists(os.path.join(cwd or '', a)) and not a.startswith('-')):
                    if is_sensitive_credential_path(a, cwd):
                        return 'deny', f"{tool_name} targeting sensitive path is forbidden: {a}"
                    if is_system_write_path(a, cwd):
                        return 'deny', f"{tool_name} targeting system path is forbidden: {a}"
                    if not is_path_in_workspaces(a, workspace_paths, cwd):
                        return 'force_ask', f"{tool_name} target outside workspace requires confirmation: {a}"
        i += 1
    return None


def find_package_json(cwd, workspace_paths):
    """Search for package.json starting from cwd up to workspace boundary or filesystem root."""
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    try:
        curr = Path(effective_cwd).resolve()
    except Exception:
        curr = Path(effective_cwd)
    ws_roots = [Path(ws).resolve() for ws in (workspace_paths or [effective_cwd])]

    while True:
        pkg_file = curr / 'package.json'
        if pkg_file.is_file():
            return str(pkg_file)
        if any(curr == ws for ws in ws_roots) or curr.parent == curr:
            break
        curr = curr.parent
    return None


def get_package_script(pkg_path, script_name):
    """Read package.json and extract named script command."""
    try:
        with open(pkg_path, 'r', encoding='utf-8', errors='replace') as f:
            data = json.load(f)
        scripts = data.get('scripts')
        if isinstance(scripts, dict) and script_name in scripts:
            val = scripts[script_name]
            if isinstance(val, str):
                return val
    except Exception:
        pass
    return None


def find_npx_workspace_executable(tool, cwd, workspace_paths):
    """Check if npx would resolve tool to a workspace-controlled executable."""
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    try:
        curr = Path(effective_cwd).resolve()
    except Exception:
        curr = Path(effective_cwd)
    ws_roots = [Path(ws).resolve() for ws in (workspace_paths or [effective_cwd])]

    while True:
        candidate = curr / 'node_modules' / '.bin' / tool
        if candidate.is_file() or candidate.is_symlink():
            try:
                norm_cand = str(candidate.resolve())
            except Exception:
                norm_cand = str(candidate)
            if is_path_in_workspaces(norm_cand, workspace_paths, effective_cwd) or is_path_in_workspaces(str(candidate), workspace_paths, effective_cwd):
                return str(candidate)
        if any(curr == ws for ws in ws_roots) or curr.parent == curr:
            break
        curr = curr.parent

    # Also check if tool in PATH resolves to a workspace-controlled executable
    res = shutil.which(tool)
    if res:
        norm_res = expand_path(res, effective_cwd)
        if is_path_in_workspaces(norm_res, workspace_paths, effective_cwd):
            return res
    return None


def split_unquoted_shell_commands(cmd_str):
    """Split a shell command line string into individual subcommand strings on unquoted operators.

    Operators recognized as command separators:
    '&&', '||', '|&', ';', '\\n', '|', '&'
    Redirections involving '&' (e.g. '&>', '&>>', '>&', '<&') are preserved within the subcommand.
    Returns (subcommands, pipeline_links) where:
      - subcommands is a list of stripped subcommand strings
      - pipeline_links is a list of tuples: (subcommand_index, operator)
    Returns (None, None) on syntax errors, unclosed quotes, or dangling operators.
    """
    in_single_quote = False
    in_double_quote = False
    escaped = False
    subcommands = []
    pipeline_links = []
    current_chars = []

    i = 0
    n = len(cmd_str)
    expect_command = False

    while i < n:
        c = cmd_str[i]
        if escaped:
            current_chars.append(c)
            escaped = False
            i += 1
            continue

        # Line continuation: \\ followed immediately by \\n
        if c == '\\' and i + 1 < n and cmd_str[i + 1] == '\n':
            i += 2
            continue

        if c == '\\':
            if in_single_quote:
                current_chars.append(c)
            elif in_double_quote:
                if i + 1 < n and cmd_str[i + 1] in ('"', '\\', '$', '`', '\n'):
                    escaped = True
                    current_chars.append(c)
                else:
                    current_chars.append(c)
            else:
                escaped = True
                current_chars.append(c)
            i += 1
            continue

        if c == "'":
            if not in_double_quote:
                in_single_quote = not in_single_quote
            current_chars.append(c)
            i += 1
            continue

        if c == '"':
            if not in_single_quote:
                in_double_quote = not in_double_quote
            current_chars.append(c)
            i += 1
            continue

        if not in_single_quote and not in_double_quote:
            # Comment check: unquoted # preceded by start of line/command or whitespace/separator
            if c == '#' and (i == 0 or cmd_str[i - 1].isspace() or cmd_str[i - 1] in (';', '&', '|')):
                while i < n and cmd_str[i] != '\n':
                    i += 1
                continue

            two = cmd_str[i:i + 2]
            if two == ';;':
                return None, None

            if two in ('&&', '||', '|&'):
                sub_str = ''.join(current_chars).strip()
                if not sub_str:
                    return None, None
                subcommands.append(sub_str)
                if two == '|&':
                    pipeline_links.append((len(subcommands) - 1, '|&'))
                current_chars = []
                expect_command = True
                i += 2
                continue

            # Redirections with &: &>, &>>, >&, <&
            if two in ('&>',):
                current_chars.append(two)
                i += 2
                continue
            if i > 0 and cmd_str[i - 1] in ('>', '<') and c == '&':
                current_chars.append(c)
                i += 1
                continue

            if c in (';', '\n', '|', '&'):
                sub_str = ''.join(current_chars).strip()
                if not sub_str and c in ('|', ';', '&'):
                    return None, None
                if sub_str:
                    subcommands.append(sub_str)
                    if c == '|':
                        pipeline_links.append((len(subcommands) - 1, '|'))
                current_chars = []
                expect_command = (c in ('|',))
                i += 1
                continue

        current_chars.append(c)
        i += 1

    rem = ''.join(current_chars).strip()
    if rem:
        subcommands.append(rem)
    elif expect_command:
        return None, None

    if in_single_quote or in_double_quote or escaped:
        return None, None

    return subcommands, pipeline_links


def tokenize_subcommand(subcmd_str):
    """Tokenize a single shell subcommand using POSIX tokenization rules."""
    try:
        s = shlex.shlex(subcmd_str, posix=True, punctuation_chars=True)
        s.whitespace_split = True
        s.commenters = ''
        return list(s)
    except Exception:
        return None


def parse_refspec_dest(refspec):
    """Extract the destination branch name from a git refspec."""
    spec = refspec.lstrip('+')
    if ':' in spec:
        dest = spec.split(':', 1)[1]
    else:
        dest = spec
    dest = re.sub(r'^refs/(heads|remotes/[^/]+)/', '', dest)
    return dest


def classify_subcommand(tokens, workspace_paths, cwd, depth=0):
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
        tok = tokens[idx]
        var_name, val = tok.split('=', 1)
        if is_dangerous_env_var(var_name):
            return 'deny', f"Setting execution-altering environment variable is forbidden: {var_name}"
        if is_credential_var_name(var_name) or is_credential_env_var(tok):
            return 'deny', f"Environment assignment referencing credentials is forbidden: {var_name}"
        if var_name not in SAFE_INLINE_ENV_VARS:
            return 'ask', f"Command with inline environment variable assignment requires confirmation: {tok}"
        if not re.match(r'^[A-Za-z0-9_.:+-]*$', val):
            return 'ask', f"Command with complex environment variable assignment requires confirmation: {tok}"
        idx += 1

    cmd_tokens = tokens[idx:]
    if not cmd_tokens:
        return 'ask', f"Standalone environment assignment requires confirmation: {' '.join(tokens)}"

    raw_cmd = unquote_token(cmd_tokens[0])

    # Extract redirections and build unquoted arguments
    filtered_args = []
    skip_next_arg = False
    for i, tok in enumerate(cmd_tokens[1:]):
        if skip_next_arg:
            skip_next_arg = False
            continue
        if tok in REDIRECTION_OPERATORS:
            skip_next_arg = True
            if i + 1 < len(cmd_tokens[1:]):
                target = unquote_token(cmd_tokens[1:][i + 1])
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
            continue
        filtered_args.append(unquote_token(tok))
    args = filtered_args

    # Resolve executable: prevent ./malicious/ls or workspace/untrusted PATH overrides
    if '/' in raw_cmd:
        resolved_exe = expand_path(raw_cmd, cwd)
        if not is_trusted_executable_path(resolved_exe, workspace_paths, cwd):
            return 'force_ask', f"Running non-system executable requires confirmation: {raw_cmd}"
        base_cmd = os.path.basename(resolved_exe)
    else:
        resolved_path = shutil.which(raw_cmd)
        if resolved_path:
            if not is_trusted_executable_path(resolved_path, workspace_paths, cwd):
                return 'force_ask', f"Running untrusted or shadowed executable requires confirmation: {raw_cmd} ({resolved_path})"
        base_cmd = raw_cmd

    # Check for sensitive files or credentials being targeted in arguments
    # Skip known text payloads (e.g. git commit messages, grep search patterns)
    skip_next = False
    for i, arg in enumerate(args):
        if skip_next:
            skip_next = False
            continue
        # For git commit/tag, skip the commit message string operand
        if base_cmd == 'git' and any(sub in args for sub in ('commit', 'tag')):
            if arg in ('-m', '--message'):
                skip_next = True
                continue
            if arg.startswith(('-m', '--message=')):
                continue
        # For grep / rg / ag, skip the search pattern operand
        if base_cmd in {'grep', 'egrep', 'fgrep', 'rg', 'ag'}:
            has_pat_flag = any(a in ('-e', '-f', '--regexp', '--file') or a.startswith(('-e', '-f', '--regexp=', '--file=')) for a in args)
            consumed_tokens = set()
            for idx_a, val_a in enumerate(args):
                if val_a in ('-e', '-f', '--regexp', '--file') and idx_a + 1 < len(args):
                    consumed_tokens.add(args[idx_a + 1])
            positionals = [a for a in args if not a.startswith('-') and a not in consumed_tokens]
            if not has_pat_flag and positionals and arg == positionals[0]:
                continue
        if is_credential_env_var(arg):
            return 'deny', f"Access to credential environment variable is forbidden: {arg}"
        val = arg.split('=', 1)[1] if arg.startswith('--') and '=' in arg else arg
        if val != '/dev/null' and is_sensitive_credential_path(val, cwd):
            return 'deny', f"Access to sensitive credential or key is forbidden: {arg}"
        if arg.startswith('-') and not arg.startswith('--') and any(c in arg for c in ('o', 't')):
            for flag in ('o', 't'):
                if flag in arg:
                    sub_val = arg[arg.index(flag) + 1:].lstrip('=')
                    if sub_val and sub_val != '/dev/null' and is_sensitive_credential_path(sub_val, cwd):
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
        is_recursive = any(
            a in ('-r', '-R', '-rf', '-fr') or
            (a.startswith('-') and not a.startswith('--') and any(c in a for c in ('r', 'R'))) or
            (a.startswith('--') and '--recursive'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 3)
            for a in args
        )
        is_dir = any(
            a in ('-d',) or
            (a.startswith('-') and not a.startswith('--') and 'd' in a) or
            (a.startswith('--') and '--dir'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 3)
            for a in args
        )
        targets = [a for a in args if not a.startswith('-')]
        if is_recursive or is_dir:
            for t in targets:
                t_norm = expand_path(t, cwd)
                if t in ('/', '/*', '~', '~/*', '$HOME') or t_norm in ('/', expand_path('~', cwd)):
                    return 'deny', f"Recursive deletion targeting root or home directory is forbidden: rm {t}"
                for ws in (workspace_paths or [cwd]):
                    ws_norm = expand_path(ws, cwd)
                    if t_norm == ws_norm:
                        return 'deny', f"Recursive deletion of entire workspace root is forbidden: rm {t}"
            return 'force_ask', f"Recursive or directory deletion requires confirmation: {' '.join(cmd_tokens)}"
        # Non-recursive rm on individual files inside workspace
        if targets and all(is_path_in_workspaces(t, workspace_paths, cwd) and not is_sensitive_credential_path(t, cwd) and not is_git_admin_path(t, cwd) for t in targets):
            return 'allow', f"Safe workspace file deletion: {' '.join(cmd_tokens)}"
        return 'force_ask', f"File deletion requires confirmation: {' '.join(cmd_tokens)}"

    # 5. Git Operations
    if base_cmd == 'git':
        if not args:
            return 'allow', 'git command query'

        git_sub = None
        git_sub_idx = -1
        skip_next = False
        for idx, a in enumerate(args):
            if skip_next:
                skip_next = False
                continue
            if a in ('-C', '--git-dir', '--work-tree', '--namespace', '-c', '--config-env'):
                skip_next = True
                continue
            if a.startswith(('-C', '--git-dir=', '--work-tree=', '--namespace=', '-c', '--config-env=')):
                continue
            if not a.startswith('-'):
                git_sub = a
                git_sub_idx = idx
                break

        if not git_sub:
            return 'allow', 'git command query'

        sub_args = args[git_sub_idx:]

        # Check for git output options across all git commands (including GNU option abbreviations)
        git_out = None
        for i, a in enumerate(args):
            if a.startswith('--o') and '=' in a:
                opt, val = a.split('=', 1)
                if '--output'.startswith(opt) or '--output-directory'.startswith(opt):
                    git_out = val
            elif a.startswith('--o') and ('--output'.startswith(a) or '--output-directory'.startswith(a)):
                if i + 1 < len(args):
                    git_out = args[i + 1]
            elif a in ('--output', '-o', '--output-directory') and i + 1 < len(args):
                git_out = args[i + 1]
            elif a.startswith('-o') and len(a) > 2 and not a.startswith('--'):
                git_out = a[2:].lstrip('=')
        if git_out:
            if is_sensitive_credential_path(git_out, cwd) or is_system_write_path(git_out, cwd):
                return 'deny', f"git {git_sub} --output targeting sensitive or system path is forbidden: {git_out}"
            if is_git_admin_path(git_out, cwd):
                return 'force_ask', f"git {git_sub} --output targeting git administrative file requires confirmation: {git_out}"
            if not is_path_in_workspaces(git_out, workspace_paths, cwd):
                return 'force_ask', f"git {git_sub} --output outside workspace requires approval: {git_out}"

        # Check for config overrides via -c or --config-env setting transport, helper, or filter programs
        for i, a in enumerate(args):
            cfg_opt = None
            if a in ('-c', '--config-env') and i + 1 < len(args):
                cfg_opt = args[i + 1]
            elif a.startswith('-c') and len(a) > 2 and not a.startswith('--'):
                cfg_opt = a[2:].lstrip('=')
            if cfg_opt:
                cfg_key = cfg_opt.split('=', 1)[0].strip().lower()
                if re.match(r'^(core\.sshcommand|core\.askpass|core\.pager|credential|remote\..*\.(vcs|uploadpack|receivepack|proxy)|http\..*proxy|diff\..*\.command|filter\..*\.clean|filter\..*\.smudge)', cfg_key):
                    return 'force_ask', f"Git command with configuration override requires confirmation: git -c {cfg_opt}"

        # External diff/textconv drivers can execute arbitrary commands configured in gitconfig/attributes
        for a in args:
            if a in ('--ext-diff', '--textconv') or a.startswith(('--ext-diff=', '--textconv=')):
                return 'force_ask', f"Git command with external diff/filter driver requires confirmation: {' '.join(cmd_tokens)}"

        # Git upload-pack, receive-pack, or exec options can run arbitrary executables
        for a in args:
            if a in ('--upload-pack', '--receive-pack', '--exec') or a.startswith(('--upload-pack=', '--receive-pack=', '--exec=')):
                return 'force_ask', f"Git command with custom remote pack/exec program requires confirmation: {' '.join(cmd_tokens)}"
            if a in ('-u',) and git_sub in {'clone', 'fetch', 'ls-remote'}:
                return 'force_ask', f"Git command with custom upload-pack option (-u) requires confirmation: {' '.join(cmd_tokens)}"

        # Configured core.pager or pager.<cmd> can execute arbitrary commands
        if git_sub in {'log', 'show', 'diff', 'blame', 'shortlog', 'whatchanged', 'reflog', 'branch'}:
            has_no_pager = any(a in ('--no-pager', '-P') for a in tokens)
            if not has_no_pager and git_has_pager_configured(cwd, git_sub):
                return 'force_ask', f"git {git_sub} with configured pager requires confirmation: {' '.join(cmd_tokens)}"

        # Check git arguments for sensitive file paths or <rev>:<path> expressions targeting sensitive files
        for a in args:
            clean_a = a.split(':', 1)[1] if (':' in a and not a.startswith(('http:', 'https:', 'ssh:', 'git:'))) else a
            if not clean_a.startswith('-') and (matches_sensitive_pattern(clean_a) or is_sensitive_credential_path(clean_a, cwd)):
                return "deny", "Forbidden sensitive path"
        # Subcommand-specific evaluation operates on sub_args where sub_args[0] is git_sub
        args = sub_args

        # Force push or direct push to protected branch detection
        if git_sub == 'push':
            has_force = any(a in ('--force', '-f', '--force-with-lease') or a.startswith('+') for a in args)
            has_repo_opt = any(a == '--repo' or a.startswith('--repo=') for a in args)
            pos_args = []
            skip_next = False
            for i, a in enumerate(args[1:], start=1):
                if skip_next:
                    skip_next = False
                    continue
                if a == '--':
                    pos_args.extend(args[i + 1:])
                    break
                if a.startswith('-'):
                    if a in ('--repo', '--receive-pack', '--exec', '-o', '--push-option') and i + 1 < len(args):
                        skip_next = True
                    continue
                pos_args.append(a)

            if has_repo_opt:
                refspecs = pos_args
            elif len(pos_args) > 1:
                refspecs = pos_args[1:]
            else:
                refspecs = []

            for spec in refspecs:
                dest = parse_refspec_dest(spec)
                if dest in PROTECTED_BRANCHES:
                    return 'deny', f"Push targeting protected branch '{dest}' is forbidden: {' '.join(cmd_tokens)}"
            if not refspecs:
                curr_branch = git_get_current_branch(cwd)
                if curr_branch in PROTECTED_BRANCHES:
                    return 'deny', f"Push targeting protected branch '{curr_branch}' is forbidden: {' '.join(cmd_tokens)}"
            if any(a == '--mirror' for a in args):
                return 'deny', f"Push with --mirror can overwrite protected remote branches: {' '.join(cmd_tokens)}"
            if any(a == '--all' for a in args):
                local_protected = git_get_local_protected_branches(cwd)
                if local_protected:
                    return 'deny', f"Push with --all pushes protected branch '{local_protected[0]}' to remote: {' '.join(cmd_tokens)}"
            if has_force:
                if not refspecs:
                    return 'deny', f"Unscoped force push is forbidden: {' '.join(cmd_tokens)}"
                return 'force_ask', f"Force push requires confirmation: {' '.join(cmd_tokens)}"
            return 'force_ask', f"Git push modifies remote repository: {' '.join(cmd_tokens)}"

        # Fetch with refspecs or custom transport helpers: can overwrite local branch references or run programs
        if git_sub == 'fetch':
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git fetch in directory outside workspace requires confirmation: {cwd}"
            if git_has_transport_executable_configured(cwd):
                return 'force_ask', f"Git fetch with configured transport program or credential helper requires confirmation: {' '.join(cmd_tokens)}"
            if git_remotes_have_executable_helpers(cwd):
                return 'force_ask', f"Git fetch with configured remote helper URL or rewrite requires confirmation: {' '.join(cmd_tokens)}"
            if any(a in ('-u', '--upload-pack') or a.startswith(('-u=', '--upload-pack=')) for a in args):
                return 'force_ask', f"Git fetch with custom upload-pack program requires confirmation: {' '.join(cmd_tokens)}"

            # Inspect positional arguments (remote / URL / refspecs)
            pos_args = [a for a in args[1:] if not a.startswith('-')]
            for a in pos_args:
                if is_unsafe_git_remote_url(a):
                    return 'force_ask', f"Git fetch with custom remote helper protocol or scheme requires confirmation: {a}"
                # If a is a remote name or URL, check its resolved URL via ls-remote --get-url
                res_resolved = git_run_probe(['ls-remote', '--get-url', a], cwd=cwd)
                if res_resolved and res_resolved.returncode == 0 and res_resolved.stdout.strip():
                    expanded = res_resolved.stdout.strip()
                    if is_unsafe_git_remote_url(expanded):
                        return 'force_ask', f"Git fetch with rewritten remote helper URL requires confirmation: {expanded}"

            refspecs = [a for a in pos_args if a != 'origin']
            if refspecs or any(a.startswith('+') for a in args):
                return 'force_ask', f"Git fetch with refspecs requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git fetch'

        # Destructive or state-discarding git commands
        if git_sub in {'clean', 'reset', 'restore'}:
            return 'force_ask', f"Git {git_sub} alters working tree: {' '.join(cmd_tokens)}"

        # Git checkout: disallow file checkouts (which discard changes) and forced checkouts
        if git_sub == 'checkout':
            return 'force_ask', f"Git checkout requires confirmation: {' '.join(cmd_tokens)}"

        # Git switch: only allow without discarding changes or creating/resetting branches
        if git_sub == 'switch':
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git switch in directory outside workspace requires confirmation: {cwd}"
            SAFE_SWITCH_FLAGS = {'-q', '--quiet', '--progress', '--guess', '--no-guess', '--ignore-other-worktrees', '--'}
            for a in args[1:]:
                if a.startswith('-') and a != '-' and a not in SAFE_SWITCH_FLAGS:
                    return 'force_ask', f"Switching with option requires confirmation: {' '.join(cmd_tokens)}"
            positionals = [a for a in args[1:] if not a.startswith('-') or a == '-']
            if len(positionals) != 1:
                return 'force_ask', f"Git switch requires explicit branch target: {' '.join(cmd_tokens)}"
            if git_has_active_hooks(cwd, ('post-checkout',)):
                return 'force_ask', f"git switch with active repository hook (post-checkout) requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_filter_configured(cwd):
                return 'force_ask', f"git switch with configured filter driver requires confirmation: {' '.join(cmd_tokens)}"
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
                    return 'force_ask', f"Mutating branches requires confirmation: {' '.join(cmd_tokens)}"
                if any(a.startswith(opt + '=') for opt in MUTATING_BRANCH_FLAGS if opt.startswith('--')):
                    return 'force_ask', f"Mutating branches requires confirmation: {' '.join(cmd_tokens)}"
                if any(a.startswith(opt) for opt in MUTATING_BRANCH_FLAGS if not opt.startswith('--')):
                    return 'force_ask', f"Mutating branches requires confirmation: {' '.join(cmd_tokens)}"
            positionals = [a for a in args[1:] if not a.startswith('-')]
            # Positional arguments in git branch create/reset branches unless --list is explicitly used
            # Note: -l means --create-reflog when creating a branch, so only --list is safe with positionals
            if positionals and not any(a == '--list' or a.startswith('--list=') for a in args):
                return 'force_ask', f"Branch creation or modification requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git branch query'

        # Git tag: only allow listing
        if git_sub == 'tag':
            if any(a in ('-d', '--delete', '-a', '-f', '--force', '-m', '-s', '-u') for a in args):
                return 'force_ask', f"Creating or deleting tags requires confirmation: {' '.join(cmd_tokens)}"
            positionals = [a for a in args[1:] if not a.startswith('-')]
            if positionals and not any(a in ('-l', '--list') for a in args):
                return 'force_ask', f"Creating tags requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git tag query'

        # Git remote: only allow read queries that do not expose credentials or invoke transport programs
        if git_sub == 'remote':
            if any(a in ('add', 'rename', 'remove', 'rm', 'set-head', 'set-branches', 'set-url', 'update', 'prune') for a in args):
                return 'force_ask', f"Mutating git remotes requires confirmation: {' '.join(cmd_tokens)}"
            if any(a == 'show' for a in args):
                return 'force_ask', f"git remote show contacts remote and may execute transport/credential programs: {' '.join(cmd_tokens)}"
            if git_has_transport_executable_configured(cwd):
                return 'force_ask', f"git remote query with configured transport program requires confirmation: {' '.join(cmd_tokens)}"
            if git_remotes_have_executable_helpers(cwd):
                return 'force_ask', f"git remote query with configured remote helper URL requires confirmation: {' '.join(cmd_tokens)}"
            if any(a in ('-v', '--verbose', 'get-url') or a.startswith(('--verbose', 'get-url')) for a in args):
                if git_remotes_have_credentials(cwd):
                    return 'deny', f"git remote query exposing embedded credentials in remote URL is forbidden: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git remote query'

        # Git commands that inspect or refresh the index/working tree execute core.fsmonitor if configured
        if git_sub in {'status', 'diff', 'ls-files', 'stash', 'add', 'commit', 'checkout', 'restore', 'reset', 'worktree', 'describe'}:
            has_no_fsmonitor = any(a == '--no-optional-locks' for a in tokens)
            if not has_no_fsmonitor and git_has_fsmonitor_configured(cwd):
                return 'force_ask', f"git {git_sub} with configured core.fsmonitor hook requires confirmation: {' '.join(cmd_tokens)}"

        # Git diff
        if git_sub == 'diff':
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git diff in directory outside workspace requires confirmation: {cwd}"
            has_no_ext = any(a == '--no-ext-diff' for a in args)
            has_no_textconv = any(a == '--no-textconv' for a in args)
            if (not has_no_ext or not has_no_textconv) and git_has_external_diff_configured(cwd):
                return 'force_ask', f"git diff with configured external diff/textconv driver requires confirmation: {' '.join(cmd_tokens)}"

            # Inspect file operands and pathspecs for sensitive files and workspace containment
            is_no_index = any(a == '--no-index' for a in args)
            diff_operands = []
            if '--' in args:
                idx = args.index('--')
                diff_operands.extend(args[idx + 1:])
                pre_dash = args[1:idx]
            else:
                pre_dash = args[1:]

            if is_no_index:
                diff_operands.extend([a for a in pre_dash if not a.startswith('-')])
            else:
                for a in pre_dash:
                    if not a.startswith('-'):
                        if a.startswith(('/', '~')) or a.startswith('..' + os.sep) or a == '..':
                            diff_operands.append(a)

            for dop in diff_operands:
                if dop in ('/dev/null', 'NUL'):
                    continue
                if matches_sensitive_pattern(dop) or is_sensitive_credential_path(dop, cwd):
                    return 'deny', f"git diff targeting sensitive file is forbidden: {dop}"
                if not is_path_in_workspaces(dop, workspace_paths, cwd):
                    return 'force_ask', f"git diff operand outside workspace requires approval: {dop}"

            probe_res = git_command_touches_sensitive_files(git_sub, args, cwd)
            if probe_res == 'sensitive':
                return 'deny', f"git diff touching sensitive credential files in patch output is forbidden: {' '.join(cmd_tokens)}"
            if probe_res == 'unknown':
                return 'force_ask', f"git diff patch cannot be verified safely: {' '.join(cmd_tokens)}"
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
                        return 'force_ask', f"git stash show with configured external diff/textconv driver requires confirmation: {' '.join(cmd_tokens)}"
                    probe_res = git_command_touches_sensitive_files('stash', args, cwd)
                    if probe_res == 'sensitive':
                        return 'deny', f"git stash show touching sensitive credential files in patch output is forbidden: {' '.join(cmd_tokens)}"
                    if probe_res == 'unknown':
                        return 'force_ask', f"git stash show patch cannot be verified safely: {' '.join(cmd_tokens)}"
                    return 'allow', 'Safe git stash show'
            return 'force_ask', f"Git stash modification requires confirmation: {' '.join(cmd_tokens)}"

        if git_sub == 'worktree':
            if any(a in ('add', 'remove', 'prune', 'lock', 'unlock', 'move', 'repair') for a in args):
                if 'add' in args:
                    if any(a in ('-B', '-f', '--force') or a.startswith(('-B', '-f', '--force')) for a in args):
                        return 'force_ask', f"git worktree add with branch reset or force requires confirmation: {' '.join(cmd_tokens)}"
                    if git_has_active_hooks(cwd, ('post-checkout',)):
                        return 'force_ask', f"git worktree add with active repository hook (post-checkout) requires confirmation: {' '.join(cmd_tokens)}"
                    if git_has_filter_configured(cwd):
                        return 'force_ask', f"git worktree add with configured filter driver requires confirmation: {' '.join(cmd_tokens)}"
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
                            return 'force_ask', f"git worktree add outside workspace requires approval: {target_dir}"
                    return 'allow', 'Safe git worktree add within workspace'
                return 'force_ask', f"Git worktree modification requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git worktree query'

        # Git show, log, blame, etc. run configured textconv drivers or signature verification by default
        if git_sub in {'show', 'log', 'blame', 'whatchanged', 'format-patch'}:
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git {git_sub} in directory outside workspace requires confirmation: {cwd}"
            has_sig = any(a == '--show-signature' or a.startswith(('--show-sig', '--show-signature=')) or
                          (a.startswith(('--format=', '--pretty=')) and any(g in a for g in ('%G', '%g'))) for a in args)
            if has_sig:
                return 'force_ask', f"git {git_sub} with signature display invokes external gpg program: {' '.join(cmd_tokens)}"
            if git_has_gpg_program_configured(cwd) and any(a.startswith(('--format=', '--pretty=')) for a in args):
                return 'force_ask', f"git {git_sub} with formatted output and custom gpg.program requires confirmation: {' '.join(cmd_tokens)}"
            has_no_textconv = any(a == '--no-textconv' for a in args)
            if not has_no_textconv and git_has_external_diff_configured(cwd):
                return 'force_ask', f"git {git_sub} with configured external diff/textconv driver requires confirmation: {' '.join(cmd_tokens)}"

            if git_sub == 'blame':
                # Check --contents <file>
                blame_contents = None
                for i, a in enumerate(args):
                    if a == '--contents' and i + 1 < len(args):
                        blame_contents = args[i + 1]
                    elif a.startswith('--contents='):
                        blame_contents = a.split('=', 1)[1]
                if blame_contents is not None:
                    if blame_contents == '-':
                        return 'force_ask', f"git blame reading contents from stdin requires confirmation: {' '.join(cmd_tokens)}"
                    if matches_sensitive_pattern(blame_contents) or is_sensitive_credential_path(blame_contents, cwd):
                        return 'deny', f"git blame targeting sensitive contents file is forbidden: {blame_contents}"
                    if not is_path_in_workspaces(blame_contents, workspace_paths, cwd):
                        return 'force_ask', f"git blame contents file outside workspace requires approval: {blame_contents}"

                # Check positional file operands and pathspecs
                blame_operands = []
                if '--' in args:
                    idx = args.index('--')
                    blame_operands.extend(args[idx + 1:])
                    pre_dash = args[1:idx]
                else:
                    pre_dash = args[1:]
                for a in pre_dash:
                    if not a.startswith('-'):
                        blame_operands.append(a)
                for bop in blame_operands:
                    if matches_sensitive_pattern(bop) or is_sensitive_credential_path(bop, cwd):
                        return 'deny', f"git blame targeting sensitive file is forbidden: {bop}"
                    if bop.startswith(('/', '~')) or bop.startswith('..' + os.sep) or bop == '..':
                        if not is_path_in_workspaces(bop, workspace_paths, cwd):
                            return 'force_ask', f"git blame operand outside workspace requires approval: {bop}"

            is_blob_show = git_sub == 'show' and any(':' in a and not a.startswith(('-', 'http:', 'https:', 'ssh:', 'git:')) for a in args[1:])
            if is_blob_show:
                for a in args[1:]:
                    if ':' in a and not a.startswith('-'):
                        obj_path = a.split(':', 1)[1]
                        if matches_sensitive_pattern(obj_path) or is_sensitive_credential_path(obj_path, cwd):
                            return 'deny', f"git show targeting sensitive object is forbidden: {a}"
                        if obj_path.startswith(('/', '~')) or '..' in obj_path.split('/'):
                            if not is_path_in_workspaces(obj_path, workspace_paths, cwd):
                                return 'force_ask', f"git show object path outside workspace requires approval: {a}"
            else:
                if git_sub != 'blame':
                    probe_res = git_command_touches_sensitive_files(git_sub, args, cwd)
                    if probe_res == 'sensitive':
                        return 'deny', f"git {git_sub} touching sensitive credential files in patch output is forbidden: {' '.join(cmd_tokens)}"
                    if probe_res == 'unknown':
                        return 'force_ask', f"git {git_sub} patch cannot be verified safely: {' '.join(cmd_tokens)}"

        # Git cat-file with batch modes, filters, textconv, or sensitive objects
        if git_sub == 'cat-file':
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git cat-file in directory outside workspace requires confirmation: {cwd}"
            if any(a in ('--batch', '--batch-check', '--batch-command', '--batch-all-objects') or 
                   a.startswith(('--batch=', '--batch-check=', '--batch-command=')) for a in args):
                return 'force_ask', f"git cat-file batch mode reads arbitrary objects from stdin or repository history: {' '.join(cmd_tokens)}"
            if any(a.startswith(('--filters', '--textconv', '--path=')) or a in ('--filters', '--textconv') for a in args):
                return 'force_ask', f"git cat-file with filter or textconv driver requires confirmation: {' '.join(cmd_tokens)}"
            for a in args[1:]:
                if not a.startswith('-'):
                    if ':' in a:
                        obj_path = a.split(':', 1)[1]
                        if matches_sensitive_pattern(obj_path) or is_sensitive_credential_path(obj_path, cwd):
                            return 'deny', f"git cat-file targeting sensitive object is forbidden: {a}"
                    elif re.match(r'^[0-9a-fA-F]{7,64}$', a):
                        return 'force_ask', f"Reading raw git object by hash can disclose sensitive repository history: {a}"
                    elif matches_sensitive_pattern(a) or is_sensitive_credential_path(a, cwd):
                        return 'deny', f"git cat-file targeting sensitive object is forbidden: {a}"
            return 'allow', 'Safe git cat-file query'

        if git_sub == 'rev-list':
            if any(a == '--objects' or a.startswith('--objects') for a in args):
                return 'force_ask', f"git rev-list --objects can list all repository history objects: {' '.join(cmd_tokens)}"

        if git_sub in SAFE_GIT_READ_SUBCOMMANDS:
            return 'allow', f"Safe git read query: git {git_sub}"

        if git_sub == 'config':
            if any(a in ('--list', '-l', '--get-regexp') or a.startswith(('--list', '--get-regexp=')) for a in args):
                return 'force_ask', f"Listing all git configuration may disclose credentials or tokens: {' '.join(cmd_tokens)}"
            # Check for sensitive config keys
            for a in args[1:]:
                clean_key = a.lower()
                if any(k in clean_key for k in ('header', 'token', 'secret', 'key', 'pass', 'auth', 'cred', 'cookie', 'proxy', 'extraheader')):
                    return 'deny', f"git config targeting sensitive credential key is forbidden: {a}"
            if any(a in ('--get', '--get-all') for a in args) or (len(args) == 2 and not args[1].startswith('-')):
                return 'allow', 'Safe git config query'
            return 'force_ask', 'Git config modification requires confirmation'

        if git_sub == 'add':
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git add in directory outside workspace requires confirmation: {cwd}"
            if any(a in ('-e', '--edit') for a in args):
                return 'force_ask', f"git add with -e/--edit invokes editor: {' '.join(cmd_tokens)}"
            if any(a in ('-f', '--force') for a in args):
                return 'force_ask', f"git add with --force can stage ignored sensitive files: {' '.join(cmd_tokens)}"
            if git_has_active_hooks(cwd, ('post-index-change',)):
                return 'force_ask', f"git add with active repository hook (post-index-change) requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_filter_configured(cwd):
                return 'force_ask', f"git add with configured filter driver requires confirmation: {' '.join(cmd_tokens)}"

            # Check individual positional arguments
            for a in args[1:]:
                if not a.startswith('-') and a not in ('.', '*', ':/'):
                    if is_sensitive_credential_path(a, cwd) or matches_sensitive_pattern(a):
                        return 'deny', f"git add targeting sensitive file is forbidden: {a}"

            # Check broad staging (e.g. git add ., git add -A, git add --all, git add -u, git add *)
            is_broad = any(a in ('.', '*', '-A', '--all', '-u', '--update', ':/') for a in args[1:])
            if is_broad:
                probe_res = git_probe_uncommitted_sensitive_files(cwd)
                if probe_res == 'sensitive':
                    return 'deny', f"git add would stage sensitive credential files: {' '.join(cmd_tokens)}"
                if probe_res == 'unknown':
                    return 'force_ask', f"git add cannot safely verify files to be staged: {' '.join(cmd_tokens)}"

            return 'allow', 'Safe git add'

        if git_sub == 'commit':
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git commit in directory outside workspace requires confirmation: {cwd}"
            has_no_edit = any(a == '--no-edit' for a in args)
            has_edit_flag = any(a in ('-e', '--edit', '-t', '--template', '-c', '--reedit-message') or
                                a.startswith(('-e=', '--edit=', '-t=', '--template=', '-c=', '--reedit-message=')) for a in args)
            if has_edit_flag and not has_no_edit:
                return 'force_ask', f"git commit with editor invocation requires confirmation: {' '.join(cmd_tokens)}"
            has_inline_msg = any(a in ('-m', '--message') or a.startswith(('-m=', '--message=')) for a in args)
            commit_file_args = []
            for i, a in enumerate(args):
                if a in ('-F', '--file'):
                    if i + 1 < len(args):
                        commit_file_args.append(args[i + 1])
                elif a.startswith(('--file=', '-F=')):
                    commit_file_args.append(a.split('=', 1)[1])
                elif a.startswith('-F') and len(a) > 2 and not a.startswith('--'):
                    commit_file_args.append(a[2:])

            if commit_file_args:
                for cf in commit_file_args:
                    if cf == '-':
                        return 'force_ask', f"git commit reading message from stdin requires confirmation: {' '.join(cmd_tokens)}"
                    if matches_sensitive_pattern(cf) or is_sensitive_credential_path(cf, cwd):
                        return 'deny', f"git commit message file targeting sensitive or credential file is forbidden: {cf}"
                    if not is_path_in_workspaces(cf, workspace_paths, cwd):
                        return 'force_ask', f"git commit message file outside workspace requires approval: {cf}"

            if not has_inline_msg and not commit_file_args:
                return 'force_ask', f"git commit without message requires confirmation: {' '.join(cmd_tokens)}"
            has_sign = any(a in ('-S', '--gpg-sign') or a.startswith(('-S', '--gpg-sign=')) for a in args)
            has_no_sign = any(a == '--no-gpg-sign' for a in args)
            if (has_sign or git_has_gpgsign_configured(cwd)) and not has_no_sign:
                return 'force_ask', f"git commit with GPG signing invokes external gpg program: {' '.join(cmd_tokens)}"
            if any(a in ('--amend', '--fixup', '--squash', '--reset-author') or a.startswith(('--amend', '--fixup=', '--squash=')) for a in args):
                return 'force_ask', f"git commit with history rewriting requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_active_hooks(cwd, ('pre-commit', 'prepare-commit-msg', 'commit-msg', 'post-commit')):
                return 'force_ask', f"git commit with active repository hook requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_filter_configured(cwd):
                return 'force_ask', f"git commit with configured filter driver requires confirmation: {' '.join(cmd_tokens)}"

            # Check --pathspec-from-file
            pathspec_files = []
            for i, a in enumerate(args):
                if a == '--pathspec-from-file' and i + 1 < len(args):
                    pathspec_files.append(args[i + 1])
                elif a.startswith('--pathspec-from-file='):
                    pathspec_files.append(a.split('=', 1)[1])

            has_pathspec = bool(pathspec_files)
            for pf in pathspec_files:
                if pf == '-':
                    return 'force_ask', f"git commit reading pathspecs from stdin requires confirmation: {' '.join(cmd_tokens)}"
                if matches_sensitive_pattern(pf) or is_sensitive_credential_path(pf, cwd):
                    return 'deny', f"git commit pathspec file targeting sensitive or credential file is forbidden: {pf}"
                if not is_path_in_workspaces(pf, workspace_paths, cwd):
                    return 'force_ask', f"git commit pathspec file outside workspace requires approval: {pf}"
                pf_resolved = expand_path(pf, cwd)
                if os.path.isfile(pf_resolved):
                    try:
                        content = Path(pf_resolved).read_text(errors='replace')
                        delim = '\0' if any(a == '--pathspec-file-nul' for a in args) else '\n'
                        for line in content.split(delim):
                            p = line.strip()
                            if p:
                                if matches_sensitive_pattern(p) or is_sensitive_credential_path(p, cwd):
                                    return 'deny', f"git commit pathspec file references sensitive file: {p}"
                                if not is_path_in_workspaces(p, workspace_paths, cwd):
                                    return 'force_ask', f"git commit pathspec file references path outside workspace: {p}"
                    except Exception:
                        return 'force_ask', f"git commit unable to verify pathspec file: {pf}"

            # Check positional pathspecs (after options, or after --)
            commit_pathspecs = []
            if '--' in args:
                idx = args.index('--')
                commit_pathspecs.extend(args[idx + 1:])
            for a in commit_pathspecs:
                if matches_sensitive_pattern(a) or is_sensitive_credential_path(a, cwd):
                    return 'deny', f"git commit targeting sensitive pathspec is forbidden: {a}"
                if not is_path_in_workspaces(a, workspace_paths, cwd):
                    return 'force_ask', f"git commit pathspec outside workspace requires approval: {a}"
            if commit_pathspecs:
                has_pathspec = True

            # Inspect staged files to prevent committing credentials
            has_all_flag = any(a in ('-a', '--all') for a in args) or has_pathspec
            probe_res = git_probe_staged_sensitive_files(cwd, include_unstaged_tracked=has_all_flag)
            if probe_res == 'sensitive':
                return 'deny', f"git commit committing sensitive credential files is forbidden: {' '.join(cmd_tokens)}"
            if probe_res == 'unknown':
                return 'force_ask', f"git commit cannot safely verify staged files: {' '.join(cmd_tokens)}"

            return 'allow', 'Safe git commit'

    # 6. Inspection Commands
    if base_cmd in SAFE_INSPECTION_COMMANDS:
        if base_cmd == 'jq':
            if any(re.search(r'(\benv\b|(?<![A-Za-z0-9_])\$ENV\b)', a) for a in args):
                return 'deny', f"jq accessing process environment is forbidden: {' '.join(cmd_tokens)}"
            if any(a in ('-f', '--from-file') or a.startswith(('-f', '--from-file=')) for a in args):
                return 'force_ask', f"jq reading filter from file requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'file':
            if any(a in ('-C', '--compile') or (a.startswith('-') and not a.startswith('--') and 'C' in a) for a in args):
                return 'force_ask', f"file with compile option (-C/--compile) writes output and requires confirmation: {' '.join(cmd_tokens)}"
        # File inspection commands must prompt if args contain variable, command substitutions, or wildcards
        if base_cmd in {'cat', 'head', 'tail', 'less', 'more', 'wc', 'file', 'stat', 'cmp', 'uniq', 'cut', 'column', 'jq'}:
            for a in args:
                if not a.startswith('-') and any(c in a for c in ('$', '`', '*', '?', '[', ']', ';', '&', '|', '<', '>', '(', ')')):
                    return 'ask', f"Inspection command with wildcard, variable, substitution, or metacharacter requires confirmation: {' '.join(cmd_tokens)}"
            # Verify file operands are within workspace and do not target sensitive paths
            file_operands = []
            if base_cmd == 'jq':
                i = 0
                while i < len(args):
                    a = args[i]
                    if a in ('--rawfile', '--slurpfile') and i + 2 < len(args):
                        file_operands.append(args[i + 2])
                        i += 2
                    elif a.startswith(('--rawfile=', '--slurpfile=')):
                        file_operands.append(a.split('=', 1)[1])
                    i += 1
                pos = [a for a in args if not a.startswith('-')]
                if len(pos) > 1:
                    file_operands.extend(pos[1:])
            else:
                skip_val = False
                for a in args:
                    if skip_val:
                        skip_val = False
                        continue
                    if a in ('-n', '-c', '-s', '-d', '-f', '-w'):
                        skip_val = True
                        continue
                    if not a.startswith('-'):
                        file_operands.append(a)

            for f_op in file_operands:
                if f_op in ('/dev/null', '/dev/zero', '/dev/stdin', '-'):
                    continue
                if is_sensitive_credential_path(f_op, cwd):
                    return 'deny', f"Access to sensitive credential or key is forbidden: {f_op}"
                if not is_path_in_workspaces(f_op, workspace_paths, cwd):
                    return 'ask', f"Inspection command reading file outside workspace requires approval: {f_op}"
        if base_cmd in {'echo', 'printf'}:
            for a in args:
                if any(c in a for c in ('$', '`')):
                    return 'ask', f"{base_cmd} with variable expansion requires confirmation: {' '.join(cmd_tokens)}"
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

        is_recursive = any(a in ('-r', '-R', '--recursive') or (a.startswith('-') and not a.startswith('--') and any(c in a for c in ('r', 'R'))) for a in args)

        GREP_OPTS_WITH_ARG = {
            '-e', '--regexp',
            '-f', '--file',
            '-m', '--max-count',
            '-A', '--after-context',
            '-B', '--before-context',
            '-C', '--context',
            '-D', '--devices',
            '-d', '--directories',
            '--exclude', '--exclude-from', '--exclude-dir',
            '--include', '--label',
        }

        has_pattern = False
        pattern_files = []
        positionals = []
        i = 0
        while i < len(args):
            a = args[i]
            if a == '--':
                positionals.extend(args[i + 1:])
                break
            if a.startswith('--'):
                opt_name = a.split('=', 1)[0]
                val = a.split('=', 1)[1] if '=' in a else None
                if opt_name == '--file' or opt_name.startswith('--file'):
                    has_pattern = True
                    if val is not None:
                        pattern_files.append(val)
                    elif i + 1 < len(args):
                        pattern_files.append(args[i + 1])
                        i += 1
                elif opt_name == '--regexp' or opt_name.startswith('--regexp'):
                    has_pattern = True
                    if val is None and i + 1 < len(args):
                        i += 1
                elif opt_name in ('--exclude-from',):
                    if val is not None:
                        pattern_files.append(val)
                    elif i + 1 < len(args):
                        pattern_files.append(args[i + 1])
                        i += 1
                elif val is None and (opt_name in GREP_OPTS_WITH_ARG or any(long_opt.startswith(opt_name) for long_opt in GREP_OPTS_WITH_ARG if long_opt.startswith('--'))):
                    if i + 1 < len(args):
                        i += 1
                i += 1
                continue
            elif a.startswith('-') and len(a) > 1:
                flag = a[1]
                if flag == 'e':
                    has_pattern = True
                    if len(a) == 2 and i + 1 < len(args):
                        i += 1
                elif flag == 'f':
                    has_pattern = True
                    if len(a) > 2:
                        pattern_files.append(a[2:].lstrip('='))
                    elif i + 1 < len(args):
                        pattern_files.append(args[i + 1])
                        i += 1
                elif flag in ('m', 'A', 'B', 'C', 'D', 'd'):
                    if len(a) == 2 and i + 1 < len(args):
                        i += 1
                i += 1
                continue
            else:
                positionals.append(a)
                i += 1

        # Check pattern files (from -f / --file / --exclude-from)
        for pf in pattern_files:
            if pf == '-':
                continue
            if is_sensitive_credential_path(pf, cwd) or matches_sensitive_pattern(pf):
                return 'deny', f"grep pattern file targeting sensitive path is forbidden: {pf}"
            if not is_path_in_workspaces(pf, workspace_paths, cwd):
                return 'ask', f"grep pattern file outside workspace requires approval: {pf}"

        search_paths = positionals if has_pattern else positionals[1:]

        for p in search_paths:
            if is_sensitive_credential_path(p, cwd) or matches_sensitive_pattern(p):
                return 'deny', f"Searching sensitive credential path is forbidden: {p}"
            p_norm = expand_path(p, cwd)
            p_dir = p_norm if p_norm.endswith(os.sep) else p_norm + os.sep
            for prefix in get_sensitive_credential_prefixes():
                prefix_norm = str(Path(prefix).resolve()) if os.path.exists(prefix) else os.path.abspath(prefix)
                if prefix_norm == p_norm or prefix_norm.startswith(p_dir):
                    return 'deny', f"Recursive search over path containing sensitive credentials is forbidden: {p}"

        if is_recursive:
            return 'ask', f"Recursive grep may expose sensitive workspace files or traverse symlinks: {' '.join(cmd_tokens)}"

        for p in search_paths:
            if not is_path_in_workspaces(p, workspace_paths, cwd):
                return 'ask', f"Searching outside workspace requires confirmation: {p}"

        return 'allow', 'Safe grep query'

    # Sort: check --compress-program, output redirection, temporary directory, and input file operands
    if base_cmd == 'sort':
        if any(a.startswith('--co') and '--compress-program'.startswith(a.split('=', 1)[0]) for a in args):
            return 'ask', f"sort with execution helper requires confirmation: {' '.join(cmd_tokens)}"
        for a in args:
            if not a.startswith('-') and any(c in a for c in ('$', '`', '*', '?', '[', ']')):
                return 'ask', f"sort with wildcard, variable, or substitution requires confirmation: {' '.join(cmd_tokens)}"

        SORT_OPTS_WITH_ARG = {
            '-o', '--output',
            '-T', '--temporary-directory',
            '-k', '--key',
            '-t', '--field-separator',
            '-S', '--buffer-size',
            '--batch-size',
            '--compress-program',
            '--parallel',
            '--files0-from',
        }
        input_files = []
        out_target = None
        temp_dir = None
        files0_from = None
        i = 0
        while i < len(args):
            a = args[i]
            if a == '--':
                input_files.extend(args[i + 1:])
                break
            if a.startswith('--'):
                opt_name = a.split('=', 1)[0]
                if '=' in a:
                    val = a.split('=', 1)[1]
                    if '--output'.startswith(opt_name):
                        out_target = val
                    elif '--temporary-directory'.startswith(opt_name):
                        temp_dir = val
                    elif '--files0-from'.startswith(opt_name):
                        files0_from = val
                    i += 1
                    continue
                elif opt_name in SORT_OPTS_WITH_ARG or any(long_opt.startswith(opt_name) for long_opt in SORT_OPTS_WITH_ARG if long_opt.startswith('--')):
                    if i + 1 < len(args):
                        val = args[i + 1]
                        if '--output'.startswith(opt_name):
                            out_target = val
                        elif '--temporary-directory'.startswith(opt_name):
                            temp_dir = val
                        elif '--files0-from'.startswith(opt_name):
                            files0_from = val
                        i += 2
                        continue
                i += 1
                continue
            elif a.startswith('-') and not a.startswith('--'):
                if 'o' in a:
                    o_idx = a.index('o')
                    rest = a[o_idx + 1:].lstrip('=')
                    if rest:
                        out_target = rest
                    elif i + 1 < len(args):
                        out_target = args[i + 1]
                        i += 1
                elif 'T' in a:
                    t_idx = a.index('T')
                    rest = a[t_idx + 1:].lstrip('=')
                    if rest:
                        temp_dir = rest
                    elif i + 1 < len(args):
                        temp_dir = args[i + 1]
                        i += 1
                elif any(c in a for c in ('k', 't', 'S')):
                    for c in ('k', 't', 'S'):
                        if c in a:
                            idx_c = a.index(c)
                            if idx_c == len(a) - 1 and i + 1 < len(args):
                                i += 1
                            break
                i += 1
                continue
            else:
                input_files.append(a)
                i += 1

        if out_target:
            if is_sensitive_credential_path(out_target, cwd) or is_system_write_path(out_target, cwd):
                return 'deny', f"sort output targeting sensitive or system path is forbidden: {out_target}"
            if is_git_admin_path(out_target, cwd):
                return 'ask', f"sort modifying git repository configuration or hooks requires confirmation: {out_target}"
            if not is_path_in_workspaces(out_target, workspace_paths, cwd):
                return 'ask', f"sort output outside workspace requires approval: {out_target}"

        if temp_dir:
            if is_sensitive_credential_path(temp_dir, cwd) or is_system_write_path(temp_dir, cwd):
                return 'deny', f"sort temporary directory targeting sensitive or system path is forbidden: {temp_dir}"
            if not is_path_in_workspaces(temp_dir, workspace_paths, cwd):
                return 'ask', f"sort temporary directory outside workspace requires approval: {temp_dir}"

        if files0_from:
            if files0_from == '-':
                return 'ask', f"sort reading file list from stdin requires confirmation: {' '.join(cmd_tokens)}"
            if is_sensitive_credential_path(files0_from, cwd):
                return 'deny', f"sort reading file list from sensitive path is forbidden: {files0_from}"
            if not is_path_in_workspaces(files0_from, workspace_paths, cwd):
                return 'ask', f"sort reading file list outside workspace requires approval: {files0_from}"

        for inf in input_files:
            if inf == '-':
                continue
            if is_sensitive_credential_path(inf, cwd) or matches_sensitive_pattern(inf):
                return 'deny', f"sort reading sensitive file is forbidden: {inf}"
            if not is_path_in_workspaces(inf, workspace_paths, cwd):
                return 'ask', f"sort reading file outside workspace requires approval: {inf}"

        return 'allow', 'Safe sort command'

    # Find: safe ONLY without destructive, execution, or file writing options
    if base_cmd == 'find':
        for a in args:
            if not a.startswith('-') and ('$' in a or '`' in a):
                return 'ask', f"find with unexpanded variable requires confirmation: {' '.join(cmd_tokens)}"
        if any(a in ('-delete', '-exec', '-execdir', '-ok', '-okdir', '-fls', '-fprint', '-fprint0', '-fprintf') or a.startswith(('-exec', '-ok', '-fls', '-fprint')) for a in args):
            return 'ask', f"find with execution or write options requires confirmation: {' '.join(cmd_tokens)}"

        # Check search roots (handling leading flags like -H, -L, -P, -D, -O)
        search_roots = []
        i = 0
        while i < len(args):
            a = args[i]
            if a in ('-H', '-L', '-P'):
                i += 1
                continue
            if a in ('-D', '-O'):
                i += 2
                continue
            if a.startswith(('-D', '-O')):
                i += 1
                continue
            # Any option starting with '-' or expression operator marks the end of search roots
            if a.startswith(('-', '(', ')', '!', ',')) or a in ('-not', '-and', '-or'):
                break
            search_roots.append(a)
            i += 1

        if not search_roots:
            search_roots = [cwd]
        for root in search_roots:
            if is_sensitive_credential_path(root, cwd):
                return 'deny', f"find searching sensitive path is forbidden: {root}"
            if not is_path_in_workspaces(root, workspace_paths, cwd):
                return 'ask', f"find searching directory outside workspace requires approval: {root}"
        return 'allow', 'Safe find command'

    # 7. Test, Lint, and Build Runners
    if base_cmd in {'npm', 'pnpm', 'yarn', 'bun'}:
        if any(a in ('--script-shell', '--shell') or a.startswith(('--script-shell=', '--shell=')) for a in args):
            return 'ask', f"{base_cmd} with custom script shell requires confirmation: {' '.join(cmd_tokens)}"

        # Workspace selection options (e.g. npm -w, --workspace, --workspaces, pnpm --filter) require confirmation
        if any(a in ('-w', '--workspace', '-ws', '--workspaces', '--filter', '-F', '--recursive', '-r') or
               a.startswith(('-w=', '--workspace=', '--filter=', '-F=')) for a in args):
            return 'ask', f"Package workspace selection options require confirmation: {' '.join(cmd_tokens)}"

        # Package directory / prefix options
        target_dir = cwd
        skip_next_dir = False
        for i, a in enumerate(args):
            if skip_next_dir:
                skip_next_dir = False
                continue
            if a in ('--prefix', '-C', '--dir', '--cwd') and i + 1 < len(args):
                target_dir = args[i + 1]
                skip_next_dir = True
            elif a.startswith(('--prefix=', '--dir=', '--cwd=')):
                target_dir = a.split('=', 1)[1]
            elif a.startswith('-C') and len(a) > 2:
                target_dir = a[2:]

        norm_target_dir = expand_path(target_dir, cwd)
        if not is_path_in_workspaces(norm_target_dir, workspace_paths, cwd):
            return 'ask', f"Package directory option targeting path outside workspace requires confirmation: {target_dir}"

        if args:
            sub = args[0]
            target_script = None
            script_args = []
            if sub == 'test' or sub.startswith('test'):
                target_script = 'test' if sub == 'test' else sub
                script_args = args[1:]
            elif sub == 'run' and len(args) > 1:
                target_script = args[1]
                script_args = args[2:]
            elif base_cmd in {'yarn', 'pnpm', 'bun'} and sub not in {'install', 'i', 'add', 'remove', 'uninstall', 'update', 'publish', 'pack', 'init', 'create', 'info', 'why', 'list', 'outdated', 'audit', 'login', 'logout'}:
                target_script = sub
                script_args = args[1:]

            if target_script:
                out_check = check_dev_tool_output(script_args, workspace_paths, norm_target_dir, f"{base_cmd} {sub}")
                if out_check:
                    return out_check

                # Inspect and validate package.json script body and lifecycle hooks if package.json exists
                pkg_json = find_package_json(norm_target_dir, workspace_paths)
                if pkg_json:
                    # Determine whether lifecycle scripts are ignored
                    npm_opts = []
                    for a in script_args:
                        if a == '--':
                            break
                        npm_opts.append(a)

                    has_ignore_scripts = False
                    for a in npm_opts:
                        if a == '--ignore-scripts' or a == '--ignore-scripts=true':
                            has_ignore_scripts = True
                        elif a.startswith('--ignore-scripts='):
                            val = a.split('=', 1)[1].lower()
                            has_ignore_scripts = (val not in ('false', '0', 'no', 'off'))
                        elif a in ('--no-ignore-scripts', '--ignore-scripts=false'):
                            has_ignore_scripts = False

                    scripts_to_check = []
                    if not has_ignore_scripts:
                        pre_s = 'pre' + target_script
                        if get_package_script(pkg_json, pre_s) is not None:
                            scripts_to_check.append(pre_s)
                    scripts_to_check.append(target_script)
                    if not has_ignore_scripts:
                        post_s = 'post' + target_script
                        if get_package_script(pkg_json, post_s) is not None:
                            scripts_to_check.append(post_s)

                    for s_name in scripts_to_check:
                        script_body = get_package_script(pkg_json, s_name)
                        if script_body is not None:
                            s_verdict, s_reason = classify_command_line(script_body, workspace_paths, norm_target_dir, depth=depth + 1)
                            if s_verdict == 'deny':
                                return 'deny', f"Package lifecycle script '{s_name}' in package.json is forbidden: {s_reason}"
                            if s_verdict != 'allow':
                                return s_verdict, f"Package lifecycle script '{s_name}' in package.json requires confirmation: {s_reason}"
                        elif s_name == target_script and (base_cmd != 'bun' or sub != 'test'):
                            return 'force_ask', f"Package script '{target_script}' not found in package.json requires confirmation: {' '.join(cmd_tokens)}"

                return 'force_ask', f"Package manager script executes repository-defined scripts or node_modules binaries: {base_cmd} {' '.join(args)}"

            if sub in {'install', 'i', 'add', 'remove', 'uninstall', 'update', 'publish'}:
                return 'ask', f"Package management alters dependencies: {base_cmd} {sub}"
        return 'ask', f"Package manager command requires confirmation: {' '.join(cmd_tokens)}"

    # npx / bunx: always requires confirmation since it executes local binaries or packages
    if base_cmd in {'npx', 'bunx'}:
        return 'force_ask', f"{base_cmd} execution requires confirmation: {' '.join(cmd_tokens)}"

    if base_cmd in {'jest', 'vitest', 'mocha', 'ava', 'tap', 'c8', 'nyc'}:
        return 'force_ask', f"Test runner executes workspace test code and requires confirmation: {base_cmd}"

    if base_cmd in {'tsc', 'eslint', 'prettier', 'standard', 'biome', 'vite', 'webpack', 'rollup', 'esbuild'}:
        in_check = check_dev_tool_inputs(args, workspace_paths, cwd, base_cmd)
        if in_check:
            return in_check
        out_check = check_dev_tool_output(args, workspace_paths, cwd, base_cmd)
        if out_check:
            return out_check
        return 'force_ask', f"JavaScript build or linter tool loads repository-controlled configuration or plugins: {base_cmd}"

    if base_cmd == 'cargo':
        if any(a == '--config' or a.startswith(('--config=', '--config')) for a in args):
            return 'force_ask', f"cargo with configuration override (--config) requires confirmation: {' '.join(cmd_tokens)}"
        if any(a == '-Z' or (a.startswith('-Z') and len(a) > 2) for a in args):
            return 'force_ask', f"cargo with unstable flag (-Z) requires confirmation: {' '.join(cmd_tokens)}"
        in_check = check_dev_tool_inputs(args, workspace_paths, cwd, 'cargo')
        if in_check:
            return in_check
        out_check = check_dev_tool_output(args, workspace_paths, cwd, 'cargo')
        if out_check:
            return out_check
        if args:
            sub = args[0]
            if sub == 'fmt':
                return 'allow', f"Safe cargo command: cargo {sub}"
            if sub in {'check', 'clippy', 'test', 'bench', 'run', 'build'}:
                return 'force_ask', f"Cargo command may execute build scripts or procedural macros: cargo {sub}"
            if sub in {'install', 'publish', 'add', 'remove'}:
                return 'force_ask', f"Cargo dependency modification requires confirmation: cargo {sub}"
        return 'force_ask', f"Cargo command requires confirmation: {' '.join(cmd_tokens)}"

    if base_cmd in {'pytest', 'ruff', 'mypy', 'flake8', 'black', 'pylint'}:
        in_check = check_dev_tool_inputs(args, workspace_paths, cwd, base_cmd)
        if in_check:
            return in_check
        out_check = check_dev_tool_output(args, workspace_paths, cwd, base_cmd)
        if out_check:
            return out_check
        return 'force_ask', f"Python tool may execute repository-configured plugins or test code: {base_cmd}"

    if base_cmd in {'python', 'python3'}:
        if args and args[0] == '-m' and len(args) > 1:
            module = args[1]
            mod_args = args[2:]
            in_check = check_dev_tool_inputs(mod_args, workspace_paths, cwd, f"python -m {module}")
            if in_check:
                return in_check
            out_check = check_dev_tool_output(mod_args, workspace_paths, cwd, f"python -m {module}")
            if out_check:
                return out_check
            return 'force_ask', f"python -m {module} executes repository-defined code or plugins: {' '.join(cmd_tokens)}"
        return 'force_ask', f"Executing Python script requires confirmation: {' '.join(cmd_tokens)}"

    if base_cmd == 'go':
        if args and args[0] in {'test', 'vet', 'fmt', 'build'}:
            if any(a in ('-exec', '--exec', '-toolexec', '--toolexec') or a.startswith(('-exec=', '--exec=', '-toolexec=', '--toolexec=')) for a in args):
                return 'force_ask', f"go {args[0]} with custom exec or toolexec program requires confirmation: {' '.join(cmd_tokens)}"
            if args[0] == 'test':
                return 'force_ask', f"go test executes workspace test code and requires confirmation: {' '.join(cmd_tokens)}"
            in_check = check_dev_tool_inputs(args[1:], workspace_paths, cwd, f"go {args[0]}")
            if in_check:
                return in_check
            out_check = check_dev_tool_output(args[1:], workspace_paths, cwd, f"go {args[0]}")
            if out_check:
                return out_check
            return 'allow', f"Safe Go static tool: go {args[0]}"

    if base_cmd == 'make':
        return 'force_ask', f"make executes repository-controlled Makefile recipes: {' '.join(cmd_tokens)}"

    # 8. Safe Local File Operations (cp / mv)
    if base_cmd in {'cp', 'mv'}:
        if base_cmd == 'cp':
            has_risky_cp = False
            for a in args:
                if a.startswith('-') and not a.startswith('--') and any(c in a for c in ('r', 'R', 'L', 'a', 'H')):
                    has_risky_cp = True
                    break
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    if any(long_opt.startswith(opt) for long_opt in ('--recursive', '--dereference', '--archive') if len(opt) >= 3):
                        has_risky_cp = True
                        break
            if has_risky_cp:
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
            elif a.startswith('--') and any('--target-directory'.startswith(opt) for opt in (a.split('=', 1)[0],) if len(opt) >= 3):
                if '=' in a:
                    target_dir = a.split('=', 1)[1]
                elif i + 1 < len(args):
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


def classify_command_line(cmd_str, workspace_paths, cwd, depth=0):
    """Classify an entire shell command line string across lines, chains, and pipelines."""
    if depth > 5:
        return 'ask', 'Nested command recursion limit exceeded'

    if not isinstance(cmd_str, str) or not cmd_str.strip():
        return 'ask', 'Empty command line or invalid type'

    # Check for command substitutions $(...) or `...` or process substitutions <(...) >(...)
    if re.search(r'(\$\(|\`|<(?=\()|>(?=\())', cmd_str):
        return 'ask', 'Command contains command or process substitution'

    subcmd_strings, pipeline_links_all = split_unquoted_shell_commands(cmd_str)
    if subcmd_strings is None:
        return 'ask', 'Unable to safely parse command line (syntax error, unclosed quote, or dangling escape)'

    if not subcmd_strings:
        return 'allow', 'Empty command'

    subcommands_all = []
    for sub_str in subcmd_strings:
        tokens = tokenize_subcommand(sub_str)
        if tokens is None:
            return 'ask', f"Unable to safely parse command tokens: {sub_str}"
        if tokens:
            subcommands_all.append(tokens)

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
        verdict, reason = classify_subcommand(sub, workspace_paths, cwd, depth=depth)
        verdicts.append((verdict, reason))

    for v, r in verdicts:
        if v == 'deny':
            return 'deny', r

    for v, r in verdicts:
        if v == 'force_ask':
            return 'force_ask', r

    for v, r in verdicts:
        if v == 'ask':
            return 'ask', r

    return 'allow', 'Safe command auto-approved by classifier'


def classify_file_modification(target_file, workspace_paths, cwd):
    """Classify file write or replacement tools."""
    if not target_file or not isinstance(target_file, str):
        return 'force_ask', 'No target file specified or invalid type'

    if is_sensitive_credential_path(target_file, cwd) or is_system_write_path(target_file, cwd):
        return 'deny', f"Modifying sensitive or system path is forbidden: {target_file}"

    if is_git_admin_path(target_file, cwd):
        return 'force_ask', f"Modifying git repository configuration or hooks requires confirmation: {target_file}"

    if is_path_in_workspaces(target_file, workspace_paths, cwd):
        return 'allow', f"File modification within workspace auto-approved: {os.path.basename(target_file)}"

    return 'force_ask', f"File modification outside workspace requires approval: {target_file}"


def classify_file_read(target_file, workspace_paths, cwd):
    """Classify read-only file access tools."""
    if not target_file or not isinstance(target_file, str) or not target_file.strip():
        return 'ask', 'File read query with missing or invalid path requires confirmation'
    if is_sensitive_credential_path(target_file, cwd):
        return 'deny', f"Reading sensitive credentials is forbidden: {target_file}"
    if not is_path_in_workspaces(target_file, workspace_paths, cwd):
        return 'ask', f"Reading file outside workspace requires approval: {target_file}"
    norm = expand_path(target_file, cwd)
    norm_dir = norm if norm.endswith(os.sep) else norm + os.sep
    for prefix in get_sensitive_credential_prefixes():
        norm_prefix = str(Path(prefix).resolve()) if os.path.exists(prefix) else os.path.abspath(prefix)
        if norm_prefix.startswith(norm_dir):
            return 'force_ask', f"Searching directory containing sensitive credentials requires approval: {target_file}"
    return 'allow', f"Safe file read: {os.path.basename(target_file)}"


def classify_directory_search(target_dir, args, workspace_paths, cwd):
    """Classify recursive directory search tools (grep_search, find_by_name)."""
    if not target_dir or not isinstance(target_dir, str) or not target_dir.strip():
        target_dir = cwd

    # If searching sensitive credential path: hard deny
    if is_sensitive_credential_path(target_dir, cwd):
        return 'deny', f"Searching sensitive credentials is forbidden: {target_dir}"

    if not is_path_in_workspaces(target_dir, workspace_paths, cwd):
        return 'ask', f"Searching directory outside workspace requires approval: {target_dir}"

    norm = expand_path(target_dir, cwd)
    norm_dir = norm if norm.endswith(os.sep) else norm + os.sep

    # Ancestor check for fixed credential prefixes
    for prefix in get_sensitive_credential_prefixes():
        norm_prefix = str(Path(prefix).resolve()) if os.path.exists(prefix) else os.path.abspath(prefix)
        if norm_prefix.startswith(norm_dir):
            return 'force_ask', f"Searching directory containing sensitive credentials requires approval: {target_dir}"

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
            decision, reason = classify_file_read(target, workspace_paths, cwd)
        elif tool_name in ('grep_search', 'find_by_name'):
            target = args.get('SearchPath') or args.get('SearchDirectory') or args.get('AbsolutePath') or ''
            decision, reason = classify_directory_search(target, args, workspace_paths, cwd)
        else:
            decision, reason = 'ask', f"Tool {tool_name} requires confirmation"

        print(json.dumps({'decision': decision, 'reason': reason}))
    except Exception as e:
        # Failsafe: never crash unhandled, always emit a valid JSON decision
        print(json.dumps({'decision': 'ask', 'reason': f"Permission classifier internal error: {e}"}))


if __name__ == '__main__':
    main()
