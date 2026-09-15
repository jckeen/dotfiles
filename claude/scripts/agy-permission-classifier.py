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

import codecs
import fnmatch
import glob
import json
import os
from pathlib import Path
import posixpath
import re
import shlex
import shutil
import subprocess
import sys
import time
try:
    import tomllib
except ImportError:
    tomllib = None

# Commands that are strictly read-only inspection and safe to auto-approve without options that execute code or write
SAFE_INSPECTION_COMMANDS = {
    'ls', 'dir', 'vdir', 'pwd', 'echo', 'printf',
    'cat', 'head', 'tail', 'wc',
    'file', 'stat', 'cmp',
    'which', 'whereis', 'type',
    'date', 'uptime', 'whoami', 'id', 'uname',
    'true', 'false', 'test', '[',
    'uniq', 'cut', 'column', 'jq',
}

# Standard directories containing system binaries
SYSTEM_BIN_DIRS = {'/bin', '/usr/bin', '/usr/local/bin', '/sbin', '/usr/sbin', '/snap/bin', '/usr/games'}

# Safe git subcommands that only inspect state without options
SAFE_GIT_READ_SUBCOMMANDS = {
    'status', 'log', 'show', 'rev-parse',
    'rev-list', 'check-ref-format', 'ls-files',
    'describe', 'cat-file', 'shortlog', 'blame',
    'version',
}

# Commands that are eligible for auto-approval and must never be shadowed by user-writable binaries
AUTO_APPROVABLE_COMMANDS = SAFE_INSPECTION_COMMANDS | {
    'git', 'rm', 'find', 'sort', 'grep', 'egrep', 'fgrep', 'rg', 'ag',
    'touch', 'mkdir', 'cp', 'mv', 'cargo', 'go',
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
        os.path.join(home, '.bashrc'),
        os.path.join(home, '.bash_profile'),
        os.path.join(home, '.zshrc'),
        os.path.join(home, '.profile'),
        '/etc/shadow',
        '/etc/sudoers',
        '/run/secrets',
    )

SENSITIVE_FILENAMES = {
    'antigravity-oauth-token',
    'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa',
    'hosts.yml',
    '.git-credentials', 'git-credentials',
    '.npmrc',
    '.pypirc',
    'application_default_credentials.json',
    '.vault-token',
    '.envrc',
}

# Glob patterns that match sensitive files
SENSITIVE_PATTERNS = (
    '.env*', 'id_rsa*', 'id_ed25519*', 'id_ecdsa*', 'id_dsa*',
    '*.pem', '*.key', 'antigravity-oauth-token',
    'shadow*', 'gshadow*', 'sudoers*', 'hosts.yml',
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
    'RUSTFMT',
    'GOTOOLCHAIN', 'GOROOT', 'GOTOOLDIR',
}

SAFE_INLINE_ENV_VARS = {
    'CI', 'NODE_ENV', 'LANG', 'LC_ALL', 'LC_CTYPE',
    'PYTHONUNBUFFERED', 'TERM', 'NO_COLOR', 'FORCE_COLOR', 'TZ',
    'CODEX_GATE_MAX_LINES', 'CODEX_GATE_REQUIRED', 'CODEX_GATE_ALLOW_INSTRUCTION_DIFF',
    'GATE_FORCE_FULL', 'CODEX_GATE_MAX_ISSUES',
}

PROTECTED_BRANCHES = {'main', 'master', 'release', 'prod', 'production'}

# Redirection operators (ordered by descending length for greedy matching)
REDIRECTION_OPERATORS = ('&>>', '>|', '&>', '>>', '>&', '>', '<>', '<')


def is_output_redirection(tok, target=None):
    """Check if token is an output redirection operator (including >& when target is not a file descriptor)."""
    if tok in ('>', '>>', '>|', '&>', '&>>', '<>'):
        return True
    if tok == '>&':
        if target is None or not str(target).strip().isdigit():
            return True
    return False


def is_dangerous_env_var(var_name):
    if var_name in DANGEROUS_ENV_VARS:
        return True
    return any(var_name.startswith(p) for p in DANGEROUS_ENV_PREFIXES)


def is_credential_var_name(var_name):
    """Check if variable name represents credentials, tokens, secrets, or keys."""
    if not var_name or not isinstance(var_name, str):
        return False
    v_upper = var_name.upper()
    if v_upper.startswith(('CODEX_GATE_', 'AGY_GATE_', 'GATE_')):
        return False
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


def decode_shell_arg(arg):
    """Safely decode shell-escaped and ANSI-C quoted ($'...') sequences in argument strings."""
    if not arg or not isinstance(arg, str):
        return arg
    decoded = arg
    if "$'" in decoded:
        try:
            decoded = re.sub(r"\$'([^']*)'", lambda m: codecs.decode(m.group(1), 'unicode_escape'), decoded)
        except Exception:
            pass
    if decoded.startswith('-$'):
        s_clean = '-' + decoded[2:].replace('$\\', '\\')
        try:
            decoded = codecs.decode(s_clean, 'unicode_escape')
        except Exception:
            pass
    elif '\\' in decoded and (decoded.startswith('-') or '$' in decoded):
        try:
            s_clean = decoded.replace('-$', '-').replace('$\\', '\\')
            decoded = codecs.decode(s_clean, 'unicode_escape')
        except Exception:
            pass
    return decoded


def decode_shell_target(target_str):
    """Safely decode shell-escaped and quoted sequences in redirection targets and file paths without altering valid filenames."""
    if not target_str or not isinstance(target_str, str):
        return target_str
    s = target_str
    if s.startswith("$'") and s.endswith("'"):
        try:
            return codecs.decode(s[2:-1], 'unicode_escape')
        except Exception:
            pass
    if len(s) >= 2 and ((s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'"))):
        s = s[1:-1]
    return s


def subcmd_has_unquoted_expansions(subcmd_str):
    """Check if subcmd_str contains unquoted/double-quoted variable expansions ($ or ` outside single quotes)."""
    if not subcmd_str or not isinstance(subcmd_str, str):
        return False
    in_sq = False
    in_dq = False
    escape = False
    for c in subcmd_str:
        if escape:
            escape = False
            continue
        if c == '\\' and not in_sq:
            escape = True
            continue
        if c == "'" and not in_dq:
            in_sq = not in_sq
            continue
        if c == '"' and not in_sq:
            in_dq = not in_dq
            continue
        if not in_sq and c in ('$', '`'):
            return True
    return False


def subcmd_has_unquoted_wildcards(subcmd_str):
    """Check if subcmd_str contains unquoted glob wildcards (*, ?, [, ] outside single and double quotes)."""
    if not subcmd_str or not isinstance(subcmd_str, str):
        return False
    in_sq = False
    in_dq = False
    escape = False
    for c in subcmd_str:
        if escape:
            escape = False
            continue
        if c == '\\' and not in_sq:
            escape = True
            continue
        if c == "'" and not in_dq:
            in_sq = not in_sq
            continue
        if c == '"' and not in_sq:
            in_dq = not in_dq
            continue
        if not in_sq and not in_dq and c in ('*', '?', '[', ']'):
            return True
    return False


def expand_unquoted_tildes(cmd_str, cwd=None):
    """Expand unquoted tilde prefixes (~, ~+, ~-, ~user) at word boundaries prior to tokenization.

    Quoted tilde forms ('~+', "~+", \\~+, '~', "~", etc.) are left untouched.
    """
    if not cmd_str or not isinstance(cmd_str, str) or '~' not in cmd_str:
        return cmd_str

    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    oldpwd = os.environ.get('OLDPWD', effective_cwd)
    home_dir = os.path.expanduser('~')

    res = []
    i = 0
    n = len(cmd_str)
    in_sq = False
    in_dq = False
    escape = False

    while i < n:
        c = cmd_str[i]

        if escape:
            res.append(c)
            escape = False
            i += 1
            continue

        if c == '\\' and not in_sq:
            escape = True
            res.append(c)
            i += 1
            continue

        if c == "'" and not in_dq:
            in_sq = not in_sq
            res.append(c)
            i += 1
            continue

        if c == '"' and not in_sq:
            in_dq = not in_dq
            res.append(c)
            i += 1
            continue

        if not in_sq and not in_dq:
            # Check if this character is an unquoted '~' at a word boundary
            if c == '~':
                is_boundary = False
                if i == 0:
                    is_boundary = True
                else:
                    prev_c = cmd_str[i - 1]
                    if prev_c in (' ', '\t', '\n', '\r', ';', '&', '|', '(', ')', '<', '>', '=', ':', '{', ','):
                        is_boundary = True

                if is_boundary:
                    # Look ahead to find the end of the tilde prefix (up to unquoted '/' or word boundary)
                    # If any quotes or escapes occur within the tilde prefix, it is NOT tilde-expanded.
                    j = i + 1
                    has_quote_in_prefix = False
                    while j < n:
                        cj = cmd_str[j]
                        if cj in ("'", '"', '\\'):
                            has_quote_in_prefix = True
                            break
                        if cj == '/':
                            # End of tilde prefix before slash
                            break
                        if cj in (' ', '\t', '\n', '\r', ';', '&', '|', '(', ')', '<', '>', '=', ':', '}', ','):
                            # End of word
                            break
                        j += 1

                    if not has_quote_in_prefix:
                        prefix = cmd_str[i:j]
                        expanded_prefix = None
                        if prefix == '~':
                            expanded_prefix = home_dir
                        elif prefix == '~+':
                            expanded_prefix = effective_cwd
                        elif prefix == '~-':
                            expanded_prefix = oldpwd
                        elif re.match(r'^~[A-Za-z0-9_.-]+$', prefix):
                            cand_home = os.path.expanduser(prefix)
                            if cand_home != prefix:
                                expanded_prefix = cand_home

                        if expanded_prefix is not None:
                            res.append(expanded_prefix)
                            i = j
                            continue

        res.append(c)
        i += 1

    return ''.join(res)


def expand_path(p_str, cwd=None, expand_tilde=False):
    """Safely expand user, variables, and relative paths against cwd."""
    if not p_str or not isinstance(p_str, str):
        return ''
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    expanded = p_str
    if expand_tilde:
        # Expand bash tilde forms ~+ ($PWD) and ~- ($OLDPWD)
        if expanded == '~+' or expanded.startswith(('~+/', '~+\\')):
            expanded = effective_cwd + expanded[2:]
        elif expanded == '~-' or expanded.startswith(('~-/', '~-\\')):
            oldpwd = os.environ.get('OLDPWD', effective_cwd)
            expanded = oldpwd + expanded[2:]
        expanded = os.path.expanduser(expanded)
    expanded = os.path.expandvars(expanded)
    if not os.path.isabs(expanded):
        expanded = os.path.join(effective_cwd, expanded)
    try:
        return str(Path(expanded).resolve())
    except Exception:
        return os.path.abspath(expanded)


PUBLIC_NON_CREDENTIAL_SUFFIXES = (
    '.example', '.sample', '.template', '.dist', '.default',
)
SOURCE_FILE_EXTENSIONS = (
    '.py', '.ts', '.js', '.jsx', '.tsx', '.go', '.rs', '.c', '.cpp', '.h', '.hpp',
    '.java', '.rb', '.php', '.css', '.scss', '.html', '.md', '.txt', '.json',
    '.yaml', '.yml', '.toml', '.xml', '.svg', '.png', '.jpg',
)


def matches_sensitive_pattern(filename):
    """Check if a filename or glob pattern matches sensitive credential patterns."""
    if not filename or not isinstance(filename, str):
        return False
    basename = os.path.basename(filename)
    if basename in SENSITIVE_FILENAMES:
        return True
    if any(basename.endswith(sfx) for sfx in PUBLIC_NON_CREDENTIAL_SUFFIXES):
        return False
    if any(basename.endswith(ext) for ext in SOURCE_FILE_EXTENSIONS):
        if basename.endswith(('.pem', '.key')):
            return True
        if basename.startswith('.env') and not any(basename.endswith(s) for s in PUBLIC_NON_CREDENTIAL_SUFFIXES):
            return True
        return False
    if basename.startswith('.env'):
        return True
    if any(fnmatch.fnmatch(basename, pat) for pat in SENSITIVE_PATTERNS):
        return True
    # If basename is a bracket expression pattern, check if it targets sensitive names without being a broad wildcard
    if '[' in basename and ']' in basename:
        candidate_sensitive = (
            '.env', '.env.local', '.env.production', '.env.development',
            'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa',
            '.git-credentials', 'hosts.yml', '.npmrc', '.pypirc',
            'secret.pem', 'server.key', 'id_rsa.pub'
        )
        if any(fnmatch.fnmatch(s, basename) for s in candidate_sensitive):
            if not any(fnmatch.fnmatch(safe, basename) for safe in ('.gitignore', '.clang-format', 'safe.txt', 'main.py', 'test.js', 'README.md', 'app.go')):
                return True
    return False


def expand_braces(text, max_depth=5, max_results=64):
    """Expand simple shell brace expressions like ~/{.aws,.ssh}/credentials with depth and result limits."""
    def _helper(t, depth):
        if depth > max_depth:
            return [t]
        m = re.search(r'\{([^{}]+)\}', t)
        if not m:
            return [t]
        prefix = t[:m.start()]
        suffix = t[m.end():]
        options = m.group(1).split(',')
        if len(options) > 16:
            return [t]
        res = []
        for opt in options:
            for sub in _helper(prefix + opt + suffix, depth + 1):
                res.append(sub)
                if len(res) >= max_results:
                    return res
        return res

    results = _helper(text, 0)
    return results[:max_results]


def is_sensitive_credential_path(path_str, cwd=None, _in_brace=False):
    """Check if a path targets credentials, private keys, or tokens (including globs and braces)."""
    if not path_str or not isinstance(path_str, str):
        return False
    if path_str == '/dev/null':
        return False

    # Check for brace expansion like ~/{.aws,.ssh}/credentials
    if not _in_brace and '{' in path_str and '}' in path_str:
        for exp in expand_braces(path_str):
            if is_sensitive_credential_path(exp, cwd, _in_brace=True):
                return True

    # 1. First, check literal path_str directly against patterns and resolve real filesystem target
    if matches_sensitive_pattern(path_str) or matches_sensitive_pattern(os.path.basename(path_str)):
        return True

    norm = expand_path(path_str, cwd, expand_tilde=True)
    if matches_sensitive_pattern(norm) or matches_sensitive_pattern(os.path.basename(norm)):
        return True

    try:
        resolved = str(Path(norm).resolve())
        if matches_sensitive_pattern(resolved) or matches_sensitive_pattern(os.path.basename(resolved)):
            return True
    except Exception:
        resolved = norm

    candidates = [norm, resolved]
    norm_no_tilde = expand_path(path_str, cwd, expand_tilde=False)
    if norm_no_tilde != norm:
        if matches_sensitive_pattern(norm_no_tilde) or matches_sensitive_pattern(os.path.basename(norm_no_tilde)):
            return True
        try:
            resolved_no_tilde = str(Path(norm_no_tilde).resolve())
            if matches_sensitive_pattern(resolved_no_tilde) or matches_sensitive_pattern(os.path.basename(resolved_no_tilde)):
                return True
            candidates.extend([norm_no_tilde, resolved_no_tilde])
        except Exception:
            candidates.append(norm_no_tilde)

    # 2. Also check de-obfuscated clean path (e.g. /etc/sha""dow or .en[v])
    clean = re.sub(r'[\"\'\\]', '', path_str)
    clean = re.sub(r'\[(.)\]', r'\1', clean)
    if clean != path_str:
        if matches_sensitive_pattern(clean) or matches_sensitive_pattern(os.path.basename(clean)):
            return True
        clean_norm = expand_path(clean, cwd, expand_tilde=True)
        if matches_sensitive_pattern(clean_norm) or matches_sensitive_pattern(os.path.basename(clean_norm)):
            return True
        try:
            clean_resolved = str(Path(clean_norm).resolve())
            if matches_sensitive_pattern(clean_resolved) or matches_sensitive_pattern(os.path.basename(clean_resolved)):
                return True
        except Exception:
            clean_resolved = clean_norm
        candidates.extend([clean_norm, clean_resolved])
        clean_norm_no_tilde = expand_path(clean, cwd, expand_tilde=False)
        if clean_norm_no_tilde != clean_norm:
            if matches_sensitive_pattern(clean_norm_no_tilde) or matches_sensitive_pattern(os.path.basename(clean_norm_no_tilde)):
                return True
            try:
                clean_resolved_no_tilde = str(Path(clean_norm_no_tilde).resolve())
                if matches_sensitive_pattern(clean_resolved_no_tilde) or matches_sensitive_pattern(os.path.basename(clean_resolved_no_tilde)):
                    return True
                candidates.extend([clean_norm_no_tilde, clean_resolved_no_tilde])
            except Exception:
                candidates.append(clean_norm_no_tilde)
    else:
        clean_norm = norm
        clean_resolved = resolved

    # Check for process environment reads (/proc/*/environ, /proc/self/environ, etc.)
    for p_cand in candidates:
        p_cand_slash = p_cand.replace('\\', '/')
        if p_cand_slash.startswith('/proc/') and ('/environ' in p_cand_slash or os.path.basename(p_cand_slash) == 'environ'):
            return True
        if (p_cand_slash.endswith('/.git/config') or p_cand_slash == '.git/config' or '/.git/config/' in p_cand_slash or
            p_cand_slash.endswith('/.git-credentials') or p_cand_slash == '.git-credentials' or
            p_cand_slash.endswith('/.docker/config.json') or
            any(p_cand_slash == p or p_cand_slash.startswith(p + '/') for p in ('/etc/shadow', '/etc/gshadow', '/etc/sudoers', '/etc/sudoers.d'))):
            return True

    for prefix in get_sensitive_credential_prefixes():
        prefixes_to_check = {os.path.abspath(prefix)}
        if os.path.exists(prefix):
            try:
                prefixes_to_check.add(str(Path(prefix).resolve()))
            except Exception:
                pass
        for norm_prefix in prefixes_to_check:
            for p_cand in candidates:
                if p_cand == norm_prefix or p_cand.startswith(norm_prefix + os.sep):
                    return True
                if any(c in p_cand for c in ('*', '?', '[')):
                    if fnmatch.fnmatch(norm_prefix, p_cand) or fnmatch.fnmatch(p_cand, norm_prefix):
                        return True
                    p_parts = p_cand.strip(os.sep).split(os.sep)
                    prefix_parts = norm_prefix.strip(os.sep).split(os.sep)
                    if len(p_parts) >= len(prefix_parts):
                        if all(fnmatch.fnmatch(pref, part) or fnmatch.fnmatch(part, pref)
                               for pref, part in zip(prefix_parts, p_parts[:len(prefix_parts)])):
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
        norm_target = expand_path(target_path, cwd, expand_tilde=False)
        for ws in workspace_paths:
            if not ws or not isinstance(ws, str):
                continue
            norm_ws = expand_path(ws, cwd, expand_tilde=True)
            if norm_target == norm_ws or norm_target.startswith(norm_ws + os.sep):
                return True
    except Exception:
        return False
    return False


def validate_file_list_entries(list_file, cmd_name, cmd_tokens, workspace_paths, cwd, written_files=None, nul_delimited=False):
    """Validate an external file list and all its entries (newline or NUL delimited)."""
    if not list_file or not isinstance(list_file, str):
        return None
    if list_file in ('-', '/dev/stdin'):
        return 'ask', f"{cmd_name} reading file list from stdin requires confirmation: {' '.join(cmd_tokens)}"
    if is_sensitive_credential_path(list_file, cwd) or matches_sensitive_pattern(list_file):
        return 'deny', f"{cmd_name} reading file list from sensitive path is forbidden: {list_file}"
    if not is_path_in_workspaces(list_file, workspace_paths, cwd):
        return 'ask', f"{cmd_name} reading file list outside workspace requires approval: {list_file}"
    f_resolved = expand_path(list_file, cwd)
    norm_f = os.path.normpath(f_resolved)
    if written_files:
        for wf in written_files:
            norm_wf = os.path.normpath(wf)
            if norm_f == norm_wf or norm_f.startswith(norm_wf + os.sep):
                return 'force_ask', f"{cmd_name} file list was modified or redirected to in the command line: {list_file}"
    for i_tok, tok in enumerate(cmd_tokens):
        if is_output_redirection(tok, cmd_tokens[i_tok + 1] if i_tok + 1 < len(cmd_tokens) else None) and i_tok + 1 < len(cmd_tokens):
            redir_target = expand_path(unquote_token(cmd_tokens[i_tok + 1]), cwd)
            if os.path.normpath(redir_target) == norm_f:
                return 'force_ask', f"{cmd_name} file list is redirected to within the same command: {list_file}"
    if not os.path.isfile(f_resolved):
        return 'force_ask', f"{cmd_name} file list does not exist: {list_file}"
    try:
        content = Path(f_resolved).read_bytes()
        raw_entries = content.split(b'\0') if nul_delimited else content.splitlines()
        for entry in raw_entries:
            if nul_delimited:
                p = entry.decode(errors='replace')
                if not p:
                    continue
            else:
                p = entry.decode(errors='replace').rstrip('\r\n')
                if not p:
                    continue
            check_targets = [p]
            if p.strip() and p.strip() != p:
                check_targets.append(p.strip())
            for target in check_targets:
                if is_sensitive_credential_path(target, cwd) or matches_sensitive_pattern(target):
                    return 'deny', f"{cmd_name} file list references sensitive path: {p}"
                if not is_path_in_workspaces(target, workspace_paths, cwd):
                    return 'ask', f"{cmd_name} file list references path outside workspace: {p}"
                if is_security_guard_path(target, cwd):
                    return 'force_ask', f"{cmd_name} file list references protected security guard: {p}"
                if is_git_admin_path(target, cwd):
                    return 'force_ask', f"{cmd_name} file list references git admin path: {p}"
                if written_files:
                    norm_target = os.path.normpath(expand_path(target, cwd))
                    for wf in written_files:
                        norm_wf = os.path.normpath(wf)
                        if norm_target == norm_wf or norm_target.startswith(norm_wf + os.sep):
                            return 'force_ask', f"{cmd_name} file list entry was modified or updated earlier: {p}"
    except Exception:
        return 'force_ask', f"{cmd_name} unable to verify file list: {list_file}"
    return None


def validate_files0_from(files0_from, cmd_name, cmd_tokens, workspace_paths, cwd, written_files=None):
    """Validate a --files0-from list file and all its NUL-delimited entries."""
    return validate_file_list_entries(files0_from, cmd_name, cmd_tokens, workspace_paths, cwd, written_files=written_files, nul_delimited=True)


def glob_matches_vcs(glob_pat):
    """Check if a glob pattern can match .git or files within .git."""
    if not glob_pat or not isinstance(glob_pat, str):
        return False
    clean_g = glob_pat.strip('\'"')
    if clean_g.startswith('!'):
        return False
    if clean_g in ('**', '*', '*/**', '**/*', '.*', '.*/**', '.*/*', '**/.*', '**/*.*', '.*/*'):
        return True
    if '.git' in clean_g:
        return True
    for candidate in ('.git', '.git/config', '.git/credentials', '.git-credentials'):
        if fnmatch.fnmatch(candidate, clean_g) or fnmatch.fnmatch(candidate, clean_g.lstrip('/')):
            return True
        if fnmatch.fnmatch(os.path.basename(candidate), clean_g):
            return True
    return False


def check_directory_descendants(target_dir, cwd=None, include_vcs=False):
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
            # Prune VCS directory unless explicitly searching VCS files
            if not include_vcs and '.git' in dirs:
                dirs.remove('.git')

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
        probe_cmd = [git_bin]
        if args and args[0] in ('status', 'diff', 'show', 'log', 'for-each-ref', 'rev-parse'):
            probe_cmd.extend(['-c', 'core.fsmonitor=false', '-c', 'diff.external=', '-c', 'submodule.recurse=false'])
        cmd_args = list(args)
        if args and args[0] in ('status', 'diff'):
            if not any(a.startswith('--ignore-submodules') for a in cmd_args):
                cmd_args.append('--ignore-submodules=all')
        probe_cmd.extend(cmd_args)
        res = subprocess.run(
            probe_cmd,
            cwd=effective_cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        _GIT_PROBE_CACHE[cache_key] = res
        return res
    except Exception:
        return None


def git_has_ext_diff_driver(cwd=None):
    """Check if git has an external diff driver configured via GIT_EXTERNAL_DIFF or diff.external."""
    ext_diff_env = os.environ.get('GIT_EXTERNAL_DIFF')
    if ext_diff_env and ext_diff_env.strip():
        return True
    res = git_run_probe(['config', '--get-regexp', r'^diff\.(external|.*\.command)$'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        return True
    return False


def git_has_textconv_driver(cwd=None):
    """Check if git has a textconv driver configured that executes programs."""
    res = git_run_probe(['config', '--get-regexp', r'^diff\..*\.textconv$'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        return True
    return False


def git_has_external_diff_configured(cwd=None):
    """Check if git has an external diff or textconv driver configured that executes programs."""
    return git_has_ext_diff_driver(cwd) or git_has_textconv_driver(cwd)


def git_has_fsmonitor_configured(cwd=None):
    """Check if git repository or any of its submodules has a core.fsmonitor hook configured that executes programs."""
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    res = git_run_probe(['config', '--get', 'core.fsmonitor'], cwd=effective_cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        val = res.stdout.strip().lower()
        if val not in ('false', '0', 'no', 'off'):
            return True

    # Check submodule configurations in .git/modules
    res_git_dir = git_run_probe(['rev-parse', '--git-dir'], cwd=effective_cwd)
    if res_git_dir and res_git_dir.returncode == 0 and res_git_dir.stdout.strip():
        git_dir = res_git_dir.stdout.strip()
        if not os.path.isabs(git_dir):
            git_dir = os.path.join(effective_cwd, git_dir)
        git_dir = os.path.normpath(git_dir)
        modules_dir = os.path.join(git_dir, 'modules')
        if os.path.isdir(modules_dir):
            try:
                for root, dirs, files in os.walk(modules_dir):
                    if 'config' in files:
                        cfg_path = os.path.join(root, 'config')
                        try:
                            with open(cfg_path, 'r', encoding='utf-8', errors='replace') as f:
                                for line in f:
                                    m = re.match(r'^\s*fsmonitor\s*=\s*(.*)', line, re.IGNORECASE)
                                    if m:
                                        val = m.group(1).strip().strip('"\'').lower()
                                        if val not in ('false', '0', 'no', 'off'):
                                            return True
                        except Exception:
                            pass
            except Exception:
                pass

    # Also check any submodules declared in .gitmodules or child git repositories in working tree
    gitmodules_path = os.path.join(effective_cwd, '.gitmodules')
    if os.path.isfile(gitmodules_path):
        try:
            with open(gitmodules_path, 'r', encoding='utf-8', errors='replace') as gf:
                for gline in gf:
                    m_path = re.match(r'^\s*path\s*=\s*(.*)', gline)
                    if m_path:
                        sub_rel = m_path.group(1).strip().strip('"\'')
                        sub_full = os.path.join(effective_cwd, sub_rel)
                        sub_git = os.path.join(sub_full, '.git')
                        if os.path.isfile(sub_git):
                            try:
                                with open(sub_git, 'r', encoding='utf-8', errors='replace') as sf:
                                    scontent = sf.read().strip()
                                    if scontent.startswith('gitdir:'):
                                        gdir = scontent.split(':', 1)[1].strip()
                                        if not os.path.isabs(gdir):
                                            gdir = os.path.join(sub_full, gdir)
                                        sub_cfg = os.path.join(gdir, 'config')
                                        if os.path.isfile(sub_cfg):
                                            with open(sub_cfg, 'r', encoding='utf-8', errors='replace') as cf:
                                                for cline in cf:
                                                    m_fs = re.match(r'^\s*fsmonitor\s*=\s*(.*)', cline, re.IGNORECASE)
                                                    if m_fs:
                                                        val = m_fs.group(1).strip().strip('"\'').lower()
                                                        if val not in ('false', '0', 'no', 'off'):
                                                            return True
                            except Exception:
                                pass
                        elif os.path.isdir(sub_git):
                            sub_cfg = os.path.join(sub_git, 'config')
                            if os.path.isfile(sub_cfg):
                                try:
                                    with open(sub_cfg, 'r', encoding='utf-8', errors='replace') as cf:
                                        for cline in cf:
                                            m_fs = re.match(r'^\s*fsmonitor\s*=\s*(.*)', cline, re.IGNORECASE)
                                            if m_fs:
                                                val = m_fs.group(1).strip().strip('"\'').lower()
                                                if val not in ('false', '0', 'no', 'off'):
                                                    return True
                                except Exception:
                                    pass
        except Exception:
            pass

    return False


def git_has_active_hooks(cwd=None, hook_names=(), written_files=None, target_ref=None):
    """Check if git repository has active (executable) repository hooks in working tree or target ref."""
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
    norm_hooks = os.path.normpath(hooks_dir)

    # If any file inside hooks_dir was created or modified earlier in the command line,
    # assume an active hook was installed.
    if written_files:
        try:
            resolved_hooks = str(Path(norm_hooks).resolve())
        except Exception:
            resolved_hooks = norm_hooks
        for wf in written_files:
            norm_wf = os.path.normpath(wf)
            if norm_wf == norm_hooks or norm_wf.startswith(norm_hooks + os.sep) or norm_hooks.startswith(norm_wf + os.sep):
                return True
            try:
                resolved_wf = str(Path(norm_wf).resolve())
                if resolved_wf == resolved_hooks or resolved_wf.startswith(resolved_hooks + os.sep) or resolved_hooks.startswith(resolved_wf + os.sep):
                    return True
            except Exception:
                pass

    for h in hook_names:
        h_path = os.path.join(norm_hooks, h)
        if os.path.isfile(h_path) and os.access(h_path, os.X_OK):
            return True

    # If target ref is provided (e.g. git switch <branch>), check if target ref commit tree contains hooks
    if target_ref:
        ref_to_probe = '@{-1}' if target_ref == '-' else target_ref
        res_toplevel = git_run_probe(['rev-parse', '--show-toplevel'], cwd=cwd)
        if res_toplevel and res_toplevel.returncode == 0 and res_toplevel.stdout.strip():
            repo_root = os.path.normpath(res_toplevel.stdout.strip())
            if norm_hooks == repo_root or norm_hooks.startswith(repo_root + os.sep):
                rel_hooks = os.path.relpath(norm_hooks, repo_root)
                for h in hook_names:
                    rel_hook = os.path.normpath(os.path.join(rel_hooks, h))
                    res_tree = git_run_probe(['ls-tree', ref_to_probe, '--', rel_hook], cwd=repo_root)
                    if res_tree and res_tree.returncode == 0 and res_tree.stdout.strip():
                        out = res_tree.stdout.strip()
                        if out.startswith('100755') or 'blob' in out:
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


def git_has_show_signature_configured(cwd=None):
    """Check if git repository has log.showSignature configured to true."""
    res = git_run_probe(['config', '--bool', 'log.showsignature'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip() == 'true':
        return True
    return False


def is_url_containing_credentials(url):
    """Check if a single URL contains embedded user/password/token credentials."""
    if not url or not isinstance(url, str):
        return False
    if re.match(r'^https?://[^/]*@', url, re.IGNORECASE):
        return True
    if '://' in url:
        after_scheme = url.split('://', 1)[1]
        host_part = after_scheme.split('/', 1)[0]
        if '@' in host_part:
            user_info = host_part.split('@', 1)[0]
            if ':' in user_info:
                return True
            if user_info.lower() in ('git', 'hg', 'svn'):
                return False
            return True
    return False


def git_remotes_have_credentials(cwd=None, config_source_args=None):
    """Check if any git remote URL contains embedded user/password/token credentials."""
    probe_cmd = ['config']
    if config_source_args:
        probe_cmd.extend(config_source_args)
    probe_cmd.extend(['--get-regexp', r'^(remote\..*\.(url|pushurl)|url\..*\.(insteadof|pushinsteadof))$'])
    res = git_run_probe(probe_cmd, cwd=cwd)
    if res and res.returncode == 0 and res.stdout:
        for line in res.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                if is_url_containing_credentials(parts[1].strip()) or is_url_containing_credentials(parts[0].strip()):
                    return True
    return False


def git_has_trailer_command_configured(cwd=None):
    """Check if git repository or config has trailer.*.cmd or trailer.*.command configured."""
    res = git_run_probe(['config', '--get-regexp', r'^trailer\..*\.(cmd|command)$'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        return True
    return False


def git_has_transport_executable_configured(cwd=None):
    """Check if git repository has transport or remote execution helpers configured in local repo config."""
    res = git_run_probe(['config', '--local', '--get-regexp', r'^(core\.sshcommand|core\.askpass|core\.pager|credential\..*helper|credential\.helper|remote\..*\.vcs|remote\..*\.uploadpack|remote\..*\.receivepack|remote\..*\.proxy|http\..*proxy)$'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        return True
    return False


def git_has_help_viewer_configured(cwd=None):
    """Check if git repository or config has help or man viewer configuration that can execute external programs."""
    res = git_run_probe(['config', '--get-regexp', r'^(help\.(format|browser|htmlpath)|man\..*|browser\..*)$'], cwd=cwd)
    if res and res.returncode == 0 and res.stdout.strip():
        for line in res.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if val and val.lower() not in ('false', '0'):
                    return True
    return False


def git_has_pager_configured(cwd=None, git_sub=None):
    """Check if git repository or config has core.pager, pager.<cmd>, or help viewer configured."""
    if git_sub == 'help' and git_has_help_viewer_configured(cwd):
        return True
    patterns = []
    if git_sub:
        patterns.append(rf'^pager\.{re.escape(git_sub)}$')
    if git_sub in {'log', 'show', 'diff', 'blame', 'shortlog', 'whatchanged', 'reflog', 'branch', 'tag'}:
        patterns.append(r'^core\.pager$')
    if not patterns:
        return False
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

    res_cfg = git_run_probe(['config', '--get-regexp', r'^remote\..*\.url$'], cwd=cwd)
    if res_cfg and res_cfg.returncode == 0 and res_cfg.stdout:
        for line in res_cfg.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                url = parts[1].strip()
                if is_unsafe_git_remote_url(url):
                    return True

    MAX_REMOTES_TO_RESOLVE = 5
    for r in remotes[:MAX_REMOTES_TO_RESOLVE]:
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

    if len(remotes) > MAX_REMOTES_TO_RESOLVE:
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
    res = git_run_probe(['status', '--porcelain', '-uall', '--ignore-submodules=all'], cwd=cwd)
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
    res = git_run_probe(['diff', '--cached', '--name-only', '--ignore-submodules=all'], cwd=cwd)
    if not res:
        return 'unknown'
    if res.returncode != 0:
        return 'safe'
    for path in res.stdout.splitlines():
        path = path.strip()
        if path and (matches_sensitive_pattern(path) or is_sensitive_credential_path(path, cwd)):
            return 'sensitive'

    if include_unstaged_tracked:
        res_unstaged = git_run_probe(['diff', '--name-only', '--ignore-submodules=all'], cwd=cwd)
        if res_unstaged and res_unstaged.returncode == 0:
            for path in res_unstaged.stdout.splitlines():
                path = path.strip()
                if path and (matches_sensitive_pattern(path) or is_sensitive_credential_path(path, cwd)):
                    return 'sensitive'
    return 'safe'


def is_valid_tool_binary_dir(cmd_name, exe_dir):
    """Check if the binary directory is trusted for auto-approved commands."""
    if exe_dir in SYSTEM_BIN_DIRS:
        return True
    home = os.path.expanduser('~')
    if cmd_name in ('cargo', 'cargo-fmt', 'rustfmt'):
        return exe_dir == os.path.join(home, '.cargo', 'bin')
    if cmd_name == 'go':
        return exe_dir in {os.path.join(home, 'go', 'bin'), '/usr/local/go/bin', '/usr/lib/go/bin'}
    if cmd_name in ('rg', 'ag'):
        return exe_dir == os.path.join(home, '.cargo', 'bin')
    return False


def is_trusted_executable_path(exe_path, workspace_paths, cwd, cmd_name=None):
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
    if exe_dir in SYSTEM_BIN_DIRS:
        return True
    # Commands eligible for auto-approval must only originate from system directories or legitimate toolchain dirs
    if cmd_name in AUTO_APPROVABLE_COMMANDS:
        return is_valid_tool_binary_dir(cmd_name, exe_dir)
    home = os.path.expanduser('~')
    trusted_exact_bin_dirs = {
        os.path.join(home, '.local', 'bin'),
        os.path.join(home, '.cargo', 'bin'),
        os.path.join(home, 'go', 'bin'),
        os.path.join(home, '.npm-global', 'bin'),
    }
    if exe_dir in trusted_exact_bin_dirs:
        return True
    for vm in ('.nvm', '.fnm', '.asdf', '.pyenv'):
        vm_dir = os.path.join(home, vm)
        if norm_exe.startswith(vm_dir + os.sep) and (os.path.basename(exe_dir) in ('bin', 'shims')):
            return True
    if norm_exe.startswith(os.path.join(os.sep + 'home', 'linuxbrew', '')) and os.path.basename(exe_dir) == 'bin':
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
        if a == '--line-prefix' or (a.startswith('--') and '--line-prefix'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 4):
            if '=' not in a:
                skip_next = True
            continue
        if a.startswith('--line-prefix='):
            continue
        if a == '--show-signature' or a.startswith(('--show-sig', '--show-signature=')):
            continue
        if a in ('--exit-code', '--quiet', '-q', '-z', '--null', '--no-color'):
            continue
        clean.append(a)
    return clean


def git_log_has_diff_options(args):
    """Check if git log / whatchanged options produce diffs, patches, or file listings."""
    for a in args:
        if a in ('-p', '-u', '-c', '--patch', '--patch-with-stat', '--patch-with-raw',
                 '--cc', '--raw', '--stat', '--numstat', '--shortstat', '--dirstat',
                 '--summary', '--name-only', '--name-status'):
            return True
        if a.startswith(('--patch', '--stat', '--numstat', '--shortstat', '--dirstat',
                         '--summary', '--raw', '--diff-merges', '--word-diff')):
            return True
        if a == '-L' or (a.startswith('-L') and not a.startswith('--')):
            return True
        if a.startswith('--') and '--line-range'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 5:
            return True
        if a.startswith('-') and not a.startswith('--') and a != '-' and any(c in a for c in ('p', 'u', 'c', 'L')):
            return True
    return False


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
        has_stdin = any(a == '--stdin' or (a.startswith('--') and len(a.split('=', 1)[0]) >= 5 and '--stdin'.startswith(a.split('=', 1)[0])) for a in safe_args)
        if has_stdin:
            return 'unknown'

        if git_sub == 'diff':
            if git_has_filter_configured(effective_cwd):
                return 'unknown'
            cmd = ['git', 'diff', '--name-status', '--line-prefix='] + [a for a in safe_args if a not in ('--name-only', '--name-status')] + ['--line-prefix=']
        elif git_sub == 'show':
            for a in safe_args:
                if not a.startswith('-') and ':' not in a:
                    res_t = git_run_probe(['cat-file', '-t', a], cwd=effective_cwd)
                    if res_t and res_t.returncode == 0 and res_t.stdout.strip() == 'blob':
                        return 'unknown'
            commit_args = [a for a in safe_args if ':' not in a and not a.startswith('--format=') and a not in ('--name-only', '--name-status')]
            cmd = ['git', 'show', '--name-status', '--format=', '--no-show-signature', '--line-prefix='] + commit_args + ['--line-prefix=']
        elif git_sub in ('log', 'whatchanged') and git_log_has_diff_options(args):
            has_line_range = any(a == '-L' or (a.startswith('-L') and not a.startswith('--')) or
                                 (a.startswith('--') and '--line-range'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 5)
                                 for a in safe_args)
            if has_line_range:
                cmd = ['git', 'log', '--format=', '--no-show-signature', '--line-prefix='] + [a for a in safe_args if not a.startswith('--format=') and a not in ('--name-only', '--name-status')] + ['--line-prefix=']
            else:
                cmd = ['git', 'log', '--name-status', '--format=', '--no-show-signature', '--line-prefix='] + [a for a in safe_args if not a.startswith('--format=') and a not in ('--name-only', '--name-status')] + ['--line-prefix=']
        elif git_sub == 'stash' and len(args) > 1 and args[1] == 'show':
            safe_stash = strip_git_output_options(args[2:])
            cmd = ['git', 'stash', 'show', '--name-status', '--line-prefix='] + [a for a in safe_stash if a not in ('--name-only', '--name-status')] + ['--line-prefix=']
        elif git_sub == 'stash' and len(args) > 1 and args[1] == 'list' and git_log_has_diff_options(args):
            safe_stash = strip_git_output_options(args[2:])
            cmd = ['git', 'stash', 'list', '--name-status', '--format=', '--no-show-signature', '--line-prefix='] + [a for a in safe_stash if not a.startswith('--format=') and a not in ('--name-only', '--name-status')] + ['--line-prefix=']
        elif git_sub == 'format-patch':
            log_args = [a for a in safe_args if not a.startswith(('--stdout', '--numbered', '-n', '-N', '--keep-subject', '-k'))]
            cmd = ['git', 'log', '--name-status', '--format=', '--no-show-signature', '--line-prefix='] + [a for a in log_args if a not in ('--name-only', '--name-status')] + ['--line-prefix=']
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
                        if not f:
                            continue
                        if '\t' in f:
                            tokens = f.split('\t')
                            for tok in tokens[1:]:
                                tok_s = tok.strip().strip('"')
                                if tok_s:
                                    parts.append(tok_s)
                        else:
                            parts.append(f)
                        if f.startswith('diff --git '):
                            rest = f[11:].strip()
                            m = re.match(r'^(?:\"a/([^\"]+)\"|a/(\S+))\s+(?:\"b/([^\"]+)\"|b/(\S+))$', rest)
                            if m:
                                parts.extend([g for g in m.groups() if g])
                            else:
                                toks = rest.split()
                                for tok in toks:
                                    t = tok.strip('\"')
                                    if t.startswith(('a/', 'b/')):
                                        t = t[2:]
                                    parts.append(t)
                        elif f.startswith('--- '):
                            p = f[4:].strip().strip('\"')
                            if p.startswith('a/'):
                                p = p[2:]
                            parts.append(p)
                        elif f.startswith('+++ '):
                            p = f[4:].strip().strip('\"')
                            if p.startswith('b/'):
                                p = p[2:]
                            parts.append(p)
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
    """Check if path targets git internal administrative files (.git, .git/config, .git/hooks, bare repo .git, core.hooksPath, etc.)."""
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
        resolved = norm

    # Also check against resolved git hooks directory (e.g. custom core.hooksPath)
    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
    target_cwds = [effective_cwd]
    curr_dir = norm if os.path.isdir(norm) else os.path.dirname(norm)
    while curr_dir and curr_dir != os.path.dirname(curr_dir) and not os.path.exists(curr_dir):
        curr_dir = os.path.dirname(curr_dir)
    if curr_dir and os.path.exists(curr_dir) and curr_dir not in target_cwds:
        target_cwds.append(curr_dir)

    for probe_cwd in target_cwds:
        res_hooks = git_run_probe(['rev-parse', '--path-format=absolute', '--git-path', 'hooks'], cwd=probe_cwd)
        if not res_hooks or res_hooks.returncode != 0 or not res_hooks.stdout.strip():
            res_hooks = git_run_probe(['rev-parse', '--git-path', 'hooks'], cwd=probe_cwd)
        if res_hooks and res_hooks.returncode == 0 and res_hooks.stdout.strip():
            hooks_dir = res_hooks.stdout.strip()
            if not os.path.isabs(hooks_dir):
                hooks_dir = os.path.join(probe_cwd, hooks_dir)
            norm_hooks = os.path.normpath(hooks_dir)
            if norm == norm_hooks or norm.startswith(norm_hooks + os.sep):
                return True
            try:
                resolved_hooks = str(Path(norm_hooks).resolve())
                if resolved == resolved_hooks or resolved.startswith(resolved_hooks + os.sep):
                    return True
            except Exception:
                pass

        # Also check against resolved git administrative directory (--git-dir)
        res_git = git_run_probe(['rev-parse', '--path-format=absolute', '--git-dir'], cwd=probe_cwd)
        if not res_git or res_git.returncode != 0 or not res_git.stdout.strip():
            res_git = git_run_probe(['rev-parse', '--git-dir'], cwd=probe_cwd)
        if res_git and res_git.returncode == 0 and res_git.stdout.strip():
            git_dir = res_git.stdout.strip()
            if not os.path.isabs(git_dir):
                git_dir = os.path.join(probe_cwd, git_dir)
            norm_git = os.path.normpath(git_dir)
            if norm == norm_git or norm.startswith(norm_git + os.sep):
                return True
            try:
                resolved_git = str(Path(norm_git).resolve())
                if resolved == resolved_git or resolved.startswith(resolved_git + os.sep):
                    return True
            except Exception:
                pass

    return False


def is_security_guard_path(path_str, cwd=None, visited=None, depth=0):
    """Check if path targets active or repository source permission classifiers, hooks, or agent security settings."""
    if not path_str or not isinstance(path_str, str):
        return False
    if depth > 3:
        return False
    if visited is None:
        visited = set()

    norm = expand_path(path_str, cwd)
    try:
        resolved = str(Path(norm).resolve())
    except Exception:
        resolved = norm

    visit_key = (norm, resolved)
    if visit_key in visited:
        return False
    visited.add(visit_key)

    basename = os.path.basename(norm)
    if basename in ('agy-permission-classifier.py', 'agy-inject-handoff.sh'):
        return True

    # Check if target resolves to this running classifier file or contains it
    try:
        self_resolved = str(Path(__file__).resolve())
        if resolved == self_resolved or self_resolved == norm:
            return True
        if self_resolved.startswith(resolved + os.sep) or self_resolved.startswith(norm + os.sep):
            return True
    except Exception:
        pass

    # Check deployed agent configuration directories (~/.claude, ~/.gemini)
    home = os.path.expanduser('~')
    for agent_dir in ('.claude', '.gemini'):
        d_path = os.path.join(home, agent_dir)
        norm_d = os.path.normpath(d_path)
        if norm == norm_d or norm.startswith(norm_d + os.sep) or resolved == norm_d or resolved.startswith(norm_d + os.sep):
            return True
        if norm_d.startswith(norm + os.sep) or norm_d.startswith(resolved + os.sep):
            return True

    # Check repository source paths that are symlinked or deployed into active runtime configuration
    norm_slash = norm.replace('\\', '/')
    res_slash = resolved.replace('\\', '/')
    for pattern in (
        '*/antigravity/hooks.json', 'antigravity/hooks.json',
        '*/.gemini/*/hooks.json', '.gemini/*/hooks.json',
        '*/.claude/*/hooks.json', '.claude/*/hooks.json',
        '*/claude/scripts/agy-*.py', 'claude/scripts/agy-*.py',
        '*/claude/scripts/agy-*.sh', 'claude/scripts/agy-*.sh',
        '*/claude/settings.json', 'claude/settings.json',
    ):
        if fnmatch.fnmatch(norm_slash, pattern) or fnmatch.fnmatch(res_slash, pattern):
            return True

    if basename == 'hooks.json':
        parts = norm.split(os.sep)
        if any(p in ('antigravity', '.gemini', '.claude', 'claude') for p in parts):
            return True

    # Check ancestor directories containing protected security hooks or classifiers
    for anc_pattern in (
        '*/antigravity', 'antigravity',
        '*/claude/scripts', 'claude/scripts',
        '*/claude', 'claude',
        '*/.gemini', '.gemini',
        '*/.claude', '.claude',
    ):
        if fnmatch.fnmatch(norm_slash, anc_pattern) or fnmatch.fnmatch(res_slash, anc_pattern):
            return True

    # Also check if norm is an existing directory containing security guard files on disk
    try:
        norm_path = Path(norm)
        if norm_path.is_dir() and norm not in ('/', expand_path('~', cwd, expand_tilde=True)) and not norm.startswith(('/usr', '/lib', '/bin', '/etc', '/var', '/proc', '/sys', '/dev')):
            if (norm_path / 'hooks.json').is_file():
                return True
            if (norm_path / 'agy-permission-classifier.py').is_file():
                return True
            walk_budget = 50
            for root, dirs, files in os.walk(norm):
                walk_budget -= 1
                if walk_budget <= 0:
                    break
                if '.git' in dirs:
                    dirs.remove('.git')
                for f in files:
                    if f in ('agy-permission-classifier.py', 'agy-inject-handoff.sh'):
                        return True
                    if f in ('hooks.json', 'settings.json'):
                        sub_rel = os.path.relpath(os.path.join(root, f), norm).replace('\\', '/')
                        if any(p in sub_rel.split('/') for p in ('.claude', 'claude', '.gemini', 'antigravity')):
                            return True
                for entry in files + dirs:
                    item_p = os.path.join(root, entry)
                    if os.path.islink(item_p):
                        try:
                            link_target = str(Path(item_p).resolve())
                            norm_target = os.path.normpath(expand_path(link_target, cwd))
                            real_target = os.path.realpath(norm_target)
                            if (norm_target, real_target) in visited:
                                continue
                            if is_security_guard_path(link_target, cwd, visited=visited, depth=depth + 1):
                                return True
                        except Exception:
                            pass
    except Exception:
        pass

    return False


def directory_contains_sensitive_files(dir_path, cwd=None, workspace_paths=None):
    """Check if an existing directory contains sensitive credential files in any descendants."""
    if not dir_path or not isinstance(dir_path, str):
        return False
    norm = expand_path(dir_path, cwd)
    try:
        norm_p = Path(norm)
        if not norm_p.is_dir():
            return False
        if norm in ('/', expand_path('~', cwd, expand_tilde=True)) or norm.startswith(('/usr', '/lib', '/bin', '/etc', '/var', '/proc', '/sys', '/dev')):
            return False
        if workspace_paths:
            if any(norm == expand_path(ws, cwd, expand_tilde=True) for ws in workspace_paths):
                return False
        for root, dirs, files in os.walk(norm):
            if '.git' in dirs:
                dirs.remove('.git')
            for f in files:
                if matches_sensitive_pattern(f):
                    return True
                full_f = os.path.join(root, f)
                if is_sensitive_credential_path(full_f, cwd):
                    return True
            for d in list(dirs):
                if matches_sensitive_pattern(d):
                    return True
            for entry in files + dirs:
                item_p = os.path.join(root, entry)
                if os.path.islink(item_p):
                    try:
                        link_target = str(Path(item_p).resolve())
                        if is_sensitive_credential_path(link_target, cwd):
                            return True
                    except Exception:
                        pass
    except Exception:
        pass
    return False


def get_inherited_go_setting(var_name):
    """Retrieve Go environment setting from environment variable or persistent go env configuration file."""
    env_val = os.environ.get(var_name)
    if env_val is not None and env_val.strip():
        return env_val.strip()
    goenv = os.environ.get('GOENV')
    candidate_paths = []
    if goenv:
        candidate_paths.append(Path(goenv).expanduser())
    home = Path(os.path.expanduser('~'))
    candidate_paths.extend([
        home / '.config' / 'go' / 'env',
        home / 'Library' / 'Application Support' / 'go' / 'env',
    ])
    for p in candidate_paths:
        try:
            if p.is_file():
                content = p.read_text(errors='replace')
                for line in content.splitlines():
                    line = line.strip()
                    if line.startswith(f'{var_name}='):
                        val = line.split('=', 1)[1].strip()
                        if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                            val = val[1:-1]
                        return val.strip()
        except Exception:
            pass
    return None


def get_inherited_goflags():
    """Retrieve GOFLAGS from environment variable or persistent go env configuration file."""
    return get_inherited_go_setting('GOFLAGS')


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
                check_dirs.add(expand_path(ws, cwd, expand_tilde=True))

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
    '-asmhdr', '-linkobj', '-dclpacks',
    '-traceprofile', '-blockprofile', '-memprofile', '-mutexprofile', '-cpuprofile',
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
            if is_git_admin_path(dest, cwd) or is_security_guard_path(dest, cwd):
                return 'force_ask', f"{tool_name} output modifying git repository metadata or security configuration requires confirmation: {dest}"
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
    ws_roots = [Path(expand_path(ws, effective_cwd, expand_tilde=True)).resolve() for ws in (workspace_paths or [effective_cwd])]

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
    ws_roots = [Path(expand_path(ws, effective_cwd, expand_tilde=True)).resolve() for ws in (workspace_paths or [effective_cwd])]

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


def normalize_shell_continuations(cmd_str: str) -> str:
    """Normalize shell line continuations (<backslash><newline>) outside single quotes.

    In POSIX shells and bash, an unquoted or double-quoted backslash followed immediately
    by a newline is completely removed along with the newline before expansions,
    substitutions, and tokenization occur.
    """
    if not cmd_str or ('\n' not in cmd_str and '\r' not in cmd_str):
        return cmd_str

    out = []
    i = 0
    n = len(cmd_str)
    in_single_quote = False
    in_double_quote = False

    while i < n:
        c = cmd_str[i]
        if in_single_quote:
            out.append(c)
            if c == "'":
                in_single_quote = False
            i += 1
            continue

        if c == "'":
            if not in_double_quote:
                in_single_quote = True
            out.append(c)
            i += 1
            continue

        if c == '"':
            if not in_single_quote:
                in_double_quote = not in_double_quote
            out.append(c)
            i += 1
            continue

        if c == '\\':
            # Check for line continuation: \ followed by \n (or \r\n)
            if i + 1 < n and cmd_str[i + 1] == '\n':
                i += 2
                continue
            if i + 2 < n and cmd_str[i + 1] == '\r' and cmd_str[i + 2] == '\n':
                i += 3
                continue
            # Escaped character: preserve \ and the following character
            out.append(c)
            if i + 1 < n:
                out.append(cmd_str[i + 1])
                i += 2
            else:
                i += 1
            continue

        out.append(c)
        i += 1

    return ''.join(out)


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
    if not isinstance(cmd_str, str):
        return None, None
    cmd_str = normalize_shell_continuations(cmd_str)
    in_single_quote = False
    in_double_quote = False
    escaped = False
    subcommands = []
    pipeline_links = []
    current_chars = []

    i = 0
    n = len(cmd_str)
    expect_command = False
    at_word_boundary = True

    while i < n:
        c = cmd_str[i]
        if escaped:
            current_chars.append(c)
            escaped = False
            at_word_boundary = False
            i += 1
            continue

        # Line continuation: \ followed immediately by \n (outside single quotes)
        if not in_single_quote and c == '\\' and i + 1 < n and cmd_str[i + 1] == '\n':
            i += 2
            continue

        if c == '\\':
            if in_single_quote:
                current_chars.append(c)
                at_word_boundary = False
            elif in_double_quote:
                if i + 1 < n and cmd_str[i + 1] in ('"', '\\', '$', '`', '\n'):
                    escaped = True
                    current_chars.append(c)
                else:
                    current_chars.append(c)
                at_word_boundary = False
            else:
                escaped = True
                current_chars.append(c)
                at_word_boundary = False
            i += 1
            continue

        if c == "'":
            if not in_double_quote:
                in_single_quote = not in_single_quote
            current_chars.append(c)
            at_word_boundary = False
            i += 1
            continue

        if c == '"':
            if not in_single_quote:
                in_double_quote = not in_double_quote
            current_chars.append(c)
            at_word_boundary = False
            i += 1
            continue

        if not in_single_quote and not in_double_quote:
            # Comment check: unquoted # at token beginning (start of command, or after unquoted whitespace/metacharacter)
            if c == '#' and at_word_boundary:
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
                at_word_boundary = True
                i += 2
                continue

            # Redirections with &: &>, &>>, >&, <&
            if two in ('&>',):
                current_chars.append(two)
                at_word_boundary = True
                i += 2
                continue
            if i > 0 and cmd_str[i - 1] in ('>', '<') and c == '&':
                current_chars.append(c)
                at_word_boundary = True
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
                if c != '\n':
                    expect_command = (c in ('|',))
                at_word_boundary = True
                i += 1
                continue

            if c.isspace() or c in ('<', '>', '(', ')'):
                current_chars.append(c)
                at_word_boundary = True
                i += 1
                continue

        current_chars.append(c)
        at_word_boundary = False
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


def extract_unquoted_redirections(subcmd_str):
    """Extract unquoted shell redirections from a subcommand string while respecting quotes and escapes.

    Returns (cleaned_cmd_str, list of (operator, target)).
    If a redirection syntax error occurs (e.g. operator with no target), returns (None, None).
    """
    if not subcmd_str or not isinstance(subcmd_str, str):
        return subcmd_str, []

    redirections = []
    cleaned_chars = []
    i = 0
    n = len(subcmd_str)
    in_sq = False
    in_dq = False
    escape = False

    while i < n:
        c = subcmd_str[i]

        if escape:
            cleaned_chars.append(c)
            escape = False
            i += 1
            continue

        if c == '\\' and not in_sq:
            escape = True
            cleaned_chars.append(c)
            i += 1
            continue

        if c == "'" and not in_dq:
            in_sq = not in_sq
            cleaned_chars.append(c)
            i += 1
            continue

        if c == '"' and not in_sq:
            in_dq = not in_dq
            cleaned_chars.append(c)
            i += 1
            continue

        if not in_sq and not in_dq:
            # Check for redirection operator starting at i
            # Check if there was a preceding fd number (e.g. 2>, 1>)
            fd = None
            if c in ('>', '<') or subcmd_str[i:i + 2] in ('&>',):
                k = len(cleaned_chars)
                while k > 0 and cleaned_chars[k - 1].isdigit():
                    k -= 1
                if k < len(cleaned_chars) and (k == 0 or cleaned_chars[k - 1].isspace()):
                    fd = ''.join(cleaned_chars[k:])
                    cleaned_chars = cleaned_chars[:k]

            op = None
            for cand in ('&>>', '&>', '>>', '>|', '>&', '<&', '<>', '>', '<'):
                if subcmd_str.startswith(cand, i):
                    op = cand
                    break

            if op is not None:
                i += len(op)
                while i < n and subcmd_str[i].isspace():
                    i += 1

                if i >= n:
                    return None, None

                target_chars = []
                t_in_sq = False
                t_in_dq = False
                t_esc = False
                while i < n:
                    tc = subcmd_str[i]
                    if t_esc:
                        target_chars.append(tc)
                        t_esc = False
                        i += 1
                        continue
                    if tc == '\\' and not t_in_sq:
                        if t_in_dq:
                            if i + 1 < n:
                                next_c = subcmd_str[i + 1]
                                if next_c in ('"', '\\', '$', '`'):
                                    target_chars.append(next_c)
                                    i += 2
                                    continue
                                elif next_c == '\n':
                                    i += 2
                                    continue
                                else:
                                    target_chars.append('\\')
                                    i += 1
                                    continue
                            else:
                                return None, None
                        else:
                            t_esc = True
                            i += 1
                            continue
                    if tc == '$' and not t_in_sq and not t_in_dq and i + 1 < n and subcmd_str[i + 1] == "'":
                        i += 2
                        ansi_chars = []
                        while i < n and subcmd_str[i] != "'":
                            if subcmd_str[i] == '\\' and i + 1 < n:
                                ansi_chars.append(subcmd_str[i:i + 2])
                                i += 2
                            else:
                                ansi_chars.append(subcmd_str[i])
                                i += 1
                        if i >= n:
                            return None, None
                        i += 1
                        try:
                            decoded_ansi = codecs.decode(''.join(ansi_chars), 'unicode_escape')
                            target_chars.extend(list(decoded_ansi))
                        except Exception:
                            return None, None
                        continue
                    if tc == "'" and not t_in_dq:
                        t_in_sq = not t_in_sq
                        i += 1
                        continue
                    if tc == '"' and not t_in_sq:
                        t_in_dq = not t_in_dq
                        i += 1
                        continue
                    if not t_in_sq and not t_in_dq:
                        if tc.isspace() or tc in (';', '&', '|', '>', '<'):
                            break
                    target_chars.append(tc)
                    i += 1

                if t_esc or t_in_sq or t_in_dq:
                    return None, None

                target_str = ''.join(target_chars)
                if not target_str:
                    return None, None
                redirections.append((op, target_str))
                cleaned_chars.append(' ')
                continue

        cleaned_chars.append(c)
        i += 1

    cleaned_str = ''.join(cleaned_chars).strip()
    return cleaned_str, redirections


def parse_refspec_dest(refspec, cwd=None):
    """Extract the destination branch name from a git refspec, resolving HEAD/@ to current branch."""
    spec = refspec.lstrip('+')
    if ':' in spec:
        dest = spec.split(':', 1)[1]
    else:
        dest = spec
    dest = re.sub(r'^refs/(heads|remotes/[^/]+)/', '', dest)
    if dest in ('HEAD', '@'):
        dest = git_get_current_branch(cwd)
    return dest


def is_git_ext_diff_opt(a):
    if not isinstance(a, str):
        return False
    opt = a.split('=', 1)[0]
    if not opt.startswith('--') or opt.startswith('--no-'):
        return False
    return ('--ext-diff'.startswith(opt) and len(opt) >= 5) or opt == '--ext-diff'


def is_git_no_ext_diff_opt(a):
    if not isinstance(a, str):
        return False
    opt = a.split('=', 1)[0]
    if not opt.startswith('--no-'):
        return False
    return ('--no-ext-diff'.startswith(opt) and len(opt) >= 8) or opt == '--no-ext-diff'


def is_git_textconv_opt(a):
    if not isinstance(a, str):
        return False
    opt = a.split('=', 1)[0]
    if not opt.startswith('--') or opt.startswith('--no-') or opt == '--text':
        return False
    return ('--textconv'.startswith(opt) and len(opt) >= 7) or opt == '--textconv'


def is_git_no_textconv_opt(a):
    if not isinstance(a, str):
        return False
    opt = a.split('=', 1)[0]
    if not opt.startswith('--no-'):
        return False
    return ('--no-textconv'.startswith(opt) and len(opt) >= 8) or opt == '--no-textconv'


def is_git_unsafe_exec_opt(a):
    if not isinstance(a, str):
        return False
    opt = a.split('=', 1)[0]
    if opt.startswith('--'):
        if ('--upload-pack'.startswith(opt) and len(opt) >= 9) or \
           ('--receive-pack'.startswith(opt) and len(opt) >= 10) or \
           ('--exec-path'.startswith(opt) and len(opt) >= 7) or \
           opt == '--exec':
            return True
    return False


def parse_grep_args(args):
    """Parse grep/egrep/fgrep argument list to identify pattern flags, pattern files, recursive mode, and positional arguments."""
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
    is_recursive = False
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
            if opt_name in ('--recursive', '--dereference-recursive') or (len(opt_name) >= 3 and ('--recursive'.startswith(opt_name) or '--dereference-recursive'.startswith(opt_name))):
                is_recursive = True
            elif opt_name == '--directories' or (len(opt_name) >= 5 and '--directories'.startswith(opt_name)):
                dir_val = val
                if dir_val is None and i + 1 < len(args):
                    i += 1
                    dir_val = args[i]
                if dir_val in ('recurse', 'r'):
                    is_recursive = True
            elif opt_name == '--file' or (len(opt_name) >= 5 and '--file'.startswith(opt_name)):
                has_pattern = True
                if val is not None:
                    pattern_files.append(val)
                elif i + 1 < len(args):
                    i += 1
                    pattern_files.append(args[i])
            elif opt_name == '--regexp' or (len(opt_name) >= 5 and '--regexp'.startswith(opt_name)):
                has_pattern = True
                if val is None and i + 1 < len(args):
                    i += 1
            elif opt_name == '--exclude-from' or (len(opt_name) >= 10 and '--exclude-from'.startswith(opt_name)):
                if val is not None:
                    pattern_files.append(val)
                elif i + 1 < len(args):
                    i += 1
                    pattern_files.append(args[i])
            elif val is None and (opt_name in GREP_OPTS_WITH_ARG or any(long_opt.startswith(opt_name) for long_opt in GREP_OPTS_WITH_ARG if long_opt.startswith('--'))):
                if i + 1 < len(args):
                    i += 1
            i += 1
            continue
        elif a.startswith('-') and len(a) > 1:
            if a[1:].isdigit():
                i += 1
                continue
            j = 1
            while j < len(a):
                c = a[j]
                if c in ('e', 'f', 'm', 'A', 'B', 'C', 'D', 'd'):
                    if j + 1 < len(a):
                        arg_val = a[j + 1:]
                        if arg_val.startswith('='):
                            arg_val = arg_val[1:]
                    elif i + 1 < len(args):
                        i += 1
                        arg_val = args[i]
                    else:
                        arg_val = ''
                    if c == 'e':
                        has_pattern = True
                    elif c == 'f':
                        has_pattern = True
                        if arg_val:
                            pattern_files.append(arg_val)
                    elif c == 'd':
                        if arg_val in ('recurse', 'r'):
                            is_recursive = True
                    break
                else:
                    if c in ('r', 'R'):
                        is_recursive = True
                    j += 1
            i += 1
            continue
        else:
            positionals.append(a)
            i += 1
    return has_pattern, pattern_files, is_recursive, positionals


RG_OPTS_WITH_ARG = {
    '-e', '--regexp',
    '-f', '--file',
    '-m', '--max-count',
    '-d', '--max-depth',
    '-A', '--after-context',
    '-B', '--before-context',
    '-C', '--context',
    '-t', '--type',
    '-T', '--type-not',
    '-g', '--glob',
    '--iglob',
    '-r', '--replace',
    '-E', '--encoding',
    '-M', '--max-columns',
    '--color',
    '--pre', '--hostname-bin',
    '--pre-glob',
    '--ignore-file', '--max-filesize',
    '--max-columns-preview',
    '--sort', '--sort-by',
    '--sortr', '--sortr-by',
    '--colors', '--type-add', '--type-clear',
    '--context-separator', '--path-separator',
    '--field-context-separator', '--field-match-separator',
    '--regex-size-limit', '--dfa-size-limit',
    '--hyperlink-format', '--generate',
}


def parse_rg_args(args):
    """Parse rg arguments to identify pattern flags, pattern files, positional operands, and globs."""
    has_pattern = False
    pattern_files = []
    positionals = []
    globs = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == '--':
            positionals.extend(args[i + 1:])
            break
        if a == '--files' or a.startswith('--files='):
            has_pattern = True
            i += 1
            continue
        if a.startswith('--'):
            opt_name = a.split('=', 1)[0]
            val = a.split('=', 1)[1] if '=' in a else None
            if opt_name == '--file' or (len(opt_name) >= 5 and '--file'.startswith(opt_name)):
                has_pattern = True
                if val is not None:
                    pattern_files.append(val)
                elif i + 1 < len(args):
                    i += 1
                    pattern_files.append(args[i])
            elif opt_name == '--regexp' or (len(opt_name) >= 5 and '--regexp'.startswith(opt_name)):
                has_pattern = True
                if val is None and i + 1 < len(args):
                    i += 1
            elif opt_name == '--ignore-file' or (len(opt_name) >= 10 and '--ignore-file'.startswith(opt_name)):
                if val is not None:
                    pattern_files.append(val)
                elif i + 1 < len(args):
                    i += 1
                    pattern_files.append(args[i])
            elif opt_name in ('--glob', '--iglob') or (len(opt_name) >= 5 and ('--glob'.startswith(opt_name) or '--iglob'.startswith(opt_name))):
                if val is not None:
                    globs.append(val)
                elif i + 1 < len(args):
                    i += 1
                    globs.append(args[i])
            elif val is None and (opt_name in RG_OPTS_WITH_ARG or any(long_opt.startswith(opt_name) for long_opt in RG_OPTS_WITH_ARG if long_opt.startswith('--'))):
                if i + 1 < len(args):
                    i += 1
            i += 1
            continue
        elif a.startswith('-') and len(a) > 1:
            if a[1:].isdigit():
                i += 1
                continue
            j = 1
            while j < len(a):
                c = a[j]
                if c in ('e', 'f', 'm', 'd', 'A', 'B', 'C', 't', 'T', 'g', 'r', 'E', 'M'):
                    if j + 1 < len(a):
                        arg_val = a[j + 1:]
                        if arg_val.startswith('='):
                            arg_val = arg_val[1:]
                    elif i + 1 < len(args):
                        i += 1
                        arg_val = args[i]
                    else:
                        arg_val = ''
                    if c == 'e':
                        has_pattern = True
                    elif c == 'f':
                        has_pattern = True
                        if arg_val:
                            pattern_files.append(arg_val)
                    elif c == 'g':
                        if arg_val:
                            globs.append(arg_val)
                    break
                else:
                    j += 1
            i += 1
            continue
        else:
            positionals.append(a)
            i += 1
    return has_pattern, pattern_files, positionals, globs


def is_ripgrep_no_config(args):
    """Check if --no-config is passed as a valid option to rg (before '--' and not as an option argument)."""
    i = 0
    n = len(args)
    while i < n:
        a = args[i]
        if a == '--':
            break
        if a == '--no-config' or (a.startswith('--') and '--no-config'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 6):
            return True
        if a.startswith('--'):
            opt_name = a.split('=', 1)[0]
            val = a.split('=', 1)[1] if '=' in a else None
            if val is None and (opt_name in RG_OPTS_WITH_ARG or any(long_opt.startswith(opt_name) for long_opt in RG_OPTS_WITH_ARG if long_opt.startswith('--'))):
                if i + 1 < n:
                    i += 1
            i += 1
            continue
        elif a.startswith('-') and len(a) > 1 and not a[1:].isdigit():
            j = 1
            while j < len(a):
                c = a[j]
                if c in ('e', 'f', 'm', 'd', 'A', 'B', 'C', 't', 'T', 'g', 'r', 'E', 'M'):
                    if j + 1 < len(a):
                        pass
                    elif i + 1 < n:
                        i += 1
                    break
                j += 1
            i += 1
            continue
        else:
            i += 1
    return False


def load_ripgrep_config_tokens(args, cwd=None, written_files=None):
    """Load and validate tokens from RIPGREP_CONFIG_PATH if applicable."""
    if is_ripgrep_no_config(args):
        return 'allow', None, []
    rg_cfg = os.environ.get('RIPGREP_CONFIG_PATH')
    if not rg_cfg or not rg_cfg.strip():
        return 'allow', None, []
    if is_sensitive_credential_path(rg_cfg, cwd) or matches_sensitive_pattern(rg_cfg):
        return 'deny', f"rg with RIPGREP_CONFIG_PATH targeting sensitive path is forbidden: {rg_cfg}", []
    if written_files:
        norm_cfg = os.path.normpath(expand_path(rg_cfg, cwd))
        real_cfg = os.path.realpath(norm_cfg)
        for wf in written_files:
            norm_wf = os.path.normpath(wf)
            real_wf = os.path.realpath(norm_wf)
            if (norm_cfg == norm_wf or norm_wf.startswith(norm_cfg + os.sep) or norm_cfg.startswith(norm_wf + os.sep) or
                real_cfg == real_wf or real_wf.startswith(real_cfg + os.sep) or real_wf.startswith(norm_wf + os.sep)):
                return 'force_ask', f"rg with RIPGREP_CONFIG_PATH modified earlier in command line requires confirmation: {rg_cfg}", []
    cfg_path = Path(expand_path(rg_cfg, cwd))
    rg_cfg_tokens = []
    if cfg_path.is_file():
        try:
            cfg_content = cfg_path.read_text(errors='replace')
            for line in cfg_content.splitlines():
                line_s = line.strip()
                if line_s and not line_s.startswith('#'):
                    try:
                        rg_cfg_tokens.extend(shlex.split(line_s, comments=True))
                    except Exception:
                        rg_cfg_tokens.extend(line_s.split())
            if any(tok.startswith(('--pre', '--hostname-bin')) or tok in ('--pre', '--hostname-bin') for tok in rg_cfg_tokens):
                return 'force_ask', f"rg with RIPGREP_CONFIG_PATH configuring preprocessor or helper program requires confirmation: {rg_cfg}", []
            if any(tok in ('-z', '--search-zip') or tok.startswith('--search-zip') or (tok.startswith('-') and not tok.startswith('--') and 'z' in tok) for tok in rg_cfg_tokens):
                return 'force_ask', f"rg with RIPGREP_CONFIG_PATH configuring compressed file search (-z/--search-zip) requires confirmation: {rg_cfg}", []
            if any(tok.startswith(('--hidden', '--no-ignore', '--follow')) or (tok.startswith('-') and not tok.startswith('--') and any(c in tok for c in ('L', 'u'))) for tok in rg_cfg_tokens):
                return 'ask', f"rg with RIPGREP_CONFIG_PATH configuring hidden files or symlink following requires confirmation: {rg_cfg}", []
            if any(is_credential_env_var(tok) for tok in rg_cfg_tokens):
                return 'deny', f"rg with RIPGREP_CONFIG_PATH referencing credential variable is forbidden: {rg_cfg}", []
            if any('$' in tok or '`' in tok for tok in rg_cfg_tokens):
                return 'ask', f"rg with RIPGREP_CONFIG_PATH containing unexpanded variable requires confirmation: {rg_cfg}", []
        except Exception:
            return 'force_ask', f"rg unable to safely read RIPGREP_CONFIG_PATH file: {rg_cfg}", []
    elif cfg_path.is_dir():
        return 'force_ask', f"rg with RIPGREP_CONFIG_PATH pointing to directory requires confirmation: {rg_cfg}", []
    return 'allow', None, rg_cfg_tokens


def extract_file_operands(base_cmd, args, rg_cfg_tokens=None):
    """
    Given base_cmd and its argument list, identify the arguments that represent
    file paths (for sensitive credential path checks), skipping text expressions,
    search patterns, and format strings.
    """
    if base_cmd in {'echo', 'printf'}:
        return []

    if base_cmd in {'grep', 'egrep', 'fgrep'}:
        has_pat_flag, pattern_files, is_rec, positionals = parse_grep_args(args)
        files = list(pattern_files)
        if has_pat_flag:
            files.extend(positionals)
        elif len(positionals) > 1:
            files.extend(positionals[1:])
        return files

    if base_cmd == 'rg':
        effective_args = list(rg_cfg_tokens or []) + list(args)
        has_pat_flag, pattern_files, positionals, *extra = parse_rg_args(effective_args)
        files = list(pattern_files)
        if has_pat_flag:
            files.extend(positionals)
        elif len(positionals) > 1:
            files.extend(positionals[1:])
        return files

    if base_cmd == 'ag':
        positionals = [a for a in args if not a.startswith('-')]
        has_pat_flag = any(a in ('-e', '--regexp') or a.startswith(('-e', '--regexp=')) for a in args)
        if has_pat_flag:
            return list(positionals)
        elif len(positionals) > 1:
            return list(positionals[1:])
        return []

    if base_cmd == 'jq':
        has_file_filter = any(a in ('-f', '--from-file') or a.startswith(('-f=', '--from-file=')) for a in args)
        files = []
        positionals = []
        skip_count = 0
        for i, a in enumerate(args):
            if skip_count > 0:
                skip_count -= 1
                continue
            if a in ('-f', '--from-file') and i + 1 < len(args):
                files.append(args[i + 1])
                skip_count = 1
                continue
            if a.startswith(('-f=', '--from-file=')):
                files.append(a.split('=', 1)[1])
                continue
            if a in ('--rawfile', '--slurpfile') and i + 2 < len(args):
                files.append(args[i + 2])
                skip_count = 2
                continue
            if a.startswith(('--rawfile=', '--slurpfile=')):
                files.append(a.split('=', 1)[1])
                continue
            if a in ('--arg', '--argjson') and i + 2 < len(args):
                skip_count = 2
                continue
            if not a.startswith('-'):
                positionals.append(a)
        if has_file_filter:
            files.extend(positionals)
        elif len(positionals) > 1:
            files.extend(positionals[1:])
        return files

    if base_cmd in {'sed', 'awk'}:
        has_script_flag = any(a in ('-e', '--expression', '-f', '--file') or a.startswith(('-e', '--expression=', '-f=', '--file=')) for a in args)
        files = []
        positionals = []
        skip_next = False
        for i, a in enumerate(args):
            if skip_next:
                skip_next = False
                continue
            if a in ('-f', '--file') and i + 1 < len(args):
                files.append(args[i + 1])
                skip_next = True
                continue
            if a.startswith(('-f=', '--file=')):
                files.append(a.split('=', 1)[1])
                continue
            if a in ('-e', '--expression') and i + 1 < len(args):
                skip_next = True
                continue
            if a.startswith(('-e', '--expression=')):
                continue
            if not a.startswith('-'):
                positionals.append(a)
        if has_script_flag:
            files.extend(positionals)
        elif len(positionals) > 1:
            files.extend(positionals[1:])
        return files

    if base_cmd == 'git':
        files = []
        skip_next = False
        for i, a in enumerate(args):
            if skip_next:
                skip_next = False
                continue
            if any(sub in args for sub in ('commit', 'tag')) and a in ('-m', '--message'):
                skip_next = True
                continue
            if any(sub in args for sub in ('commit', 'tag')) and (a.startswith('-m') or a.startswith('--message=')):
                continue
            val = a.split('=', 1)[1] if a.startswith('--') and '=' in a else a
            files.append(val)
        return files

    files = []
    in_pos_only = False
    for a in args:
        if in_pos_only:
            files.append(a)
            continue
        if a == '--':
            in_pos_only = True
            continue
        val = a.split('=', 1)[1] if a.startswith('--') and '=' in a else a
        files.append(val)
    return files


def classify_subcommand(tokens, workspace_paths, cwd, depth=0, raw_subcmd=None, written_files=None):
    """Classify a single atomic subcommand (list of tokens).

    Returns (verdict, reason) where verdict is 'allow', 'deny', or 'ask'.
    """
    if not tokens:
        return 'allow', 'Empty subcommand'

    if raw_subcmd:
        raw_subcmd = expand_unquoted_tildes(raw_subcmd, cwd)

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

    extracted_redirections = []
    if raw_subcmd:
        cleaned_cmd, extracted_redirections = extract_unquoted_redirections(raw_subcmd)
        if extracted_redirections is None:
            return 'ask', f"Subcommand with invalid redirection syntax requires confirmation: {raw_subcmd}"
        if cleaned_cmd:
            new_tokens = tokenize_subcommand(cleaned_cmd)
            if new_tokens is not None:
                idx = 0
                while idx < len(new_tokens) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', new_tokens[idx]):
                    tok = new_tokens[idx]
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
                cmd_tokens = new_tokens[idx:]
        else:
            cmd_tokens = []

    # Validate extracted redirections
    if extracted_redirections:
        for tok, target_raw in extracted_redirections:
            target = target_raw
            if target == '/dev/null':
                continue
            if tok in ('>&', '<&') and target.isdigit():
                continue
            if target.startswith(('/dev/tcp/', '/dev/udp/')):
                return 'ask', f"Network communication via redirection requires confirmation: {target}"
            if '$' in target or '*' in target or '?' in target:
                return 'ask', f"Redirection with unexpanded variable or glob requires approval: {target}"
            if is_sensitive_credential_path(target, cwd):
                return 'deny', f"Redirect targeting sensitive path is forbidden: {target}"
            if written_files:
                norm_target = os.path.normpath(expand_path(target, cwd))
                for wf in written_files:
                    norm_wf = os.path.normpath(wf)
                    if norm_target == norm_wf or norm_target.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_target + os.sep):
                        return 'force_ask', f"Redirection targeting path modified or created earlier in the command line requires confirmation: {target}"
            if tok == '<':
                if not is_path_in_workspaces(target, workspace_paths, cwd):
                    return 'ask', f"Input redirection reading outside workspace requires approval: {target}"
            else:
                if is_system_write_path(target, cwd):
                    return 'deny', f"Redirect targeting system write path is forbidden: {target}"
                if is_git_admin_path(target, cwd):
                    return 'ask', f"Redirect modifying git repository configuration or hooks requires confirmation: {target}"
                if is_security_guard_path(target, cwd):
                    return 'force_ask', f"Redirect modifying security configuration requires confirmation: {target}"
                if not is_path_in_workspaces(target, workspace_paths, cwd):
                    return 'ask', f"Redirecting output outside workspace requires approval: {target}"
        filtered_args = [unquote_token(t) for t in cmd_tokens[1:]]
    else:
        # Fallback: extract redirections from tokens if raw_subcmd was not provided
        filtered_args = []
        skip_next_arg = False
        for i, tok in enumerate(cmd_tokens[1:]):
            if skip_next_arg:
                skip_next_arg = False
                continue
            if tok in REDIRECTION_OPERATORS:
                skip_next_arg = True
                if i + 1 < len(cmd_tokens[1:]):
                    target = decode_shell_target(cmd_tokens[1:][i + 1])
                    if target == '/dev/null':
                        continue
                    if target.startswith(('/dev/tcp/', '/dev/udp/')):
                        return 'ask', f"Network communication via redirection requires confirmation: {target}"
                    if '$' in target or '*' in target or '?' in target:
                        return 'ask', f"Redirection with unexpanded variable or glob requires approval: {target}"
                    if is_sensitive_credential_path(target, cwd):
                        return 'deny', f"Redirect targeting sensitive path is forbidden: {target}"
                    if written_files:
                        norm_target = os.path.normpath(expand_path(target, cwd))
                        for wf in written_files:
                            norm_wf = os.path.normpath(wf)
                            if norm_target == norm_wf or norm_target.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_target + os.sep):
                                return 'force_ask', f"Redirection targeting path modified or created earlier in the command line requires confirmation: {target}"
                    if tok == '<':
                        if not is_path_in_workspaces(target, workspace_paths, cwd):
                            return 'ask', f"Input redirection reading outside workspace requires approval: {target}"
                    else:
                        if is_system_write_path(target, cwd):
                            return 'deny', f"Redirect targeting system write path is forbidden: {target}"
                        if is_git_admin_path(target, cwd):
                            return 'ask', f"Redirect modifying git repository configuration or hooks requires confirmation: {target}"
                        if is_security_guard_path(target, cwd):
                            return 'force_ask', f"Redirect modifying security configuration requires confirmation: {target}"
                        if not is_path_in_workspaces(target, workspace_paths, cwd):
                            return 'ask', f"Redirecting output outside workspace requires approval: {target}"
                continue
            filtered_args.append(unquote_token(tok))

    if not cmd_tokens:
        if extracted_redirections:
            return 'allow', 'Safe redirection command'
        return 'ask', f"Standalone environment assignment requires confirmation: {' '.join(tokens)}"

    raw_cmd = unquote_token(cmd_tokens[0])
    args = filtered_args

    # Resolve executable: prevent ./malicious/ls or workspace/untrusted PATH overrides
    if '/' in raw_cmd:
        resolved_exe = expand_path(raw_cmd, cwd)
        if written_files:
            for wf in written_files:
                if resolved_exe == wf or resolved_exe.startswith(wf + os.sep):
                    return 'force_ask', f"Executable was created or modified earlier in the command line: {raw_cmd} ({resolved_exe})"
        cand_base = os.path.basename(resolved_exe)
        if not is_trusted_executable_path(resolved_exe, workspace_paths, cwd, cand_base):
            return 'force_ask', f"Running non-system executable requires confirmation: {raw_cmd}"
        exe_dir = os.path.dirname(resolved_exe)
        if cand_base in AUTO_APPROVABLE_COMMANDS and not is_valid_tool_binary_dir(cand_base, exe_dir):
            return 'force_ask', f"Auto-approved command shadowed by non-system binary requires confirmation: {raw_cmd} ({resolved_exe})"
        base_cmd = cand_base
    else:
        path_env = os.environ.get('PATH', '')
        path_dirs = path_env.split(os.pathsep) if path_env else []
        if not path_dirs:
            path_dirs = os.defpath.split(os.pathsep)

        resolved_path = None
        for d in path_dirs:
            dir_path = expand_path(d, cwd) if d else cwd
            cand = expand_path(os.path.join(dir_path, raw_cmd), cwd)
            if written_files:
                for wf in written_files:
                    if cand == wf or cand.startswith(wf + os.sep):
                        return 'force_ask', f"Executable was created or modified earlier in the command line: {raw_cmd} ({cand})"
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                resolved_path = cand
                break

        if not resolved_path:
            resolved_path = shutil.which(raw_cmd)
            if resolved_path:
                norm_resolved = expand_path(resolved_path, cwd)
                if written_files:
                    for wf in written_files:
                        if norm_resolved == wf or norm_resolved.startswith(wf + os.sep):
                            return 'force_ask', f"Executable was created or modified earlier in the command line: {raw_cmd} ({resolved_path})"

        if resolved_path:
            if not is_trusted_executable_path(resolved_path, workspace_paths, cwd, raw_cmd):
                return 'force_ask', f"Running untrusted or shadowed executable requires confirmation: {raw_cmd} ({resolved_path})"
            exe_dir = os.path.dirname(resolved_path)
            if raw_cmd in AUTO_APPROVABLE_COMMANDS and not is_valid_tool_binary_dir(raw_cmd, exe_dir):
                return 'force_ask', f"Auto-approved command shadowed by non-system binary requires confirmation: {raw_cmd} ({resolved_path})"
        base_cmd = raw_cmd

    rg_cfg_tokens = []
    if base_cmd == 'rg':
        rg_verdict, rg_reason, rg_cfg_tokens = load_ripgrep_config_tokens(args, cwd, written_files)
        if rg_verdict != 'allow':
            return rg_verdict, rg_reason

    # Check for credential environment variables across all arguments (including patterns, filters, and messages)
    for arg in args:
        if is_credential_env_var(arg):
            return 'deny', f"Access to credential environment variable is forbidden: {arg}"

    # Check for sensitive files or credentials being targeted in file path arguments
    file_operands = extract_file_operands(base_cmd, args, rg_cfg_tokens=rg_cfg_tokens)
    for f in file_operands:
        if f != '/dev/null' and (is_sensitive_credential_path(f, cwd) or matches_sensitive_pattern(f)):
            return 'deny', f"Access to sensitive credential or key is forbidden: {f}"

    for arg in args:
        if arg.startswith('-') and not arg.startswith('--') and any(c in arg for c in ('o', 't')):
            for flag in ('o', 't'):
                if flag in arg:
                    sub_val = arg[arg.index(flag) + 1:].lstrip('=')
                    if sub_val and sub_val != '/dev/null' and (is_sensitive_credential_path(sub_val, cwd) or matches_sensitive_pattern(sub_val)):
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
        # Decode ANSI-C quotes and escape sequences across all arguments
        decoded_args = [decode_shell_arg(a) for a in args]

        is_recursive = False
        is_dir = False
        targets = []
        skip_options = False

        for a in decoded_args:
            if skip_options:
                targets.append(a)
                continue
            if a == '--':
                skip_options = True
                continue
            if a.startswith('-') and a != '-':
                if any(c in a for c in ('r', 'R')):
                    is_recursive = True
                if 'd' in a:
                    is_dir = True
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    if '--recursive'.startswith(opt) and len(opt) >= 3:
                        is_recursive = True
                    elif '--dir'.startswith(opt) and len(opt) >= 3:
                        is_dir = True
                    elif opt not in ('--force', '--interactive', '--verbose') and not any(opt.startswith(f) for f in ('--interactive=', '--preserve-root')):
                        return 'force_ask', f"rm with unverified option ({a}) requires confirmation: {' '.join(cmd_tokens)}"
                else:
                    SAFE_SHORT = {'f', 'i', 'I', 'v', 'r', 'R', 'd'}
                    if any(c not in SAFE_SHORT for c in a[1:]):
                        return 'force_ask', f"rm with unverified option ({a}) requires confirmation: {' '.join(cmd_tokens)}"
            else:
                targets.append(a)

        for t in targets:
            if is_system_write_path(t, cwd):
                return 'deny', f"Deletion targeting system path is forbidden: rm {t}"
            if is_sensitive_credential_path(t, cwd) or matches_sensitive_pattern(t):
                return 'deny', f"Deletion targeting sensitive credentials or keys is forbidden: rm {t}"

        if is_recursive or is_dir:
            for t in targets:
                t_norm = expand_path(t, cwd)
                if t in ('/', '/*', '~', '~/*', '$HOME') or t_norm in ('/', expand_path('~', cwd, expand_tilde=True)):
                    return 'deny', f"Recursive deletion targeting root or home directory is forbidden: rm {t}"
                for ws in (workspace_paths or [cwd]):
                    ws_norm = expand_path(ws, cwd, expand_tilde=True)
                    if t_norm == ws_norm:
                        return 'deny', f"Recursive deletion of entire workspace root is forbidden: rm {t}"
            return 'force_ask', f"Recursive or directory deletion requires confirmation: {' '.join(cmd_tokens)}"

        # If any argument contains unescaped/unresolved shell parameter expansions ($ or `), require confirmation
        for a in args:
            if any(c in a for c in ('$', '`')) or a.startswith(('<(', '>(')):
                return 'force_ask', f"rm with unresolved shell expansion requires confirmation: {' '.join(cmd_tokens)}"

        if written_files:
            for t in targets:
                t_norm = os.path.normpath(expand_path(t, cwd))
                for wf in written_files:
                    wf_norm = os.path.normpath(wf)
                    if t_norm == wf_norm or t_norm.startswith(wf_norm + os.sep) or wf_norm.startswith(t_norm + os.sep):
                        return 'force_ask', f"rm target was created or modified earlier in the command line: {t}"

        # Non-recursive rm on individual files inside workspace
        if targets and all(is_path_in_workspaces(t, workspace_paths, cwd) and not is_sensitive_credential_path(t, cwd) and not is_git_admin_path(t, cwd) and not is_security_guard_path(t, cwd) for t in targets):
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

        # Check for git help commands or options that invoke external viewers
        has_help = any(
            a == '--help' or (a.startswith('--') and '--help'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 5)
            for a in args
        )
        if git_sub == 'help' or has_help:
            return 'force_ask', f"Git help option or command dispatches to external viewer (help.format / man.viewer) and requires confirmation: {' '.join(cmd_tokens)}"

        # Git upload-pack, receive-pack, exec-path, or exec options can run arbitrary executables
        if any(is_git_unsafe_exec_opt(a) for a in args):
            return 'force_ask', f"Git command with custom remote pack/exec program requires confirmation: {' '.join(cmd_tokens)}"

        if not git_sub:
            return 'allow', 'git command query'

        # Check and validate git directory overrides (-C, --git-dir, --work-tree)
        # Top-level directory options must precede the subcommand
        git_dir_opts = []
        effective_cwd = cwd
        skip_dir_opt = False
        pre_sub_args = args[:git_sub_idx]
        for idx, a in enumerate(pre_sub_args):
            if skip_dir_opt:
                skip_dir_opt = False
                continue
            if a == '-C' and idx + 1 < len(pre_sub_args):
                git_dir_opts.append(('-C', pre_sub_args[idx + 1]))
                skip_dir_opt = True
            elif a.startswith('-C') and len(a) > 2 and not a.startswith('--'):
                git_dir_opts.append(('-C', a[2:]))
            elif a in ('--git-dir', '--work-tree') and idx + 1 < len(pre_sub_args):
                git_dir_opts.append((a, pre_sub_args[idx + 1]))
                skip_dir_opt = True
            elif a.startswith(('--git-dir=', '--work-tree=')):
                opt_k, opt_v = a.split('=', 1)
                git_dir_opts.append((opt_k, opt_v))

        for opt_k, opt_v in git_dir_opts:
            if is_sensitive_credential_path(opt_v, effective_cwd):
                return 'deny', f"git directory option {opt_k} targeting sensitive path is forbidden: {opt_v}"
            if not is_path_in_workspaces(opt_v, workspace_paths, effective_cwd):
                return 'force_ask', f"git {opt_k} targeting directory outside workspace requires confirmation: {opt_v}"
            if opt_k in ('--git-dir', '--work-tree'):
                return 'force_ask', f"git with alternate repository or work-tree ({opt_k}) requires confirmation: {' '.join(cmd_tokens)}"
            if opt_k == '-C':
                effective_cwd = expand_path(opt_v, effective_cwd)

        cwd = effective_cwd
        sub_args = args[git_sub_idx:]

        # Git repository queries outside declared workspaces require confirmation
        if git_sub not in {'version', 'check-ref-format'}:
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git {git_sub} in directory outside workspace requires confirmation: {cwd}"
            res_toplevel = git_run_probe(['rev-parse', '--show-toplevel'], cwd=cwd)
            if res_toplevel and res_toplevel.returncode == 0 and res_toplevel.stdout.strip():
                worktree_root = res_toplevel.stdout.strip()
                if not is_path_in_workspaces(worktree_root, workspace_paths, cwd):
                    return 'force_ask', f"git {git_sub} repository worktree ({worktree_root}) outside workspace requires confirmation: {cwd}"
            res_git_dir = git_run_probe(['rev-parse', '--git-dir'], cwd=cwd)
            if res_git_dir and res_git_dir.returncode == 0 and res_git_dir.stdout.strip():
                git_dir_path = expand_path(res_git_dir.stdout.strip(), cwd)
                if not is_path_in_workspaces(git_dir_path, workspace_paths, cwd):
                    return 'force_ask', f"git {git_sub} repository directory ({git_dir_path}) outside workspace requires confirmation: {cwd}"

        # Check for git output options across all git commands (including GNU option abbreviations)
        git_outs = []
        skip_arg = False
        for i, a in enumerate(args):
            if skip_arg:
                skip_arg = False
                continue
            if git_sub in ('commit', 'tag') and a in ('-m', '--message'):
                skip_arg = True
                continue
            if git_sub in ('commit', 'tag') and (a.startswith('-m') or a.startswith('--message=')):
                continue
            if a.startswith('--o') and '=' in a:
                opt, val = a.split('=', 1)
                if ('--output'.startswith(opt) and len(opt) >= 4) or ('--output-directory'.startswith(opt) and len(opt) >= 4):
                    git_outs.append(decode_shell_target(val))
            elif a.startswith('--o') and (('--output'.startswith(a) and len(a) >= 4) or ('--output-directory'.startswith(a) and len(a) >= 4)):
                if i + 1 < len(args):
                    git_outs.append(decode_shell_target(args[i + 1]))
                    skip_arg = True
            elif a in ('--output', '-o', '--output-directory') and i + 1 < len(args):
                git_outs.append(decode_shell_target(args[i + 1]))
                skip_arg = True
            elif a.startswith('-o') and len(a) > 2 and not a.startswith('--'):
                git_outs.append(decode_shell_target(a[2:].lstrip('=')))

        for git_out in git_outs:
            if not git_out:
                continue
            if is_sensitive_credential_path(git_out, cwd) or is_system_write_path(git_out, cwd):
                return 'deny', f"git {git_sub} --output targeting sensitive or system path is forbidden: {git_out}"
            if is_git_admin_path(git_out, cwd) or is_security_guard_path(git_out, cwd):
                return 'force_ask', f"git {git_sub} --output targeting git administrative file or security configuration requires confirmation: {git_out}"
            if not is_path_in_workspaces(git_out, workspace_paths, cwd):
                return 'force_ask', f"git {git_sub} --output outside workspace requires approval: {git_out}"

        # Check for config overrides via -c or --config-env (top-level options)
        for i, a in enumerate(pre_sub_args):
            cfg_opt = None
            if a in ('-c', '--config-env') and i + 1 < len(pre_sub_args):
                cfg_opt = pre_sub_args[i + 1]
            elif a.startswith('--config-env='):
                cfg_opt = a.split('=', 1)[1]
            elif a.startswith('-c') and len(a) > 2 and not a.startswith('--'):
                cfg_opt = a[2:].lstrip('=')
            if cfg_opt is not None or a in ('-c', '--config-env') or a.startswith(('-c', '--config-env=')):
                return 'force_ask', f"Git command with configuration override (-c/--config-env) requires confirmation: {' '.join(cmd_tokens)}"

        # External diff/textconv drivers can execute arbitrary commands configured in gitconfig/attributes
        for a in args:
            if is_git_ext_diff_opt(a) or is_git_textconv_opt(a):
                return 'force_ask', f"Git command with external diff/filter driver requires confirmation: {' '.join(cmd_tokens)}"

        # Git upload-pack, receive-pack, exec-path, or exec options can run arbitrary executables
        if any(is_git_unsafe_exec_opt(a) for a in pre_sub_args):
            return 'force_ask', f"Git command with custom exec-path requires confirmation: {' '.join(cmd_tokens)}"
        for a in sub_args:
            if is_git_unsafe_exec_opt(a):
                return 'force_ask', f"Git command with custom remote pack/exec program requires confirmation: {' '.join(cmd_tokens)}"
            if a in ('-u',) and git_sub in {'clone', 'fetch', 'ls-remote'}:
                return 'force_ask', f"Git command with custom upload-pack option (-u) requires confirmation: {' '.join(cmd_tokens)}"

        # Configured core.pager or pager.<cmd> can execute arbitrary commands
        has_paginate = any(
            a == '-p' or (a.startswith('--') and '--paginate'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 5)
            for a in args[:git_sub_idx]
        )
        if has_paginate:
            return 'force_ask', f"git with pagination flag forces configured pager execution: {' '.join(cmd_tokens)}"
        has_no_pager = any(
            a in ('--no-pager', '-P') or (a.startswith('--') and '--no-pager'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 5)
            for a in args[:git_sub_idx]
        )
        if not has_no_pager and git_has_pager_configured(cwd, git_sub):
            return 'force_ask', f"git {git_sub} with configured pager requires confirmation: {' '.join(cmd_tokens)}"


        # Reject unverified shell parameter expansions and substitutions in Git arguments
        for a in args:
            if any(c in a for c in ('$', '`')) or a.startswith(('<(', '>(')):
                return 'ask', f"Git command with shell parameter expansion or substitution requires confirmation: {' '.join(cmd_tokens)}"

        # Check git arguments for sensitive file paths or <rev>:<path> expressions targeting sensitive files
        skip_next = False
        for a in args:
            if skip_next:
                skip_next = False
                continue
            if git_sub in ('commit', 'tag') and a in ('-m', '--message'):
                skip_next = True
                continue
            if git_sub in ('commit', 'tag') and (a.startswith('-m') or a.startswith('--message=')):
                continue
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
                dest = parse_refspec_dest(spec, cwd=cwd)
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
            if git_has_active_hooks(cwd, ('reference-transaction',), written_files=written_files):
                return 'force_ask', f"Git fetch with active repository hook requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_transport_executable_configured(cwd):
                return 'force_ask', f"Git fetch with configured transport program or credential helper requires confirmation: {' '.join(cmd_tokens)}"
            if git_remotes_have_executable_helpers(cwd):
                return 'force_ask', f"Git fetch with configured remote helper URL or rewrite requires confirmation: {' '.join(cmd_tokens)}"
            def is_upload_pack_opt(a):
                if a == '-u' or a.startswith('-u='):
                    return True
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    if opt.startswith('--upload') and '--upload-pack'.startswith(opt):
                        return True
                return False
            if any(is_upload_pack_opt(a) for a in args):
                return 'force_ask', f"Git fetch with custom upload-pack program requires confirmation: {' '.join(cmd_tokens)}"
            def is_fetch_prune_opt(a):
                if a in ('-p', '-P') or a.startswith(('-p=', '-P=')):
                    return True
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    if ('--prune'.startswith(opt) and len(opt) >= 5) or ('--prune-tags'.startswith(opt) and len(opt) >= 8):
                        return True
                return False
            for a in args:
                if is_fetch_prune_opt(a):
                    return 'force_ask', f"Git fetch with prune option ({a}) requires confirmation: {' '.join(cmd_tokens)}"

            has_fetch_force = any(
                a in ('-f', '--force', '--update-head-ok', '--update-shallow', '--refmap') or
                a.split('=', 1)[0] in ('--force', '--update-head-ok', '--update-shallow', '--refmap') or
                (a.startswith('--') and (
                    ('--force'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 5) or
                    ('--update-head-ok'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 9) or
                    ('--update-shallow'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 10) or
                    ('--refmap'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 5)
                )) or
                (a.startswith('-') and not a.startswith('--') and 'f' in a)
                for a in args
            )
            if has_fetch_force:
                return 'force_ask', f"Git fetch with force or update-head-ok option requires confirmation: {' '.join(cmd_tokens)}"

            if any(a == '--stdin' or (a.startswith('--') and len(a.split('=', 1)[0]) >= 5 and '--stdin'.startswith(a.split('=', 1)[0])) for a in args):
                return 'force_ask', f"Git fetch reading refspecs from stdin requires confirmation: {' '.join(cmd_tokens)}"

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

            # Inspect configured remote fetch refspecs
            res_fetch_cfg = git_run_probe(['config', '--get-regexp', r'^remote\..*\.fetch$'], cwd=cwd)
            if res_fetch_cfg and res_fetch_cfg.returncode == 0 and res_fetch_cfg.stdout:
                for line in res_fetch_cfg.stdout.splitlines():
                    parts = line.split(None, 1)
                    if len(parts) == 2:
                        cfg_refspec = parts[1].strip()
                        # Normal safe fetch refspec is [+]<src>:refs/remotes/<remote>/<dst>
                        if ':' in cfg_refspec:
                            _, dst_ref = cfg_refspec.split(':', 1)
                            clean_dst = dst_ref.strip()
                            if not clean_dst.startswith('refs/remotes/'):
                                return 'force_ask', f"git fetch with configured refspec updating non-remote ref requires confirmation: {cfg_refspec}"
                        else:
                            return 'force_ask', f"git fetch with configured refspec requires confirmation: {cfg_refspec}"

            res_prune = git_run_probe(['config', '--bool', 'fetch.prune'], cwd=cwd)
            if res_prune and res_prune.returncode == 0 and res_prune.stdout.strip() == 'true':
                return 'force_ask', f"git fetch with configured fetch.prune requires confirmation: {' '.join(cmd_tokens)}"
            res_prune_tags = git_run_probe(['config', '--bool', 'fetch.pruneTags'], cwd=cwd)
            if res_prune_tags and res_prune_tags.returncode == 0 and res_prune_tags.stdout.strip() == 'true':
                return 'force_ask', f"git fetch with configured fetch.pruneTags requires confirmation: {' '.join(cmd_tokens)}"

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
            SAFE_SWITCH_FLAGS = {'-q', '--quiet', '--progress', '--no-guess', '--ignore-other-worktrees', '--'}
            for a in args[1:]:
                if a.startswith('-') and a != '-' and a not in SAFE_SWITCH_FLAGS:
                    return 'force_ask', f"Switching with option requires confirmation: {' '.join(cmd_tokens)}"
            positionals = [a for a in args[1:] if not a.startswith('-') or a == '-']
            if len(positionals) != 1:
                return 'force_ask', f"Git switch requires explicit branch target: {' '.join(cmd_tokens)}"
            target_branch = positionals[0]
            if target_branch != '-':
                has_no_guess = any(a == '--no-guess' for a in args)
                if not has_no_guess:
                    res_repo = git_run_probe(['rev-parse', '--is-inside-work-tree'], cwd=cwd)
                    if res_repo and res_repo.returncode == 0:
                        res_local = git_run_probe(['show-ref', '--verify', '--quiet', f'refs/heads/{target_branch}'], cwd=cwd)
                        if not res_local or res_local.returncode != 0:
                            res_remote = git_run_probe(['for-each-ref', '--format=%(refname)', f'refs/remotes/*/{target_branch}'], cwd=cwd)
                            if res_remote and res_remote.returncode == 0 and res_remote.stdout.strip():
                                return 'force_ask', f"git switch creates local tracking branch from remote for '{target_branch}': {' '.join(cmd_tokens)}"
            if git_has_active_hooks(cwd, ('post-checkout', 'post-index-change', 'reference-transaction'), written_files=written_files, target_ref=target_branch):
                return 'force_ask', f"git switch with active repository hook requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_fsmonitor_configured(cwd):
                return 'force_ask', f"git switch with configured core.fsmonitor hook requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_filter_configured(cwd):
                return 'force_ask', f"git switch with configured filter driver requires confirmation: {' '.join(cmd_tokens)}"
            res_repo = git_run_probe(['rev-parse', '--is-inside-work-tree'], cwd=cwd)
            if res_repo and res_repo.returncode == 0:
                ref_to_probe = '@{-1}' if target_branch == '-' else target_branch
                res_toplevel = git_run_probe(['rev-parse', '--show-toplevel'], cwd=cwd)
                if res_toplevel and res_toplevel.returncode == 0 and res_toplevel.stdout.strip():
                    repo_root = os.path.normpath(res_toplevel.stdout.strip())
                    res_ref = git_run_probe(['rev-parse', '--verify', f'{ref_to_probe}^{{commit}}'], cwd=repo_root)
                    if res_ref and res_ref.returncode == 0:
                        res_head = git_run_probe(['rev-parse', '--verify', 'HEAD'], cwd=repo_root)
                        if res_head and res_head.returncode == 0:
                            res_diff = git_run_probe(['diff', '--name-only', 'HEAD', ref_to_probe], cwd=repo_root)
                        else:
                            res_diff = git_run_probe(['ls-tree', '-r', '--name-only', ref_to_probe], cwd=repo_root)
                        if res_diff and res_diff.returncode == 0:
                            for cf in res_diff.stdout.splitlines():
                                cf = cf.strip()
                                if not cf:
                                    continue
                                full_cf = os.path.normpath(os.path.join(repo_root, cf))
                                if is_sensitive_credential_path(full_cf, cwd) or matches_sensitive_pattern(cf) or is_sensitive_credential_path(cf, cwd):
                                    return 'deny', f"git switch modifying sensitive credential path is forbidden: {cf}"
                                if is_security_guard_path(full_cf, cwd) or is_security_guard_path(cf, cwd):
                                    return 'force_ask', f"git switch modifying protected security guard or classifier requires confirmation: {cf}"
                                if is_git_admin_path(full_cf, cwd) or is_git_admin_path(cf, cwd):
                                    return 'force_ask', f"git switch modifying git admin path requires confirmation: {cf}"
                                if not is_path_in_workspaces(full_cf, workspace_paths, cwd):
                                    return 'force_ask', f"git switch modifies path outside workspace: {cf}"
                        else:
                            return 'force_ask', f"git switch unable to verify target branch diff: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git switch'

        # Git branch: only allow read-only queries
        if git_sub == 'branch':
            MUTATING_BRANCH_LONGS = (
                '--edit-description',
                '--set-upstream-to',
                '--unset-upstream',
                '--delete',
                '--move',
                '--copy',
                '--force',
                '--track',
                '--set-upstream',
            )
            for a in args[1:]:
                if a.startswith('-') and not a.startswith('--') and a != '-':
                    if any(c in a for c in ('d', 'D', 'm', 'M', 'c', 'C', 'f', 'u')):
                        return 'force_ask', f"Mutating branches requires confirmation: {' '.join(cmd_tokens)}"
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    for target_long in MUTATING_BRANCH_LONGS:
                        if target_long.startswith(opt) and len(opt) >= 3:
                            return 'force_ask', f"Mutating branches requires confirmation ({opt}): {' '.join(cmd_tokens)}"
            positionals = [a for a in args[1:] if not a.startswith('-')]
            # Positional arguments in git branch create/reset branches unless --list is explicitly used
            # Note: -l means --create-reflog when creating a branch, so only --list is safe with positionals
            if positionals and not any(a == '--list' or a.startswith('--list=') for a in args):
                return 'force_ask', f"Branch creation or modification requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git branch query'

        # Git tag: only allow listing
        if git_sub == 'tag':
            for a in args[1:]:
                if a.startswith('-') and not a.startswith('--') and a != '-':
                    if any(c in a for c in ('d', 'a', 'f', 'm', 's', 'u')):
                        return 'force_ask', f"Creating or deleting tags requires confirmation: {' '.join(cmd_tokens)}"
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    for mut in ('--delete', '--force', '--annotate', '--sign'):
                        if mut.startswith(opt) and len(opt) >= 3:
                            return 'force_ask', f"Creating or deleting tags requires confirmation ({opt}): {' '.join(cmd_tokens)}"
            positionals = [a for a in args[1:] if not a.startswith('-')]
            if positionals and not any(a in ('-l', '--list') or a.startswith('--list=') for a in args):
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
            is_verbose_or_get_url = any(
                (a.startswith('-') and not a.startswith('--') and 'v' in a) or
                (a.startswith('--') and ('--verbose'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 5)) or
                a == 'get-url' or a.startswith('get-url')
                for a in args
            )
            if is_verbose_or_get_url:
                if git_remotes_have_credentials(cwd):
                    return 'deny', f"git remote query exposing embedded credentials in remote URL is forbidden: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git remote query'

        # Git commands that inspect or refresh the index/working tree execute core.fsmonitor if configured
        if git_sub in {'status', 'diff', 'ls-files', 'stash', 'add', 'commit', 'checkout', 'restore', 'reset', 'worktree', 'describe', 'switch'}:
            if git_has_fsmonitor_configured(cwd):
                return 'force_ask', f"git {git_sub} with configured core.fsmonitor hook requires confirmation: {' '.join(cmd_tokens)}"

        if git_sub == 'status':
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git status in directory outside workspace requires confirmation: {cwd}"
            if git_has_active_hooks(cwd, ('post-index-change',), written_files=written_files):
                return 'force_ask', f"git status with active repository hook (post-index-change) requires confirmation: {' '.join(cmd_tokens)}"

        # Git diff
        if git_sub == 'diff':
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git diff in directory outside workspace requires confirmation: {cwd}"
            ext_diff_enabled = None
            textconv_enabled = None
            for a in args:
                if a == '--':
                    break
                if is_git_ext_diff_opt(a):
                    ext_diff_enabled = True
                elif is_git_no_ext_diff_opt(a):
                    ext_diff_enabled = False
                if is_git_textconv_opt(a):
                    textconv_enabled = True
                elif is_git_no_textconv_opt(a):
                    textconv_enabled = False

            if ext_diff_enabled is True:
                return 'force_ask', f"git diff with external diff driver requires confirmation: {' '.join(cmd_tokens)}"
            if textconv_enabled is True:
                return 'force_ask', f"git diff with textconv driver requires confirmation: {' '.join(cmd_tokens)}"

            has_no_ext = (ext_diff_enabled is False)
            has_no_textconv = (textconv_enabled is False)
            ext_diff_env = os.environ.get('GIT_EXTERNAL_DIFF')
            if not has_no_ext and ext_diff_env and ext_diff_env.strip():
                if is_sensitive_credential_path(ext_diff_env, cwd) or matches_sensitive_pattern(ext_diff_env):
                    return 'deny', f"git diff with GIT_EXTERNAL_DIFF referencing sensitive path is forbidden: {ext_diff_env}"
                return 'force_ask', f"git diff with inherited GIT_EXTERNAL_DIFF executable requires confirmation: {ext_diff_env}"
            if not has_no_ext and git_has_ext_diff_driver(cwd):
                return 'force_ask', f"git diff with configured external diff driver requires confirmation: {' '.join(cmd_tokens)}"
            if not has_no_textconv and git_has_textconv_driver(cwd):
                return 'force_ask', f"git diff with configured textconv driver requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_filter_configured(cwd):
                return 'force_ask', f"git diff with configured filter driver requires confirmation: {' '.join(cmd_tokens)}"

            # Inspect file operands and pathspecs for sensitive files and workspace containment
            diff_operands = []
            if '--' in args:
                idx = args.index('--')
                diff_operands.extend(args[idx + 1:])
                pre_dash = args[1:idx]
            else:
                pre_dash = args[1:]
            is_no_index = any(a == '--no-index' for a in pre_dash)
            has_stdin = any(a == '--stdin' or (a.startswith('--') and len(a.split('=', 1)[0]) >= 5 and '--stdin'.startswith(a.split('=', 1)[0])) for a in pre_dash)
            if has_stdin:
                return 'force_ask', f"git diff reading inputs from stdin requires confirmation: {' '.join(cmd_tokens)}"

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

            if written_files:
                for wf in written_files:
                    if matches_sensitive_pattern(wf) or is_sensitive_credential_path(wf, cwd):
                        return 'deny', f"git diff following modification of sensitive file is forbidden: {wf}"
                return 'force_ask', f"git diff following earlier file or working-tree modifications in command line requires confirmation: {' '.join(cmd_tokens)}"

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
                if stash_sub in ('list', 'show'):
                    args_options = args[:args.index('--')] if '--' in args else args
                    has_no_sig = any(a == '--no-show-signature' for a in args_options)
                    has_sig = any(a == '--show-signature' or a.startswith(('--show-sig', '--show-signature=')) or
                                  (a.startswith(('--format=', '--pretty=')) and any(g in a for g in ('%G', '%g'))) for a in args_options)
                    if has_sig or (not has_no_sig and git_has_show_signature_configured(cwd)):
                        return 'force_ask', f"git stash {stash_sub} with signature display invokes external gpg program: {' '.join(cmd_tokens)}"
                    if git_has_gpg_program_configured(cwd) and any(a.startswith(('--format=', '--pretty=')) for a in args_options):
                        return 'force_ask', f"git stash {stash_sub} with formatted output and custom gpg.program requires confirmation: {' '.join(cmd_tokens)}"

                    has_no_ext = any(a == '--no-ext-diff' for a in args_options)
                    has_no_textconv = any(a == '--no-textconv' for a in args_options)
                    ext_diff_env = os.environ.get('GIT_EXTERNAL_DIFF')
                    if not has_no_ext and ext_diff_env and ext_diff_env.strip():
                        if is_sensitive_credential_path(ext_diff_env, cwd) or matches_sensitive_pattern(ext_diff_env):
                            return 'deny', f"git stash {stash_sub} with GIT_EXTERNAL_DIFF referencing sensitive path is forbidden: {ext_diff_env}"
                        return 'force_ask', f"git stash {stash_sub} with inherited GIT_EXTERNAL_DIFF executable requires confirmation: {ext_diff_env}"
                    if not has_no_ext and git_has_ext_diff_driver(cwd):
                        return 'force_ask', f"git stash {stash_sub} with configured external diff driver requires confirmation: {' '.join(cmd_tokens)}"
                    if not has_no_textconv and git_has_textconv_driver(cwd):
                        return 'force_ask', f"git stash {stash_sub} with configured textconv driver requires confirmation: {' '.join(cmd_tokens)}"

                    has_diff = stash_sub == 'show' or git_log_has_diff_options(args)
                    if has_diff:
                        if written_files:
                            for wf in written_files:
                                if matches_sensitive_pattern(wf) or is_sensitive_credential_path(wf, cwd):
                                    return 'deny', f"git stash {stash_sub} following modification of sensitive file is forbidden: {wf}"
                            return 'force_ask', f"git stash {stash_sub} following earlier file or working-tree modifications requires confirmation: {' '.join(cmd_tokens)}"
                        probe_res = git_command_touches_sensitive_files('stash', args, cwd)
                        if probe_res == 'sensitive':
                            return 'deny', f"git stash {stash_sub} touching sensitive credential files in patch output is forbidden: {' '.join(cmd_tokens)}"
                        if probe_res == 'unknown':
                            return 'force_ask', f"git stash {stash_sub} patch cannot be verified safely: {' '.join(cmd_tokens)}"
                    return 'allow', f"Safe git stash {stash_sub}"
            return 'force_ask', f"Git stash modification requires confirmation: {' '.join(cmd_tokens)}"

        if git_sub == 'worktree':
            if any(a in ('add', 'remove', 'prune', 'lock', 'unlock', 'move', 'repair') for a in args):
                if 'add' in args:
                    if any(a in ('-B', '-f', '--force') or a.startswith(('-B', '-f', '--force')) for a in args):
                        return 'force_ask', f"git worktree add with branch reset or force requires confirmation: {' '.join(cmd_tokens)}"
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
                    target_dir = dir_operands[0] if dir_operands else None
                    target_ref = dir_operands[1] if len(dir_operands) >= 2 else 'HEAD'
                    if git_has_active_hooks(cwd, ('post-checkout', 'post-index-change', 'reference-transaction'), written_files=written_files, target_ref=target_ref):
                        return 'force_ask', f"git worktree add with active repository hook requires confirmation: {' '.join(cmd_tokens)}"
                    if git_has_fsmonitor_configured(cwd):
                        return 'force_ask', f"git worktree add with configured core.fsmonitor hook requires confirmation: {' '.join(cmd_tokens)}"
                    if git_has_filter_configured(cwd):
                        return 'force_ask', f"git worktree add with configured filter driver requires confirmation: {' '.join(cmd_tokens)}"
                    if target_dir:
                        target_dir_abs = os.path.normpath(expand_path(target_dir, cwd))
                        if is_sensitive_credential_path(target_dir, cwd) or matches_sensitive_pattern(target_dir):
                            return 'deny', f"git worktree add targeting sensitive path is forbidden: {target_dir}"
                        if is_git_admin_path(target_dir, cwd):
                            return 'force_ask', f"git worktree add targeting git administrative path requires confirmation: {target_dir}"
                        if not is_path_in_workspaces(target_dir, workspace_paths, cwd) or is_system_write_path(target_dir, cwd):
                            return 'force_ask', f"git worktree add outside workspace requires approval: {target_dir}"

                        res_hp = git_run_probe(['config', '--get', 'core.hooksPath'], cwd=cwd)
                        raw_hp = res_hp.stdout.strip() if res_hp and res_hp.returncode == 0 and res_hp.stdout.strip() else None
                        res_git_hooks = git_run_probe(['rev-parse', '--git-path', 'hooks'], cwd=cwd)
                        norm_hooks = None
                        if res_git_hooks and res_git_hooks.returncode == 0 and res_git_hooks.stdout.strip():
                            h_cand = res_git_hooks.stdout.strip()
                            norm_hooks = os.path.normpath(h_cand if os.path.isabs(h_cand) else os.path.join(cwd or os.getcwd(), h_cand))
                        hooks_to_probe = []
                        if raw_hp and not os.path.isabs(raw_hp):
                            hooks_to_probe.append(os.path.normpath(raw_hp))
                        if norm_hooks and (norm_hooks == target_dir_abs or norm_hooks.startswith(target_dir_abs + os.sep)):
                            hooks_to_probe.append(os.path.normpath(os.path.relpath(norm_hooks, target_dir_abs)))
                        for h_dir in hooks_to_probe:
                            for h in ('post-checkout', 'post-index-change', 'reference-transaction'):
                                rel_hook = os.path.normpath(os.path.join(h_dir, h))
                                res_tree = git_run_probe(['ls-tree', target_ref, '--', rel_hook], cwd=cwd)
                                if res_tree and res_tree.returncode == 0 and res_tree.stdout.strip():
                                    return 'force_ask', f"git worktree add checks out repository hook into configured hooks path ({rel_hook}): {' '.join(cmd_tokens)}"

                    res_repo = git_run_probe(['rev-parse', '--is-inside-work-tree'], cwd=cwd)
                    if res_repo and res_repo.returncode == 0:
                        res_ref = git_run_probe(['rev-parse', '--verify', f'{target_ref}^{{commit}}'], cwd=cwd)
                        if res_ref and res_ref.returncode == 0:
                            res_tree_all = git_run_probe(['ls-tree', '-r', '--name-only', target_ref], cwd=cwd)
                            if res_tree_all and res_tree_all.returncode == 0 and res_tree_all.stdout:
                                for f in res_tree_all.stdout.splitlines():
                                    f = f.strip()
                                    if not f:
                                        continue
                                    if is_sensitive_credential_path(f, cwd) or matches_sensitive_pattern(f):
                                        return 'deny', f"git worktree add checks out sensitive credential file: {f}"
                                    if is_security_guard_path(f, cwd):
                                        return 'force_ask', f"git worktree add checks out protected security guard: {f}"
                    return 'allow', 'Safe git worktree add within workspace'
                return 'force_ask', f"Git worktree modification requires confirmation: {' '.join(cmd_tokens)}"
            return 'allow', 'Safe git worktree query'

        # Git show, log, blame, shortlog, etc. run configured textconv drivers or signature verification by default
        if git_sub in {'show', 'log', 'blame', 'whatchanged', 'format-patch', 'shortlog'}:
            def git_has_sig_opt(args_list):
                for i, a in enumerate(args_list):
                    if a == '--show-signature' or a.startswith(('--show-sig', '--show-signature=')):
                        return True
                    if a.startswith(('--format=', '--pretty=')):
                        val = a.split('=', 1)[1]
                        if any(g in val for g in ('%G', '%g')):
                            return True
                    elif a in ('--format', '--pretty') and i + 1 < len(args_list):
                        val = args_list[i + 1]
                        if any(g in val for g in ('%G', '%g')):
                            return True
                    elif a.startswith('--'):
                        opt = a.split('=', 1)[0]
                        if ('--format'.startswith(opt) and len(opt) >= 4) or ('--pretty'.startswith(opt) and len(opt) >= 4):
                            if '=' in a:
                                val = a.split('=', 1)[1]
                                if any(g in val for g in ('%G', '%g')):
                                    return True
                            elif i + 1 < len(args_list):
                                val = args_list[i + 1]
                                if any(g in val for g in ('%G', '%g')):
                                    return True
                return False

            def git_has_fmt_opt(args_list):
                for i, a in enumerate(args_list):
                    if a.startswith(('--format=', '--pretty=')):
                        return True
                    elif a in ('--format', '--pretty'):
                        return True
                    elif a.startswith('--'):
                        opt = a.split('=', 1)[0]
                        if ('--format'.startswith(opt) and len(opt) >= 4) or ('--pretty'.startswith(opt) and len(opt) >= 4):
                            return True
                return False

            args_options = args[:args.index('--')] if '--' in args else args
            has_stdin = any(a == '--stdin' or (a.startswith('--') and len(a.split('=', 1)[0]) >= 5 and '--stdin'.startswith(a.split('=', 1)[0])) for a in args_options)
            if has_stdin:
                return 'force_ask', f"git {git_sub} reading revisions from stdin requires confirmation: {' '.join(cmd_tokens)}"
            has_no_sig = any(a == '--no-show-signature' for a in args_options)
            has_sig = git_has_sig_opt(args_options)
            if has_sig or (not has_no_sig and git_sub in {'show', 'log', 'whatchanged'} and git_has_show_signature_configured(cwd)):
                return 'force_ask', f"git {git_sub} with signature display invokes external gpg program: {' '.join(cmd_tokens)}"
            if git_has_gpg_program_configured(cwd) and git_has_fmt_opt(args_options):
                return 'force_ask', f"git {git_sub} with formatted output and custom gpg.program requires confirmation: {' '.join(cmd_tokens)}"
            has_no_ext = any(is_git_no_ext_diff_opt(a) for a in args_options)
            has_no_textconv = any(a == '--no-textconv' for a in args_options)
            ext_diff_env = os.environ.get('GIT_EXTERNAL_DIFF')
            if not has_no_ext and ext_diff_env and ext_diff_env.strip():
                if is_sensitive_credential_path(ext_diff_env, cwd) or matches_sensitive_pattern(ext_diff_env):
                    return 'deny', f"git {git_sub} with GIT_EXTERNAL_DIFF referencing sensitive path is forbidden: {ext_diff_env}"
                return 'force_ask', f"git {git_sub} with inherited GIT_EXTERNAL_DIFF executable requires confirmation: {ext_diff_env}"
            if not has_no_textconv and git_sub != 'shortlog' and git_has_external_diff_configured(cwd):
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

            if git_sub == 'show':
                show_objects = []
                if '--' in args:
                    idx = args.index('--')
                    show_pre_dash = args[1:idx]
                else:
                    show_pre_dash = args[1:]
                for a in show_pre_dash:
                    if not a.startswith('-'):
                        show_objects.append(a)
                for obj in show_objects:
                    if ':' not in obj:
                        res_t = git_run_probe(['cat-file', '-t', obj], cwd=cwd)
                        if res_t and res_t.returncode == 0 and res_t.stdout.strip() == 'blob':
                            return 'force_ask', f"git show reading raw git blob by hash can disclose sensitive repository history: {obj}"

            if git_sub == 'show':
                for a in args[1:]:
                    if ':' in a and not a.startswith(('-', 'http:', 'https:', 'ssh:', 'git:')):
                        obj_path = a.rsplit(':', 1)[1]
                        if obj_path.startswith(('0:', '1:', '2:', '3:')):
                            obj_path = obj_path[2:]
                        if matches_sensitive_pattern(obj_path) or is_sensitive_credential_path(obj_path, cwd):
                            return 'deny', f"git show targeting sensitive object is forbidden: {a}"
                        if obj_path.startswith(('/', '~')) or '..' in obj_path.split('/'):
                            if not is_path_in_workspaces(obj_path, workspace_paths, cwd):
                                return 'force_ask', f"git show object path outside workspace requires approval: {a}"

            is_pure_blob_show = False
            if git_sub == 'show':
                pos_objects = [a for a in show_pre_dash if not a.startswith('-')]
                if pos_objects and all(':' in obj and not obj.startswith(('http:', 'https:', 'ssh:', 'git:')) for obj in pos_objects):
                    is_pure_blob_show = True

            if git_sub in ('log', 'whatchanged'):
                for i_arg, a in enumerate(args[1:], start=1):
                    l_val = None
                    if a == '-L' and i_arg + 1 < len(args):
                        l_val = args[i_arg + 1]
                    elif a.startswith('-L') and not a.startswith('--'):
                        l_val = a[2:]
                    elif a.startswith('--line-range=') or a == '--line-range':
                        if '=' in a:
                            l_val = a.split('=', 1)[1]
                        elif i_arg + 1 < len(args):
                            l_val = args[i_arg + 1]
                    if l_val is not None and ':' in l_val:
                        target_f = l_val.rsplit(':', 1)[1].strip().strip('"\'')
                        if target_f:
                            if matches_sensitive_pattern(target_f) or is_sensitive_credential_path(target_f, cwd):
                                return 'deny', f"git {git_sub} -L targeting sensitive file is forbidden: {target_f}"
                            if target_f.startswith(('/', '~')) or target_f.startswith('..' + os.sep) or target_f == '..':
                                if not is_path_in_workspaces(target_f, workspace_paths, cwd):
                                    return 'force_ask', f"git {git_sub} -L target outside workspace requires approval: {target_f}"

            if git_sub != 'blame' and not is_pure_blob_show:
                if written_files:
                    for wf in written_files:
                        if matches_sensitive_pattern(wf) or is_sensitive_credential_path(wf, cwd):
                            return 'deny', f"git {git_sub} following modification of sensitive file is forbidden: {wf}"
                    return 'force_ask', f"git {git_sub} following earlier file or working-tree modifications requires confirmation: {' '.join(cmd_tokens)}"
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
                        obj_path = a.rsplit(':', 1)[1]
                        if obj_path.startswith(('0:', '1:', '2:', '3:')):
                            obj_path = obj_path[2:]
                        if matches_sensitive_pattern(obj_path) or is_sensitive_credential_path(obj_path, cwd):
                            return 'deny', f"git cat-file targeting sensitive object is forbidden: {a}"
                        if obj_path.startswith(('/', '~')) or '..' in obj_path.split('/'):
                            if not is_path_in_workspaces(obj_path, workspace_paths, cwd):
                                return 'force_ask', f"git cat-file object path outside workspace requires approval: {a}"
                    else:
                        clean_obj = re.sub(r'[\^~].*$', '', a)
                        is_hash = bool(re.match(r'^[0-9a-fA-F]{7,64}$', clean_obj))
                        res_t = git_run_probe(['cat-file', '-t', a], cwd=cwd)
                        is_blob = bool(res_t and res_t.returncode == 0 and res_t.stdout.strip() == 'blob')
                        if is_hash or is_blob:
                            return 'force_ask', f"Reading raw git object can disclose sensitive repository history: {a}"
                        if matches_sensitive_pattern(a) or is_sensitive_credential_path(a, cwd):
                            return 'deny', f"git cat-file targeting sensitive object is forbidden: {a}"
            return 'allow', 'Safe git cat-file query'

        if git_sub == 'rev-list':
            if any(a == '--objects' or a.startswith('--objects') for a in args):
                return 'force_ask', f"git rev-list --objects can list all repository history objects: {' '.join(cmd_tokens)}"
            if any(a == '--stdin' or (a.startswith('--') and len(a.split('=', 1)[0]) >= 5 and '--stdin'.startswith(a.split('=', 1)[0])) for a in args):
                return 'force_ask', f"git rev-list reading revisions from stdin requires confirmation: {' '.join(cmd_tokens)}"

        if git_sub in SAFE_GIT_READ_SUBCOMMANDS:
            return 'allow', f"Safe git read query: git {git_sub}"

        if git_sub == 'config':
            if any(a in ('--list', '-l', '--get-regexp') or a.startswith(('--list', '--get-regexp=')) for a in args):
                return 'force_ask', f"Listing all git configuration may disclose credentials or tokens: {' '.join(cmd_tokens)}"
            if any(a == '--blob' or a.startswith('--blob=') for a in args):
                return 'force_ask', f"git config reading from blob requires confirmation: {' '.join(cmd_tokens)}"

            config_files = []
            skip_cfg = False
            for i, a in enumerate(args[1:], start=1):
                if skip_cfg:
                    skip_cfg = False
                    continue
                if a in ('-f', '--file') and i + 1 < len(args):
                    config_files.append(args[i + 1])
                    skip_cfg = True
                    continue
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    if '--file'.startswith(opt) and len(opt) >= 3:
                        if '=' in a:
                            config_files.append(a.split('=', 1)[1])
                        elif i + 1 < len(args):
                            config_files.append(args[i + 1])
                            skip_cfg = True
                        continue
                elif a.startswith('-f') and len(a) > 2 and not a.startswith('--'):
                    val = a[2:]
                    if val.startswith('='):
                        val = val[1:]
                    config_files.append(val)
                    continue

            scope_args = []
            has_includes = False
            has_no_includes = False
            for a in args[1:]:
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    if '--includes'.startswith(opt) and len(opt) >= 3:
                        has_includes = True
                        has_no_includes = False
                    elif '--no-includes'.startswith(opt) and len(opt) >= 6:
                        has_no_includes = True
                        has_includes = False
                    elif '--global'.startswith(opt) and len(opt) >= 3:
                        scope_args.append('--global')
                    elif '--system'.startswith(opt) and len(opt) >= 3:
                        scope_args.append('--system')
                    elif '--local'.startswith(opt) and len(opt) >= 3:
                        scope_args.append('--local')
                    elif '--worktree'.startswith(opt) and len(opt) >= 3:
                        scope_args.append('--worktree')

            for cf in config_files:
                if is_sensitive_credential_path(cf, cwd) or matches_sensitive_pattern(cf):
                    return 'deny', f"git config targeting sensitive file is forbidden: {cf}"
                if not is_path_in_workspaces(cf, workspace_paths, cwd):
                    return 'ask', f"git config reading file outside workspace requires approval: {cf}"
                if written_files:
                    norm_cf = os.path.normpath(expand_path(cf, cwd))
                    for wf in written_files:
                        norm_wf = os.path.normpath(wf)
                        if norm_cf == norm_wf or norm_cf.startswith(norm_wf + os.sep):
                            return 'force_ask', f"git config file was modified or updated earlier in the command line: {cf}"

            if has_includes and config_files:
                for cf in config_files:
                    f_path = expand_path(cf, cwd)
                    res_origin = git_run_probe(['config', '--includes', '--file', f_path, '--list', '--show-origin'], cwd=cwd)
                    if res_origin and res_origin.returncode == 0 and res_origin.stdout:
                        for line in res_origin.stdout.splitlines():
                            parts = line.split('\t', 1)
                            origin_part = parts[0].strip()
                            if origin_part.startswith('file:'):
                                inc_file = origin_part[5:]
                                if is_sensitive_credential_path(inc_file, cwd) or matches_sensitive_pattern(inc_file):
                                    return 'deny', f"git config included sensitive file is forbidden: {inc_file}"
                                if not is_path_in_workspaces(inc_file, workspace_paths, cwd):
                                    return 'ask', f"git config included file outside workspace requires approval: {inc_file}"
                                if is_security_guard_path(inc_file, cwd):
                                    return 'force_ask', f"git config included security guard file requires confirmation: {inc_file}"
                                if written_files:
                                    norm_inc = os.path.normpath(expand_path(inc_file, cwd))
                                    for wf in written_files:
                                        norm_wf = os.path.normpath(wf)
                                        if norm_inc == norm_wf or norm_inc.startswith(norm_wf + os.sep):
                                            return 'force_ask', f"git config included file was modified earlier: {inc_file}"
                            if len(parts) == 2:
                                kv = parts[1].strip()
                                if '=' in kv:
                                    k_inc, v_inc = kv.split('=', 1)
                                    k_inc_clean = k_inc.strip().lower()
                                    if k_inc_clean.startswith(('include.', 'includeif.')):
                                        inc_target = v_inc.strip()
                                        if is_sensitive_credential_path(inc_target, cwd) or matches_sensitive_pattern(inc_target):
                                            return 'deny', f"git config include target is sensitive: {inc_target}"
                                        if not is_path_in_workspaces(inc_target, workspace_paths, cwd):
                                            return 'ask', f"git config include target outside workspace requires approval: {inc_target}"

            # Collect keys queried or set
            config_keys = []
            skip_arg = False
            for i, a in enumerate(args[1:], start=1):
                if skip_arg:
                    skip_arg = False
                    continue
                if a in ('-f', '--file', '--blob', '--default', '-t', '--type', '--get-color', '--get-colorbool') and i + 1 < len(args):
                    skip_arg = True
                    continue
                if a.startswith(('-f', '--file=', '--blob=', '--default=', '--type=', '-t=')):
                    continue
                if a.startswith('-'):
                    continue
                config_keys.append(a)

            # Check for sensitive config keys
            for k in config_keys:
                clean_key = k.lower()
                if any(sec in clean_key for sec in ('header', 'token', 'secret', 'key', 'pass', 'auth', 'cred', 'cookie', 'proxy', 'extraheader')):
                    return 'deny', f"git config targeting sensitive credential key is forbidden: {k}"
                if any(sec in clean_key for sec in ('url', 'remote', 'insteadof')):
                    sources_to_check = []
                    if config_files:
                        for cf in config_files:
                            src = ['--file', expand_path(cf, cwd)]
                            if has_includes:
                                src.insert(0, '--includes')
                            sources_to_check.append(src)
                    if scope_args:
                        src = list(scope_args)
                        if has_includes:
                            src.insert(0, '--includes')
                        sources_to_check.append(src)
                    if not sources_to_check:
                        if has_includes:
                            sources_to_check.append(['--includes'])
                        elif has_no_includes:
                            sources_to_check.append(['--no-includes'])
                        else:
                            sources_to_check.append(None)

                    for src in sources_to_check:
                        if git_remotes_have_credentials(cwd, config_source_args=src):
                            return 'deny', f"git config query exposing embedded credentials in remote URL is forbidden: {k}"
            if any(a in ('--get', '--get-all') for a in args) or (len(args) == 2 and not args[1].startswith('-')):
                return 'allow', 'Safe git config query'
            return 'force_ask', 'Git config modification requires confirmation'

        if git_sub == 'add':
            if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                return 'force_ask', f"git add in directory outside workspace requires confirmation: {cwd}"
            def is_git_add_interactive_opt(opt):
                if not opt:
                    return False
                if opt.startswith('-') and not opt.startswith('--') and opt != '-':
                    if any(c in opt for c in ('e', 'p', 'i')):
                        return True
                if opt.startswith('--'):
                    clean_opt = opt.split('=', 1)[0]
                    for dangerous_long in ('--edit', '--interactive', '--patch'):
                        if dangerous_long.startswith(clean_opt) and len(clean_opt) >= 3:
                            return True
                return False

            if any(is_git_add_interactive_opt(a) for a in args):
                return 'force_ask', f"git add with editor or interactive option requires confirmation: {' '.join(cmd_tokens)}"
            if any(a == '--force' or a.startswith('--force') or (a.startswith('-') and not a.startswith('--') and a != '-' and 'f' in a) for a in args):
                return 'force_ask', f"git add with --force can stage ignored sensitive files: {' '.join(cmd_tokens)}"
            if git_has_active_hooks(cwd, ('post-index-change',), written_files=written_files):
                return 'force_ask', f"git add with active repository hook (post-index-change) requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_filter_configured(cwd):
                return 'force_ask', f"git add with configured filter driver requires confirmation: {' '.join(cmd_tokens)}"

            # Check --pathspec-from-file
            pathspec_files = []
            for i, a in enumerate(args[1:], start=1):
                if a == '--pathspec-from-file' and i + 1 < len(args):
                    pathspec_files.append(args[i + 1])
                elif a.startswith('--pathspec-from-file='):
                    pathspec_files.append(a.split('=', 1)[1])

            has_add_pathspec_file = bool(pathspec_files)
            for pf in pathspec_files:
                if pf == '-':
                    return 'force_ask', f"git add reading pathspecs from stdin requires confirmation: {' '.join(cmd_tokens)}"
                if matches_sensitive_pattern(pf) or is_sensitive_credential_path(pf, cwd):
                    return 'deny', f"git add pathspec file targeting sensitive or credential file is forbidden: {pf}"
                if not is_path_in_workspaces(pf, workspace_paths, cwd):
                    return 'force_ask', f"git add pathspec file outside workspace requires approval: {pf}"
                pf_resolved = expand_path(pf, cwd)
                norm_pf = os.path.normpath(pf_resolved)
                if written_files:
                    for wf in written_files:
                        norm_wf = os.path.normpath(wf)
                        if norm_pf == norm_wf or norm_pf.startswith(norm_wf + os.sep):
                            return 'force_ask', f"git add pathspec file was modified or redirected to in the command line: {pf}"
                for i_tok, tok in enumerate(cmd_tokens):
                    if is_output_redirection(tok, cmd_tokens[i_tok + 1] if i_tok + 1 < len(cmd_tokens) else None) and i_tok + 1 < len(cmd_tokens):
                        redir_target = expand_path(unquote_token(cmd_tokens[i_tok + 1]), cwd)
                        if os.path.normpath(redir_target) == norm_pf:
                            return 'force_ask', f"git add pathspec file is redirected to within the same command: {pf}"
                if os.path.isfile(pf_resolved):
                    try:
                        content = Path(pf_resolved).read_text(errors='replace')
                        delim = '\0' if any(a == '--pathspec-file-nul' for a in args) else '\n'
                        for line in content.split(delim):
                            p = line.strip()
                            if p:
                                if matches_sensitive_pattern(p) or is_sensitive_credential_path(p, cwd):
                                    return 'deny', f"git add pathspec file references sensitive file: {p}"
                                if not is_path_in_workspaces(p, workspace_paths, cwd):
                                    return 'force_ask', f"git add pathspec file references path outside workspace: {p}"
                    except Exception:
                        return 'force_ask', f"git add unable to verify pathspec file: {pf}"

            def strip_magic_pathspec(p):
                if not p or not isinstance(p, str):
                    return ''
                if p.startswith(':(') and ')' in p:
                    return p.split(')', 1)[1]
                if p.startswith(':/'):
                    return p[2:]
                if p.startswith(':'):
                    return p.lstrip(':')
                return p

            def is_broad_git_pathspec(p, cwd):
                if not p or not isinstance(p, str):
                    return False
                if p in ('.', '*', ':/', '-A', '--all', '-u', '--update'):
                    return True
                if p.startswith(':/') or p.startswith(':('):
                    return True
                if '*' in p or '?' in p or ('[' in p and ']' in p):
                    return True
                try:
                    resolved = expand_path(p, cwd)
                    if os.path.isdir(resolved):
                        return True
                except Exception:
                    pass
                return False

            # Check individual positional arguments
            for a in args[1:]:
                if not a.startswith('-'):
                    clean_p = strip_magic_pathspec(a)
                    if clean_p and (is_sensitive_credential_path(clean_p, cwd) or matches_sensitive_pattern(clean_p)):
                        return 'deny', f"git add targeting sensitive file is forbidden: {a}"
                    if matches_sensitive_pattern(a) or is_sensitive_credential_path(a, cwd):
                        return 'deny', f"git add targeting sensitive file is forbidden: {a}"

            if written_files:
                for wf in written_files:
                    if matches_sensitive_pattern(wf) or is_sensitive_credential_path(wf, cwd):
                        return 'deny', f"git add following write of sensitive file is forbidden: {wf}"

            # Check broad staging (e.g. git add ., git add -A, git add --all, git add -u, git add *, or pathspec file, or magic pathspec)
            is_broad = has_add_pathspec_file or any(is_broad_git_pathspec(a, cwd) for a in args[1:] if not a.startswith('-') or a in ('-A', '--all', '-u', '--update'))
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
            def is_git_commit_edit_opt(opt):
                if not opt:
                    return False
                if opt in ('-e', '-t', '-c', '-p', '-i'):
                    return True
                if opt.startswith(('-e=', '-t=', '-c=')):
                    return True
                if opt.startswith('-') and not opt.startswith('--') and opt != '-':
                    if any(c in opt for c in ('e', 't', 'c', 'p', 'i')):
                        return True
                if opt.startswith('--'):
                    clean_opt = opt.split('=', 1)[0]
                    for dangerous_long in ('--edit', '--template', '--reedit-message', '--patch', '--interactive'):
                        if dangerous_long.startswith(clean_opt) and len(clean_opt) >= 3:
                            return True
                return False

            def is_git_commit_no_edit_opt(opt):
                if not opt:
                    return False
                if opt == '--no-edit' or (opt.startswith('--') and '--no-edit'.startswith(opt.split('=', 1)[0]) and len(opt.split('=', 1)[0]) >= 5):
                    return True
                return False

            last_edit_idx = -1
            last_no_edit_idx = -1
            for i, a in enumerate(args):
                if is_git_commit_edit_opt(a):
                    last_edit_idx = i
                if is_git_commit_no_edit_opt(a):
                    last_no_edit_idx = i

            if last_edit_idx != -1 and last_edit_idx > last_no_edit_idx:
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

            last_sign_idx = -1
            last_no_sign_idx = -1
            for i, a in enumerate(args):
                if a in ('-S', '--gpg-sign') or a.startswith(('-S', '--gpg-sign=')):
                    last_sign_idx = i
                elif a == '--no-gpg-sign' or (a.startswith('--') and '--no-gpg-sign'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 5):
                    last_no_sign_idx = i

            is_signing = False
            if last_sign_idx != -1 and last_sign_idx > last_no_sign_idx:
                is_signing = True
            elif git_has_gpgsign_configured(cwd) and last_no_sign_idx == -1:
                is_signing = True

            if is_signing:
                return 'force_ask', f"git commit with GPG signing invokes external gpg program: {' '.join(cmd_tokens)}"
            if any(a in ('--amend', '--fixup', '--squash', '--reset-author') or a.startswith(('--amend', '--fixup=', '--squash=')) for a in args):
                return 'force_ask', f"git commit with history rewriting requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_active_hooks(cwd, ('pre-commit', 'prepare-commit-msg', 'commit-msg', 'post-commit', 'post-index-change', 'reference-transaction'), written_files=written_files):
                return 'force_ask', f"git commit with active repository hook requires confirmation: {' '.join(cmd_tokens)}"
            if git_has_filter_configured(cwd):
                return 'force_ask', f"git commit with configured filter driver requires confirmation: {' '.join(cmd_tokens)}"
            has_trailer = any(a == '--trailer' or a.startswith('--trailer=') or
                              (a.startswith('--') and '--trailer'.startswith(a.split('=', 1)[0]) and len(a.split('=', 1)[0]) >= 4)
                              for a in args)
            if has_trailer and git_has_trailer_command_configured(cwd):
                return 'force_ask', f"git commit with --trailer and configured trailer command requires confirmation: {' '.join(cmd_tokens)}"

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
                norm_pf = os.path.normpath(pf_resolved)
                if written_files:
                    for wf in written_files:
                        norm_wf = os.path.normpath(wf)
                        if norm_pf == norm_wf or norm_pf.startswith(norm_wf + os.sep):
                            return 'force_ask', f"git commit pathspec file was modified or redirected to in the command line: {pf}"
                for i_tok, tok in enumerate(cmd_tokens):
                    if is_output_redirection(tok, cmd_tokens[i_tok + 1] if i_tok + 1 < len(cmd_tokens) else None) and i_tok + 1 < len(cmd_tokens):
                        redir_target = expand_path(unquote_token(cmd_tokens[i_tok + 1]), cwd)
                        if os.path.normpath(redir_target) == norm_pf:
                            return 'force_ask', f"git commit pathspec file is redirected to within the same command: {pf}"
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
            GIT_COMMIT_OPTS_WITH_ARG = {
                '-m', '--message',
                '-F', '--file',
                '-c', '-C', '--reedit-message', '--reuse-message',
                '-t', '--template',
                '--author', '--date',
                '-u', '--untracked-files',
                '-S', '--gpg-sign',
                '--cleanup',
                '--pathspec-from-file',
                '--trailer',
            }
            commit_pathspecs = []
            skip_arg = False
            in_dash_dash = False
            for i, a in enumerate(args[1:], start=1):
                if skip_arg:
                    skip_arg = False
                    continue
                if in_dash_dash:
                    commit_pathspecs.append(a)
                    continue
                if a == '--':
                    in_dash_dash = True
                    continue
                if a.startswith('--'):
                    opt_name = a.split('=', 1)[0]
                    if '=' in a:
                        continue
                    if opt_name in GIT_COMMIT_OPTS_WITH_ARG or any(long_opt.startswith(opt_name) and len(opt_name) >= 4 for long_opt in GIT_COMMIT_OPTS_WITH_ARG if long_opt.startswith('--')):
                        skip_arg = True
                        continue
                    continue
                if a.startswith('-') and len(a) > 1:
                    if a in ('-m', '-F', '-c', '-C', '-t', '-S', '-u'):
                        skip_arg = True
                        continue
                    continue
                commit_pathspecs.append(a)

            def strip_magic_pathspec_commit(p):
                if not p or not isinstance(p, str):
                    return ''
                if p.startswith(':(') and ')' in p:
                    return p.split(')', 1)[1]
                if p.startswith(':/'):
                    return p[2:]
                if p.startswith(':'):
                    return p.lstrip(':')
                return p

            for a in commit_pathspecs:
                clean_p = strip_magic_pathspec_commit(a)
                if (clean_p and (matches_sensitive_pattern(clean_p) or is_sensitive_credential_path(clean_p, cwd))) or matches_sensitive_pattern(a) or is_sensitive_credential_path(a, cwd):
                    return 'deny', f"git commit targeting sensitive pathspec is forbidden: {a}"
                target_check = clean_p if clean_p else a
                if not is_path_in_workspaces(target_check, workspace_paths, cwd):
                    return 'force_ask', f"git commit pathspec outside workspace requires approval: {a}"
            if commit_pathspecs:
                has_pathspec = True

            def is_commit_all_flag(arg):
                if arg in ('-a', '--all') or arg.startswith('--all='):
                    return True
                if arg.startswith('--'):
                    opt = arg.split('=', 1)[0]
                    return '--all'.startswith(opt) and len(opt) >= 4
                if arg.startswith('-') and not arg.startswith('--') and arg != '-':
                    flag_chars = []
                    for c in arg[1:]:
                        flag_chars.append(c)
                        if c in ('m', 'F', 'c', 'C', 't', 'S', 'u'):
                            break
                    return 'a' in flag_chars
                return False

            if written_files:
                for wf in written_files:
                    if matches_sensitive_pattern(wf) or is_sensitive_credential_path(wf, cwd):
                        return 'deny', f"git commit following modification of sensitive file is forbidden: {wf}"

            # Inspect staged files to prevent committing credentials
            has_all_flag = has_pathspec or any(is_commit_all_flag(a) for a in args[1:])
            probe_res = git_probe_staged_sensitive_files(cwd, include_unstaged_tracked=has_all_flag)
            if probe_res == 'sensitive':
                return 'deny', f"git commit committing sensitive credential files is forbidden: {' '.join(cmd_tokens)}"
            if probe_res == 'unknown':
                return 'force_ask', f"git commit cannot safely verify staged files: {' '.join(cmd_tokens)}"

            return 'allow', 'Safe git commit'

    # Interactive pagers support shell escapes and unclassified command execution
    if base_cmd in {'less', 'more', 'most'}:
        return 'force_ask', f"Interactive pager {base_cmd} can execute arbitrary shell commands and requires confirmation: {' '.join(cmd_tokens)}"

    # 6. Inspection Commands
    if base_cmd in SAFE_INSPECTION_COMMANDS:
        if base_cmd == 'jq':
            if any(re.search(r'((?<![A-Za-z0-9_.$])env\b|(?<![A-Za-z0-9_])\$ENV\b)', a) for a in args):
                return 'deny', f"jq accessing process environment is forbidden: {' '.join(cmd_tokens)}"
            if any(a in ('-f', '--from-file') or a.startswith(('-f', '--from-file=')) for a in args):
                return 'force_ask', f"jq reading filter from file requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'file':
            if any(a in ('-C', '--compile') or (a.startswith('-') and not a.startswith('--') and 'C' in a) for a in args):
                return 'force_ask', f"file with compile option (-C/--compile) writes output and requires confirmation: {' '.join(cmd_tokens)}"
            def is_file_uncompress_or_sandbox_opt(a):
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    if any(long_opt.startswith(opt) and len(opt) >= 3 for long_opt in ('--uncompress', '--uncompress-noreport', '--no-sandbox')):
                        return True
                    return False
                if a.startswith('-') and len(a) > 1:
                    return any(c in a[1:] for c in ('z', 'Z', 'S'))
                return False
            if any(is_file_uncompress_or_sandbox_opt(a) for a in args):
                return 'force_ask', f"file with uncompress or sandbox-disabling option (-z/-Z/-S) executes external decompressors and requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd in {'test', '['}:
            for a in args:
                if any(c in a for c in ('$', '`')):
                    return 'force_ask', f"test/[ with variable or command substitution in argument requires confirmation: {' '.join(cmd_tokens)}"
            test_args = list(args)
            if base_cmd == '[' and test_args and test_args[-1] == ']':
                test_args = test_args[:-1]

            UNARY_FILE_TESTS = {'-b', '-c', '-d', '-e', '-f', '-g', '-h', '-k', '-p', '-r', '-s', '-u', '-w', '-x', '-O', '-G', '-L', '-S', '-N'}
            BINARY_FILE_TESTS = {'-nt', '-ot', '-ef'}
            file_operands = []
            i = 0
            while i < len(test_args):
                a = test_args[i]
                if a in ('-v', '-R'):
                    if i + 1 < len(test_args):
                        var_name = test_args[i + 1]
                        if not re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*$', var_name):
                            return 'force_ask', f"test/[ variable test with array subscript or expression evaluation requires confirmation: {var_name}"
                        i += 2
                        continue
                    else:
                        return 'force_ask', f"test/[ missing variable name for {a}"
                elif a in UNARY_FILE_TESTS:
                    if i + 1 < len(test_args):
                        file_operands.append(test_args[i + 1])
                        i += 2
                        continue
                elif a in BINARY_FILE_TESTS:
                    if i > 0:
                        file_operands.append(test_args[i - 1])
                    if i + 1 < len(test_args):
                        file_operands.append(test_args[i + 1])
                        i += 2
                        continue
                i += 1

            for f_op in file_operands:
                if f_op in ('/dev/null', '/dev/zero', '/dev/stdin', '-'):
                    continue
                if written_files:
                    norm_fop = os.path.normpath(expand_path(f_op, cwd))
                    for wf in written_files:
                        norm_wf = os.path.normpath(wf)
                        if norm_fop == norm_wf or norm_fop.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_fop + os.sep):
                            return 'force_ask', f"test/[ reading file modified or updated earlier in the command line requires confirmation: {f_op}"
                if is_sensitive_credential_path(f_op, cwd):
                    return 'deny', f"test/[ targeting sensitive credential or key is forbidden: {f_op}"
                if not is_path_in_workspaces(f_op, workspace_paths, cwd):
                    return 'ask', f"test/[ testing file outside workspace requires approval: {f_op}"

            return 'allow', 'Safe test/[ evaluation'
        # File inspection commands must prompt if args contain variable, command substitutions, or wildcards
        if base_cmd in {'cat', 'head', 'tail', 'wc', 'file', 'stat', 'cmp', 'uniq', 'cut', 'column', 'jq', 'date', 'ls', 'dir', 'vdir'}:
            for a in args:
                if any(c in a for c in ('$', '`')):
                    return 'ask', f"Inspection command with variable or substitution requires confirmation: {' '.join(cmd_tokens)}"
                if not a.startswith('-') and any(c in a for c in ('*', '?', '[', ']', ';', '&', '|', '<', '>', '(', ')')):
                    return 'ask', f"Inspection command with wildcard or metacharacter requires confirmation: {' '.join(cmd_tokens)}"
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
            elif base_cmd == 'file':
                in_positional_only = False
                files_from_list = []
                i = 0
                while i < len(args):
                    a = args[i]
                    if in_positional_only:
                        file_operands.append(a)
                        i += 1
                        continue
                    if a == '--':
                        in_positional_only = True
                        i += 1
                        continue
                    if a.startswith('--'):
                        opt = a.split('=', 1)[0]
                        val = a.split('=', 1)[1] if '=' in a else None
                        if '--files-from'.startswith(opt) and len(opt) >= 3:
                            ff_val = val if val is not None else (args[i + 1] if i + 1 < len(args) else None)
                            if val is None and i + 1 < len(args):
                                i += 1
                            if ff_val:
                                file_operands.append(ff_val)
                                files_from_list.append(ff_val)
                            i += 1
                            continue
                        if '--magic-file'.startswith(opt) and len(opt) >= 3:
                            mf_val = val if val is not None else (args[i + 1] if i + 1 < len(args) else None)
                            if val is None and i + 1 < len(args):
                                i += 1
                            if mf_val:
                                for mf in mf_val.split(':'):
                                    if mf:
                                        file_operands.append(mf)
                            i += 1
                            continue
                        if any(opt_name.startswith(opt) and len(opt) >= 3 for opt_name in ('--separator', '--exclude', '--exclude-quiet', '--parameter')):
                            if val is None and i + 1 < len(args):
                                i += 1
                            i += 1
                            continue
                        i += 1
                        continue
                    if a.startswith('-') and len(a) > 1:
                        # Handle attached or clustered options
                        for idx_char, ch in enumerate(a[1:], start=1):
                            if ch == 'f':
                                rest = a[idx_char + 1:].lstrip('=')
                                ff_val = rest if rest else (args[i + 1] if i + 1 < len(args) else None)
                                if not rest and i + 1 < len(args):
                                    i += 1
                                if ff_val:
                                    file_operands.append(ff_val)
                                    files_from_list.append(ff_val)
                                break
                            elif ch == 'm':
                                rest = a[idx_char + 1:].lstrip('=')
                                mf_val = rest if rest else (args[i + 1] if i + 1 < len(args) else None)
                                if not rest and i + 1 < len(args):
                                    i += 1
                                if mf_val:
                                    for mf in mf_val.split(':'):
                                        if mf:
                                            file_operands.append(mf)
                                break
                            elif ch in ('F', 'e', 'P'):
                                rest = a[idx_char + 1:].lstrip('=')
                                if not rest and i + 1 < len(args):
                                    i += 1
                                break
                        i += 1
                        continue
                    file_operands.append(a)
                    i += 1
                for ff in files_from_list:
                    v_res = validate_file_list_entries(ff, 'file', cmd_tokens, workspace_paths, cwd, written_files=written_files, nul_delimited=False)
                    if v_res is not None:
                        return v_res
            elif base_cmd == 'date':
                i = 0
                while i < len(args):
                    a = args[i]
                    if a == '--':
                        for rem in args[i + 1:]:
                            if not rem.startswith('+'):
                                file_operands.append(rem)
                        break
                    if a.startswith('--'):
                        opt = a.split('=', 1)[0]
                        val = a.split('=', 1)[1] if '=' in a else None
                        if '--file'.startswith(opt) and len(opt) >= 3:
                            if val is not None:
                                file_operands.append(val)
                            elif i + 1 < len(args):
                                file_operands.append(args[i + 1])
                                i += 1
                            i += 1
                            continue
                        if '--reference'.startswith(opt) and len(opt) >= 3:
                            if val is not None:
                                file_operands.append(val)
                            elif i + 1 < len(args):
                                file_operands.append(args[i + 1])
                                i += 1
                            i += 1
                            continue
                        if '--date'.startswith(opt) and len(opt) >= 3:
                            if val is None and i + 1 < len(args):
                                i += 1
                            i += 1
                            continue
                        if '--set'.startswith(opt) and len(opt) >= 3:
                            if val is None and i + 1 < len(args):
                                i += 1
                            i += 1
                            continue
                        i += 1
                        continue
                    if a.startswith('-') and len(a) > 1 and not a.startswith('--'):
                        j = 1
                        while j < len(a):
                            ch = a[j]
                            if ch in ('f', 'r'):
                                val = a[j + 1:].lstrip('=')
                                if val:
                                    file_operands.append(val)
                                elif i + 1 < len(args):
                                    file_operands.append(args[i + 1])
                                    i += 1
                                break
                            elif ch in ('d', 's'):
                                val = a[j + 1:].lstrip('=')
                                if not val and i + 1 < len(args):
                                    i += 1
                                break
                            elif ch == 'I':
                                break
                            else:
                                j += 1
                        i += 1
                        continue
                    if not a.startswith('-') and not a.startswith('+'):
                        file_operands.append(a)
                    i += 1
            elif base_cmd == 'wc':
                files0_from = None
                in_positional_only = False
                i = 0
                while i < len(args):
                    a = args[i]
                    if in_positional_only:
                        file_operands.append(a)
                        i += 1
                        continue
                    if a == '--':
                        in_positional_only = True
                        i += 1
                        continue
                    if a.startswith('--'):
                        opt = a.split('=', 1)[0]
                        if '--files0-from'.startswith(opt) and len(opt) >= 3:
                            if '=' in a:
                                files0_from = a.split('=', 1)[1]
                                i += 1
                            elif i + 1 < len(args):
                                files0_from = args[i + 1]
                                i += 2
                            else:
                                i += 1
                            continue
                        i += 1
                        continue
                    elif not a.startswith('-'):
                        file_operands.append(a)
                    i += 1
                if files0_from:
                    f0_verdict = validate_files0_from(files0_from, 'wc', cmd_tokens, workspace_paths, cwd, written_files=written_files)
                    if f0_verdict:
                        return f0_verdict
            elif base_cmd in {'cat', 'head', 'tail', 'stat', 'cmp', 'ls', 'dir', 'vdir', 'uniq', 'cut', 'column'}:
                INSPECTION_OPTS_WITH_ARG = {
                    'head': {'-n', '--lines', '-c', '--bytes'},
                    'tail': {'-n', '--lines', '-c', '--bytes', '-s', '--sleep-interval', '--max-unchanged-stats', '--pid'},
                    'cut': {'-d', '--delimiter', '-f', '--fields', '-b', '--bytes', '-c', '--characters'},
                    'column': {'-s', '--separator', '-c', '--output-width', '-N', '--table-columns', '-o', '--output-separator', '-W', '--table-wrap'},
                    'uniq': {'-f', '--skip-fields', '-s', '--skip-chars', '-w', '--check-chars'},
                    'stat': {'-c', '--format', '--printf'},
                    'cmp': {'-i', '--ignore-initial', '-n', '--bytes'},
                    'ls': {'-w', '--width', '-T', '--tabsize', '-I', '--ignore', '--hide', '--block-size', '--format', '--quoting-style', '--time-style', '--sort', '--time'},
                    'dir': {'-w', '--width', '-T', '--tabsize', '-I', '--ignore', '--hide', '--block-size', '--format', '--quoting-style', '--time-style', '--sort', '--time'},
                    'vdir': {'-w', '--width', '-T', '--tabsize', '-I', '--ignore', '--hide', '--block-size', '--format', '--quoting-style', '--time-style', '--sort', '--time'},
                }
                opts_with_arg = INSPECTION_OPTS_WITH_ARG.get(base_cmd, set())
                skip_val = False
                in_positional_only = False
                for a in args:
                    if in_positional_only:
                        file_operands.append(a)
                        continue
                    if skip_val:
                        skip_val = False
                        continue
                    if a == '--':
                        in_positional_only = True
                        continue
                    if a.startswith('--'):
                        opt_name = a.split('=', 1)[0]
                        if '=' in a:
                            continue
                        if opt_name in opts_with_arg:
                            skip_val = True
                            continue
                        continue
                    if a.startswith('-') and len(a) > 1:
                        if a in opts_with_arg:
                            skip_val = True
                            continue
                        continue
                    file_operands.append(a)

            if base_cmd in {'ls', 'dir', 'vdir'} and not file_operands:
                if not is_path_in_workspaces(cwd, workspace_paths, cwd):
                    return 'ask', f"{base_cmd} listing directory outside workspace requires approval: {cwd}"

            for f_op in file_operands:
                if f_op in ('/dev/null', '/dev/zero', '/dev/stdin', '-'):
                    continue
                if any(c in f_op for c in ('$', '`', '*', '?', '[', ']', ';', '&', '|', '<', '>', '(', ')')):
                    return 'ask', f"Inspection command operand with wildcard, variable, substitution, or metacharacter requires confirmation: {f_op}"
                norm_fop = os.path.normpath(expand_path(f_op, cwd))
                if written_files:
                    for wf in written_files:
                        norm_wf = os.path.normpath(wf)
                        if norm_fop == norm_wf or norm_fop.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_fop + os.sep):
                            return 'force_ask', f"Inspection command reading file modified or updated earlier in the command line requires confirmation: {f_op}"
                if is_sensitive_credential_path(f_op, cwd):
                    return 'deny', f"Access to sensitive credential or key is forbidden: {f_op}"
                if base_cmd in {'ls', 'dir', 'vdir'} and (norm_fop in SYSTEM_BIN_DIRS or os.path.dirname(norm_fop) in SYSTEM_BIN_DIRS):
                    continue
                if not is_path_in_workspaces(f_op, workspace_paths, cwd):
                    return 'ask', f"Inspection command reading file outside workspace requires approval: {f_op}"
        if base_cmd == 'echo':
            if raw_subcmd is not None:
                if subcmd_has_unquoted_expansions(raw_subcmd):
                    return 'ask', f"echo with variable expansion requires confirmation: {' '.join(cmd_tokens)}"
            else:
                for a in args:
                    if any(c in a for c in ('$', '`')):
                        return 'ask', f"echo with variable expansion requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'date':
            def is_date_set_opt(a):
                if a == '--set' or a.startswith('--set='):
                    return True
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    if '--set'.startswith(opt) and len(opt) >= 3:
                        return True
                if a.startswith('-') and not a.startswith('--') and len(a) > 1:
                    j = 1
                    while j < len(a):
                        ch = a[j]
                        if ch == 's':
                            return True
                        if ch in ('d', 'f', 'r', 'I'):
                            break
                        j += 1
                return False
            if any(is_date_set_opt(a) for a in args) or any(re.match(r'^\d{8,12}(\.\d{2})?$', a) for a in args if not a.startswith('-') and not a.startswith('+')):
                return 'force_ask', f"date with system clock setting requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'printf':
            v_var = None
            if any(a == '-v' or a.startswith('-v') for a in args):
                for i, a in enumerate(args):
                    if a == '-v' and i + 1 < len(args):
                        v_var = args[i + 1]
                        break
                    elif a.startswith('-v') and len(a) > 2:
                        v_var = a[2:]
                        break
                if v_var and (is_dangerous_env_var(v_var) or is_credential_var_name(v_var)):
                    return 'deny', f"Setting execution-altering environment variable via printf is forbidden: {v_var}"

            def has_printf_n_specifier(fmt_str: str) -> bool:
                clean = fmt_str.replace('%%', '')
                return bool(re.search(r"%[-+ #0']*(?:\d+\$)?(?:\*|\d+)?(?:\.(?:\*|\d+))?(?:hh|h|ll|l|L|j|z|t)?n", clean))

            fmt_arg = None
            pos_args = []
            idx_a = 0
            while idx_a < len(args):
                a_tok = args[idx_a]
                if a_tok == '--':
                    idx_a += 1
                    if idx_a < len(args):
                        fmt_arg = args[idx_a]
                        pos_args = args[idx_a + 1:]
                    break
                if a_tok == '-v':
                    idx_a += 2
                    continue
                if a_tok.startswith('-v'):
                    idx_a += 1
                    continue
                if a_tok.startswith('-'):
                    idx_a += 1
                    continue
                fmt_arg = a_tok
                pos_args = args[idx_a + 1:]
                break

            cand_fmt_list = [fmt_arg] if fmt_arg is not None else []
            if fmt_arg and any(c in fmt_arg for c in ('*', '?', '[')) and cwd and os.path.isdir(cwd):
                try:
                    expanded_fmts = glob.glob(os.path.join(cwd, fmt_arg))
                    if expanded_fmts:
                        cand_fmt_list.extend(os.path.basename(p) for p in expanded_fmts)
                except Exception:
                    pass

            cand_pos_args = list(pos_args)
            for pa in pos_args:
                if any(c in pa for c in ('*', '?', '[')) and cwd and os.path.isdir(cwd):
                    try:
                        expanded_pas = glob.glob(os.path.join(cwd, pa))
                        if expanded_pas:
                            cand_pos_args.extend(os.path.basename(p) for p in expanded_pas)
                    except Exception:
                        pass

            for cf in cand_fmt_list:
                if cf and has_printf_n_specifier(cf):
                    for pa in cand_pos_args:
                        if is_dangerous_env_var(pa) or is_credential_var_name(pa):
                            return 'deny', f"Setting execution-altering environment variable via printf is forbidden: {pa}"

            if v_var is not None:
                cand_v = [v_var]
                if any(c in v_var for c in ('*', '?', '[')) and cwd and os.path.isdir(cwd):
                    try:
                        expanded_vs = glob.glob(os.path.join(cwd, v_var))
                        if expanded_vs:
                            cand_v.extend(os.path.basename(p) for p in expanded_vs)
                    except Exception:
                        pass
                for cv in cand_v:
                    if cv and (is_dangerous_env_var(cv) or is_credential_var_name(cv)):
                        return 'deny', f"Setting execution-altering environment variable via printf is forbidden: {cv}"

            if raw_subcmd is not None:
                if subcmd_has_unquoted_expansions(raw_subcmd):
                    return 'ask', f"printf with variable expansion requires confirmation: {' '.join(cmd_tokens)}"
                if subcmd_has_unquoted_wildcards(raw_subcmd):
                    return 'ask', f"printf with wildcard pattern requires confirmation: {' '.join(cmd_tokens)}"
            else:
                for a in args:
                    if any(c in a for c in ('$', '`')):
                        return 'ask', f"printf with variable expansion requires confirmation: {' '.join(cmd_tokens)}"
                    if any(c in a for c in ('*', '?', '[', ']')):
                        return 'ask', f"printf with wildcard pattern requires confirmation: {' '.join(cmd_tokens)}"

            if v_var is not None:
                return 'ask', f"printf with variable assignment (-v) requires confirmation: {' '.join(cmd_tokens)}"

            n_spec = any(cf and has_printf_n_specifier(cf) for cf in cand_fmt_list)
            if n_spec:
                return 'ask', f"printf with %n variable assignment requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'uniq':
            positionals = [a for a in args if not a.startswith('-')]
            if len(positionals) > 1:
                return 'ask', f"uniq with output file operand requires confirmation: {' '.join(cmd_tokens)}"
        return 'allow', f"Safe inspection command: {base_cmd}"

    # Ripgrep and Silver Searcher: safe unless using external preprocessors/pagers, searching hidden/symlink, or searching sensitive paths
    if base_cmd in {'rg', 'ag'}:
        if base_cmd == 'ag':
            # Silver Searcher passes --pager argument to popen()
            if any(a == '--pager' or a.startswith('--pager=') for a in args):
                return 'force_ask', f"ag with custom pager program requires confirmation: {' '.join(cmd_tokens)}"
            # ag -f or --follow traverses symlinks
            if any(a in ('-f', '--follow') or (a.startswith('-') and not a.startswith('--') and 'f' in a) for a in args):
                return 'ask', f"ag following symlinks (-f/--follow) requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'rg':
            all_rg_tokens = list(rg_cfg_tokens) + list(args)
            has_zip = False
            for tok in all_rg_tokens:
                if tok == '--':
                    break
                if tok == '--no-search-zip' or (tok.startswith('--') and '--no-search-zip'.startswith(tok.split('=', 1)[0]) and len(tok.split('=', 1)[0]) >= 6):
                    has_zip = False
                elif tok == '-z' or tok == '--search-zip' or (tok.startswith('--') and '--search-zip'.startswith(tok.split('=', 1)[0]) and len(tok.split('=', 1)[0]) >= 5):
                    has_zip = True
                elif tok.startswith('-') and not tok.startswith('--') and 'z' in tok:
                    has_zip = True
            if has_zip:
                return 'force_ask', f"rg with compressed file search (-z/--search-zip) invokes external decompressor programs: {' '.join(cmd_tokens)}"
            rg_options = []
            for tok in all_rg_tokens:
                if tok == '--':
                    break
                rg_options.append(tok)
            if any(a.startswith(('--pre', '--hostname-bin')) or a in ('--pre', '--hostname-bin') for a in rg_options):
                return 'force_ask', f"rg with custom preprocessor or helper program requires confirmation: {' '.join(cmd_tokens)}"
        # Check for unexpanded variables
        for a in args:
            if '$' in a or '`' in a:
                return 'ask', f"{base_cmd} with unexpanded variable requires confirmation: {' '.join(cmd_tokens)}"
        # Check for hidden files, un-ignoring, or symlink following (including bundled short flags like -iL, -Lu)
        cli_options = []
        for a in args:
            if a == '--':
                break
            cli_options.append(a)
        if any(a.startswith(('--hidden', '--no-ignore', '--follow')) or (a.startswith('-') and not a.startswith('--') and any(c in a for c in ('L', 'u'))) for a in cli_options):
            return 'ask', f"{base_cmd} with hidden files or symlink following requires confirmation: {' '.join(cmd_tokens)}"
        if base_cmd == 'rg':
            all_rg_tokens = list(rg_cfg_tokens) + list(args)
            has_pattern_flag, pattern_files, positionals, globs = parse_rg_args(all_rg_tokens)
        else:
            positionals = [a for a in args if not a.startswith('-')]
            has_pattern_flag = any(
                a in ('-e', '--regexp') or a.startswith(('-e', '--regexp='))
                for a in args
            )
            pattern_files = []
            globs = []

        # Check globs for sensitive patterns
        for g in globs:
            if matches_sensitive_pattern(g) or any(c in g for c in ('.env', 'id_rsa', 'id_ed25519', '.key', '.pem')):
                return 'deny', f"{base_cmd} with glob targeting sensitive pattern is forbidden: {g}"

        include_vcs = (base_cmd == 'rg') and (
            any(glob_matches_vcs(g) for g in globs) or
            any(a == '--no-ignore-vcs' or a.startswith('--no-ignore-vcs') for a in all_rg_tokens)
        )

        # Validate pattern files
        for pf in pattern_files:
            if pf == '-':
                continue
            if is_sensitive_credential_path(pf, cwd) or matches_sensitive_pattern(pf):
                return 'deny', f"{base_cmd} pattern file targeting sensitive path is forbidden: {pf}"
            if not is_path_in_workspaces(pf, workspace_paths, cwd):
                return 'ask', f"{base_cmd} pattern file outside workspace requires approval: {pf}"
            if written_files:
                norm_pf = os.path.normpath(expand_path(pf, cwd))
                for wf in written_files:
                    norm_wf = os.path.normpath(wf)
                    if norm_pf == norm_wf or norm_pf.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_pf + os.sep):
                        return 'force_ask', f"{base_cmd} pattern file was modified or updated earlier in the command line: {pf}"

        search_paths = positionals if has_pattern_flag else positionals[1:]
        if not search_paths:
            search_paths = [cwd]
        for p in search_paths:
            if p == '-':
                continue
            if written_files:
                norm_p = os.path.normpath(expand_path(p, cwd))
                for wf in written_files:
                    norm_wf = os.path.normpath(wf)
                    if norm_p == norm_wf or norm_p.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_p + os.sep):
                        return 'force_ask', f"{base_cmd} searching path modified or updated earlier in the command line: {p}"
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
                desc_verdict, desc_reason = check_directory_descendants(p_norm, cwd, include_vcs=include_vcs)
                if desc_verdict != 'allow':
                    return desc_verdict, f"Directory search {desc_reason}: {p}"
        return 'allow', 'Safe grep query'

    # Grep: safe unless searching sensitive directories or recursive search
    if base_cmd in {'grep', 'egrep', 'fgrep'}:
        # Check for unexpanded variables
        for a in args:
            if '$' in a or '`' in a:
                return 'ask', f"grep with unexpanded variable requires confirmation: {' '.join(cmd_tokens)}"

        has_pattern, pattern_files, is_recursive, positionals = parse_grep_args(args)

        # Check pattern files (from -f / --file / --exclude-from)
        for pf in pattern_files:
            if pf == '-':
                continue
            if is_sensitive_credential_path(pf, cwd) or matches_sensitive_pattern(pf):
                return 'deny', f"grep pattern file targeting sensitive path is forbidden: {pf}"
            if not is_path_in_workspaces(pf, workspace_paths, cwd):
                return 'ask', f"grep pattern file outside workspace requires approval: {pf}"
            if written_files:
                norm_pf = os.path.normpath(expand_path(pf, cwd))
                for wf in written_files:
                    norm_wf = os.path.normpath(wf)
                    if norm_pf == norm_wf or norm_pf.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_pf + os.sep):
                        return 'force_ask', f"grep pattern file was modified or updated earlier in the command line: {pf}"

        search_paths = positionals if has_pattern else positionals[1:]

        for p in search_paths:
            if p == '-':
                continue
            if written_files:
                norm_p = os.path.normpath(expand_path(p, cwd))
                for wf in written_files:
                    norm_wf = os.path.normpath(wf)
                    if norm_p == norm_wf or norm_p.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_p + os.sep):
                        return 'force_ask', f"grep searching path modified or updated earlier in the command line: {p}"
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
            if p == '-':
                continue
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
        out_targets = []
        temp_dirs = []
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
                    if '--output'.startswith(opt_name) and len(opt_name) >= 3:
                        out_targets.append(decode_shell_target(val))
                    elif '--temporary-directory'.startswith(opt_name) and len(opt_name) >= 3:
                        temp_dirs.append(decode_shell_target(val))
                    elif '--files0-from'.startswith(opt_name) and len(opt_name) >= 3:
                        files0_from = val
                    i += 1
                    continue
                elif opt_name in SORT_OPTS_WITH_ARG or any(long_opt.startswith(opt_name) for long_opt in SORT_OPTS_WITH_ARG if long_opt.startswith('--')):
                    if i + 1 < len(args):
                        val = args[i + 1]
                        if '--output'.startswith(opt_name) and len(opt_name) >= 3:
                            out_targets.append(decode_shell_target(val))
                        elif '--temporary-directory'.startswith(opt_name) and len(opt_name) >= 3:
                            temp_dirs.append(decode_shell_target(val))
                        elif '--files0-from'.startswith(opt_name) and len(opt_name) >= 3:
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
                        out_targets.append(decode_shell_target(rest))
                    elif i + 1 < len(args):
                        out_targets.append(decode_shell_target(args[i + 1]))
                        i += 1
                elif 'T' in a:
                    t_idx = a.index('T')
                    rest = a[t_idx + 1:].lstrip('=')
                    if rest:
                        temp_dirs.append(decode_shell_target(rest))
                    elif i + 1 < len(args):
                        temp_dirs.append(decode_shell_target(args[i + 1]))
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

        for out_target in out_targets:
            if not out_target:
                continue
            if is_sensitive_credential_path(out_target, cwd) or is_system_write_path(out_target, cwd):
                return 'deny', f"sort output targeting sensitive or system path is forbidden: {out_target}"
            if is_git_admin_path(out_target, cwd):
                return 'ask', f"sort modifying git repository configuration or hooks requires confirmation: {out_target}"
            if is_security_guard_path(out_target, cwd):
                return 'force_ask', f"sort modifying security configuration requires confirmation: {out_target}"
            if not is_path_in_workspaces(out_target, workspace_paths, cwd):
                return 'ask', f"sort output outside workspace requires approval: {out_target}"

        for temp_dir in temp_dirs:
            if not temp_dir:
                continue
            if is_sensitive_credential_path(temp_dir, cwd) or is_system_write_path(temp_dir, cwd):
                return 'deny', f"sort temporary directory targeting sensitive or system path is forbidden: {temp_dir}"
            if not is_path_in_workspaces(temp_dir, workspace_paths, cwd):
                return 'ask', f"sort temporary directory outside workspace requires approval: {temp_dir}"

        if files0_from:
            f0_verdict = validate_files0_from(files0_from, 'sort', cmd_tokens, workspace_paths, cwd, written_files=written_files)
            if f0_verdict:
                return f0_verdict

        for inf in input_files:
            if inf == '-':
                continue
            if written_files:
                norm_inf = os.path.normpath(expand_path(inf, cwd))
                for wf in written_files:
                    norm_wf = os.path.normpath(wf)
                    if norm_inf == norm_wf or norm_inf.startswith(norm_wf + os.sep):
                        return 'force_ask', f"sort reading file modified or updated earlier in the command line: {inf}"
            if is_sensitive_credential_path(inf, cwd) or matches_sensitive_pattern(inf):
                return 'deny', f"sort reading sensitive file is forbidden: {inf}"
            if not is_path_in_workspaces(inf, workspace_paths, cwd):
                return 'ask', f"sort reading file outside workspace requires approval: {inf}"

        return 'allow', 'Safe sort command'

    # Find: safe ONLY without destructive, execution, or file writing options
    if base_cmd == 'find':
        for a in args:
            if '$' in a or '`' in a:
                return 'ask', f"find with unexpanded variable requires confirmation: {' '.join(cmd_tokens)}"
        if any(a in ('-delete', '-exec', '-execdir', '-ok', '-okdir', '-fls', '-fprint', '-fprint0', '-fprintf') or a.startswith(('-exec', '-ok', '-fls', '-fprint')) for a in args):
            return 'ask', f"find with execution or write options requires confirmation: {' '.join(cmd_tokens)}"

        # Following symbolic links (-L or -follow) allows find to escape workspace boundaries
        if any(a in ('-L', '-follow') for a in args):
            return 'ask', f"find following symbolic links can traverse outside workspace: {' '.join(cmd_tokens)}"

        # -files0-from reads search roots from an external file or stdin
        files0_from = None
        for i, a in enumerate(args):
            if a in ('-files0-from', '--files0-from') and i + 1 < len(args):
                files0_from = args[i + 1]
            elif a.startswith(('-files0-from=', '--files0-from=')):
                files0_from = a.split('=', 1)[1]

        if files0_from:
            if files0_from == '-':
                return 'ask', f"find reading search roots from stdin requires confirmation: {' '.join(cmd_tokens)}"
            if is_sensitive_credential_path(files0_from, cwd):
                return 'deny', f"find reading search roots from sensitive path is forbidden: {files0_from}"
            return 'ask', f"find reading search roots from file requires confirmation: {files0_from}"

        # Check search roots (handling leading flags like -H, -P, -D, -O)
        search_roots = []
        i = 0
        while i < len(args):
            a = args[i]
            if a in ('-H', '-P'):
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
        if any(a.startswith('+') for a in args):
            return 'force_ask', f"cargo with toolchain override requires confirmation: {' '.join(cmd_tokens)}"
        rustup_tc = os.environ.get('RUSTUP_TOOLCHAIN')
        if rustup_tc and (rustup_tc.startswith(('/', '.')) or os.path.exists(rustup_tc)):
            return 'force_ask', f"cargo with custom RUSTUP_TOOLCHAIN requires confirmation: {rustup_tc}"
        if args:
            sub = args[0]
            if sub == 'fmt':
                rustfmt_env = os.environ.get('RUSTFMT')
                if rustfmt_env and rustfmt_env.strip():
                    return 'force_ask', f"cargo fmt with custom RUSTFMT executable requires confirmation: {rustfmt_env}"
                # Validate cargo-fmt and rustfmt executable resolution to prevent workspace PATH hijacking
                for helper_name in ('cargo-fmt', 'rustfmt'):
                    h_path = shutil.which(helper_name)
                    if h_path:
                        if is_sensitive_credential_path(h_path, cwd) or matches_sensitive_pattern(h_path):
                            return 'deny', f"cargo fmt executes {helper_name} referencing sensitive path: {h_path}"
                        if not is_trusted_executable_path(h_path, workspace_paths, cwd, helper_name):
                            return 'force_ask', f"cargo fmt executes untrusted or workspace-controlled {helper_name} helper: {h_path}"
                        h_dir = os.path.dirname(os.path.normpath(h_path))
                        if not is_valid_tool_binary_dir(helper_name, h_dir):
                            return 'force_ask', f"cargo fmt executes {helper_name} shadowed by non-system binary: {h_path}"
                        if written_files:
                            norm_h = os.path.normpath(h_path)
                            for wf in written_files:
                                norm_wf = os.path.normpath(wf)
                                if norm_h == norm_wf or norm_h.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_h + os.sep):
                                    return 'force_ask', f"cargo fmt with {helper_name} executable modified earlier in command line requires confirmation: {h_path}"
                for local_cand in ('cargo-fmt', 'rustfmt', os.path.join('bin', 'cargo-fmt'), os.path.join('bin', 'rustfmt')):
                    local_path = os.path.join(cwd, local_cand) if cwd else local_cand
                    if os.path.isfile(local_path) and os.access(local_path, os.X_OK):
                        return 'force_ask', f"cargo fmt with workspace-local {local_cand} requires confirmation: {local_path}"
                if written_files:
                    for wf in written_files:
                        bname = os.path.basename(wf)
                        if bname in ('Cargo.toml', 'rustfmt', 'rustfmt.toml', '.rustfmt.toml'):
                            return 'force_ask', f"cargo fmt with {bname} modified earlier in command line requires confirmation: {wf}"
                search_dirs = [Path(cwd).resolve() if cwd else Path.cwd().resolve()]
                for idx_arg, a in enumerate(args[1:]):
                    if a == '--manifest-path' and idx_arg + 1 < len(args[1:]):
                        mp = Path(expand_path(args[1:][idx_arg + 1], cwd)).resolve()
                        search_dirs.append(mp.parent if mp.is_file() else mp)
                    elif a.startswith('--manifest-path='):
                        mp = Path(expand_path(a.split('=', 1)[1], cwd)).resolve()
                        search_dirs.append(mp.parent if mp.is_file() else mp)
                for s_dir in search_dirs:
                    curr = s_dir
                    while True:
                        cargo_file = curr / 'Cargo.toml'
                        if written_files:
                            norm_cf = os.path.normpath(str(cargo_file))
                            for wf in written_files:
                                norm_wf = os.path.normpath(wf)
                                if norm_cf == norm_wf or norm_wf.startswith(norm_cf + os.sep):
                                    return 'force_ask', f"cargo fmt with Cargo.toml modified earlier in command line requires confirmation: {cargo_file}"
                        if cargo_file.is_file():
                            try:
                                cargo_text = cargo_file.read_text(errors='replace')
                                target_paths = []
                                if tomllib:
                                    try:
                                        c_data = tomllib.loads(cargo_text)
                                        if isinstance(c_data, dict):
                                            lib_sec = c_data.get('lib')
                                            if isinstance(lib_sec, dict) and 'path' in lib_sec:
                                                target_paths.append(str(lib_sec['path']))
                                            for sec_name in ('bin', 'example', 'test', 'bench'):
                                                sec_val = c_data.get(sec_name)
                                                if isinstance(sec_val, list):
                                                    for item in sec_val:
                                                        if isinstance(item, dict) and 'path' in item:
                                                            target_paths.append(str(item['path']))
                                                elif isinstance(sec_val, dict) and 'path' in sec_val:
                                                    target_paths.append(str(sec_val['path']))
                                    except Exception:
                                        pass
                                for m_path in re.finditer(r'(?m)^\s*path\s*=\s*["\']([^"\']+)["\']', cargo_text):
                                    target_paths.append(m_path.group(1))
                                for tp in target_paths:
                                    tp_clean = tp.strip('\'"')
                                    tp_full = os.path.normpath(expand_path(tp_clean, str(curr)))
                                    if not is_path_in_workspaces(tp_full, workspace_paths, cwd):
                                        return 'force_ask', f"cargo fmt target path in Cargo.toml points outside workspace: {tp_clean}"
                                    if is_sensitive_credential_path(tp_full, cwd) or matches_sensitive_pattern(tp_full):
                                        return 'deny', f"cargo fmt target path in Cargo.toml points to sensitive credential: {tp_clean}"
                                    if is_system_write_path(tp_full, cwd):
                                        return 'deny', f"cargo fmt target path in Cargo.toml points to system path: {tp_clean}"
                                    if is_security_guard_path(tp_full, cwd):
                                        return 'force_ask', f"cargo fmt target path in Cargo.toml points to security guard: {tp_clean}"
                                    if is_git_admin_path(tp_full, cwd):
                                        return 'force_ask', f"cargo fmt target path in Cargo.toml points to git repository metadata: {tp_clean}"
                            except Exception:
                                pass

                        for tc_name in ('rust-toolchain.toml', 'rust-toolchain'):
                            tc_file = curr / tc_name
                            norm_tc = os.path.normpath(str(tc_file))
                            real_tc = os.path.realpath(norm_tc)
                            if written_files:
                                for wf in written_files:
                                    norm_wf = os.path.normpath(wf)
                                    real_wf = os.path.realpath(norm_wf)
                                    if (norm_tc == norm_wf or norm_wf.startswith(norm_tc + os.sep) or norm_tc.startswith(norm_wf + os.sep) or
                                        real_tc == real_wf or real_wf.startswith(real_tc + os.sep) or real_tc.startswith(norm_wf + os.sep)):
                                        return 'force_ask', f"cargo fmt with toolchain file modified earlier in command line requires confirmation: {tc_file}"
                            if tc_file.is_file():
                                try:
                                    tc_text = tc_file.read_text(errors='replace')
                                    if re.search(r'(?m)^\s*path\s*=', tc_text) or 'toolchain.path' in tc_text:
                                        return 'force_ask', f"cargo fmt with custom toolchain path in {tc_name} requires confirmation: {' '.join(cmd_tokens)}"
                                    if tomllib:
                                        tc_data = tomllib.loads(tc_text)
                                        if isinstance(tc_data, dict):
                                            tc_section = tc_data.get('toolchain')
                                            if isinstance(tc_section, dict) and 'path' in tc_section:
                                                return 'force_ask', f"cargo fmt with custom toolchain path in {tc_name} requires confirmation: {' '.join(cmd_tokens)}"
                                except Exception:
                                    pass
                        if curr.parent == curr:
                            break
                        curr = curr.parent

                    # Inspect .rs files for #[path = "..."] module path attributes pointing outside workspace
                    try:
                        for root_d, dirs, files in os.walk(str(s_dir)):
                            dirs[:] = [d for d in dirs if not d.startswith('.') and d not in ('target', 'node_modules', 'vendor')]
                            for fname in files:
                                if fname.endswith('.rs'):
                                    rs_path = os.path.join(root_d, fname)
                                    try:
                                        with open(rs_path, 'r', encoding='utf-8', errors='replace') as rf:
                                            rs_text = rf.read()
                                        if 'path' not in rs_text:
                                            continue
                                        for mp in re.finditer(r'#!?\[\s*path\s*=\s*(?:r(#*)"(.*?)"\1|["\']([^"\']*)["\'])\s*\]', rs_text):
                                            m_target = (mp.group(2) if mp.group(2) is not None else mp.group(3)).strip()
                                            mod_full = os.path.normpath(expand_path(m_target, root_d))
                                            if not is_path_in_workspaces(mod_full, workspace_paths, cwd):
                                                return 'force_ask', f"cargo fmt module path attribute in {fname} points outside workspace: {m_target}"
                                            if is_sensitive_credential_path(mod_full, cwd) or matches_sensitive_pattern(mod_full):
                                                return 'deny', f"cargo fmt module path attribute in {fname} points to sensitive credential: {m_target}"
                                            if is_system_write_path(mod_full, cwd):
                                                return 'deny', f"cargo fmt module path attribute in {fname} points to system path: {m_target}"
                                            if is_security_guard_path(mod_full, cwd):
                                                return 'force_ask', f"cargo fmt module path attribute in {fname} points to security guard: {m_target}"
                                            if is_git_admin_path(mod_full, cwd):
                                                return 'force_ask', f"cargo fmt module path attribute in {fname} points to git repository metadata: {m_target}"
                                    except Exception:
                                        pass
                    except Exception:
                        pass
                if written_files:
                    for wf in written_files:
                        if wf.endswith('.rs') and os.path.isfile(wf):
                            try:
                                with open(wf, 'r', encoding='utf-8', errors='replace') as rf:
                                    rs_text = rf.read()
                                if 'path' in rs_text:
                                    for mp in re.finditer(r'#!?\[\s*path\s*=\s*(?:r(#*)"(.*?)"\1|["\']([^"\']*)["\'])\s*\]', rs_text):
                                        m_target = (mp.group(2) if mp.group(2) is not None else mp.group(3)).strip()
                                        mod_full = os.path.normpath(expand_path(m_target, os.path.dirname(wf)))
                                        if not is_path_in_workspaces(mod_full, workspace_paths, cwd):
                                            return 'force_ask', f"cargo fmt module path attribute in {os.path.basename(wf)} points outside workspace: {m_target}"
                                        if is_sensitive_credential_path(mod_full, cwd) or matches_sensitive_pattern(mod_full):
                                            return 'deny', f"cargo fmt module path attribute in {os.path.basename(wf)} points to sensitive credential: {m_target}"
                                        if is_system_write_path(mod_full, cwd):
                                            return 'deny', f"cargo fmt module path attribute in {os.path.basename(wf)} points to system path: {m_target}"
                                        if is_security_guard_path(mod_full, cwd):
                                            return 'force_ask', f"cargo fmt module path attribute in {os.path.basename(wf)} points to security guard: {m_target}"
                                        if is_git_admin_path(mod_full, cwd):
                                            return 'force_ask', f"cargo fmt module path attribute in {os.path.basename(wf)} points to git repository metadata: {m_target}"
                            except Exception:
                                pass
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
            GO_EXECUTABLE_HELPERS = {
                'CC': ('gcc', 'clang'),
                'CXX': ('g++', 'clang++'),
                'FC': ('gfortran',),
                'GCCGO': ('gccgo',),
                'AR': ('ar',),
                'NM': ('nm',),
                'PKG_CONFIG': ('pkg-config',),
            }
            for helper_var, default_candidates in GO_EXECUTABLE_HELPERS.items():
                hval = get_inherited_go_setting(helper_var)
                if hval and hval.strip():
                    try:
                        hparts = shlex.split(hval)
                    except Exception:
                        hparts = hval.split()
                    if not hparts:
                        continue
                    for hp in hparts:
                        if is_sensitive_credential_path(hp, cwd) or matches_sensitive_pattern(hp):
                            return 'deny', f"go {args[0]} with {helper_var} referencing sensitive path is forbidden: {hp}"
                    hexe = hparts[0]
                    resolved_hexe = shutil.which(hexe)
                    if not resolved_hexe:
                        resolved_hexe = expand_path(hexe, cwd)
                    if not is_trusted_executable_path(resolved_hexe, workspace_paths, cwd, os.path.basename(resolved_hexe)):
                        return 'force_ask', f"go {args[0]} with untrusted or workspace-controlled {helper_var} ({hexe}) requires confirmation: {hval}"
                    if written_files:
                        norm_hexe = os.path.normpath(resolved_hexe)
                        for wf in written_files:
                            norm_wf = os.path.normpath(wf)
                            if norm_hexe == norm_wf or norm_hexe.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_hexe + os.sep):
                                return 'force_ask', f"go {args[0]} with {helper_var} executable modified earlier in command line requires confirmation: {hval}"
                    for opt in hparts[1:]:
                        opt_clean = opt.split('=', 1)[1] if '=' in opt else opt
                        norm_opt = os.path.normpath(expand_path(opt_clean, cwd))
                        if is_path_in_workspaces(norm_opt, workspace_paths, cwd) or any(norm_opt.startswith(p) for p in ('/tmp', '/var/tmp', '/dev/shm')):
                            return 'force_ask', f"go {args[0]} with {helper_var} referencing untrusted or workspace path requires confirmation: {opt}"
                else:
                    # When helper is not explicitly set, validate default helper binaries resolved through PATH or workspace
                    for cand in default_candidates:
                        cand_local = expand_path(cand, cwd)
                        if written_files:
                            norm_local = os.path.normpath(cand_local)
                            for wf in written_files:
                                norm_wf = os.path.normpath(wf)
                                if norm_local == norm_wf or norm_local.startswith(norm_wf + os.sep):
                                    return 'force_ask', f"go {args[0]} default {helper_var} executable ({cand}) created or modified earlier in command line requires confirmation: {cand_local}"
                        if os.path.isfile(cand_local) and not is_trusted_executable_path(cand_local, workspace_paths, cwd, cand):
                            return 'force_ask', f"go {args[0]} workspace-controlled default {helper_var} executable ({cand}) requires confirmation: {cand_local}"
                        resolved_cand = shutil.which(cand)
                        if resolved_cand:
                            if not is_trusted_executable_path(resolved_cand, workspace_paths, cwd, cand):
                                return 'force_ask', f"go {args[0]} default {helper_var} ({cand}) resolves to untrusted or workspace path: {resolved_cand}"
                            if written_files:
                                norm_cand = os.path.normpath(resolved_cand)
                                for wf in written_files:
                                    norm_wf = os.path.normpath(wf)
                                    if norm_cand == norm_wf or norm_cand.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_cand + os.sep):
                                        return 'force_ask', f"go {args[0]} default {helper_var} executable ({cand}) modified earlier in command line requires confirmation: {resolved_cand}"

            for root_var in ('GOTOOLDIR', 'GOROOT'):
                rval = get_inherited_go_setting(root_var)
                if rval and rval.strip():
                    norm_rv = os.path.normpath(expand_path(rval.strip(), cwd))
                    if is_sensitive_credential_path(norm_rv, cwd) or matches_sensitive_pattern(norm_rv):
                        return 'deny', f"go {args[0]} with {root_var} targeting sensitive path is forbidden: {rval}"
                    if is_path_in_workspaces(norm_rv, workspace_paths, cwd) or any(norm_rv.startswith(p) for p in ('/tmp', '/var/tmp', '/dev/shm')):
                        return 'force_ask', f"go {args[0]} with untrusted or workspace-controlled {root_var} requires confirmation: {rval}"
                    if written_files:
                        for wf in written_files:
                            norm_wf = os.path.normpath(wf)
                            if norm_rv == norm_wf or norm_rv.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_rv + os.sep):
                                return 'force_ask', f"go {args[0]} with {root_var} modified earlier in command line requires confirmation: {rval}"

            gtc = get_inherited_go_setting('GOTOOLCHAIN')
            if gtc and gtc.strip():
                gtc_clean = gtc.strip()
                if is_sensitive_credential_path(gtc_clean, cwd) or matches_sensitive_pattern(gtc_clean):
                    return 'deny', f"go {args[0]} with GOTOOLCHAIN targeting sensitive path is forbidden: {gtc}"
                if '/' in gtc_clean or '\\' in gtc_clean:
                    norm_gtc = os.path.normpath(expand_path(gtc_clean, cwd))
                    if is_path_in_workspaces(norm_gtc, workspace_paths, cwd) or any(norm_gtc.startswith(p) for p in ('/tmp', '/var/tmp', '/dev/shm')):
                        return 'force_ask', f"go {args[0]} with untrusted or workspace-controlled GOTOOLCHAIN requires confirmation: {gtc}"
                    if written_files:
                        for wf in written_files:
                            norm_wf = os.path.normpath(wf)
                            if norm_gtc == norm_wf or norm_gtc.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_gtc + os.sep):
                                return 'force_ask', f"go {args[0]} with GOTOOLCHAIN modified earlier in command line requires confirmation: {gtc}"
                gtc_base = gtc_clean.split('+', 1)[0].strip()
                if gtc_base not in ('', 'local', 'default', 'auto', 'path'):
                    cand_local = expand_path(gtc_base, cwd)
                    if written_files:
                        norm_local = os.path.normpath(cand_local)
                        for wf in written_files:
                            norm_wf = os.path.normpath(wf)
                            if norm_local == norm_wf or norm_local.startswith(norm_wf + os.sep):
                                return 'force_ask', f"go {args[0]} GOTOOLCHAIN executable ({gtc_base}) created or modified earlier in command line requires confirmation: {cand_local}"
                    if os.path.isfile(cand_local) and not is_trusted_executable_path(cand_local, workspace_paths, cwd, gtc_base):
                        return 'force_ask', f"go {args[0]} workspace-controlled GOTOOLCHAIN executable ({gtc_base}) requires confirmation: {cand_local}"
                    resolved_cand = shutil.which(gtc_base)
                    if resolved_cand:
                        if not is_trusted_executable_path(resolved_cand, workspace_paths, cwd, gtc_base):
                            return 'force_ask', f"go {args[0]} GOTOOLCHAIN ({gtc}) resolves to untrusted or workspace path: {resolved_cand}"
                        if written_files:
                            norm_cand = os.path.normpath(resolved_cand)
                            for wf in written_files:
                                norm_wf = os.path.normpath(wf)
                                if norm_cand == norm_wf or norm_cand.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_cand + os.sep):
                                    return 'force_ask', f"go {args[0]} GOTOOLCHAIN executable ({gtc_base}) modified earlier in command line requires confirmation: {resolved_cand}"
                    else:
                        return 'force_ask', f"go {args[0]} with custom or non-local GOTOOLCHAIN ({gtc}) requires confirmation"

            if written_files:
                for wf in written_files:
                    if os.path.basename(wf) in ('go.mod', 'go.work'):
                        return 'force_ask', f"go {args[0]} with {os.path.basename(wf)} modified earlier in command line requires confirmation: {wf}"

            if (gtc or '').strip().split('+', 1)[0].strip() != 'local':
                effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
                curr_go = Path(effective_cwd).resolve()
                while True:
                    for tc_fname in ('go.work', 'go.mod'):
                        tc_f = curr_go / tc_fname
                        if tc_f.is_file():
                            try:
                                tc_text = tc_f.read_text(errors='replace')
                                m_tc = re.search(r'(?m)^\s*toolchain\s+([^\s\r\n]+)', tc_text)
                                if m_tc:
                                    tc_name = m_tc.group(1).strip()
                                    tc_base = tc_name.split('+', 1)[0].strip()
                                    if tc_base not in ('', 'local', 'default', 'auto', 'path'):
                                        cand_local = expand_path(tc_base, str(curr_go))
                                        if os.path.isfile(cand_local) and not is_trusted_executable_path(cand_local, workspace_paths, cwd, tc_base):
                                            return 'force_ask', f"go {args[0]} with workspace-controlled toolchain ({tc_base}) in {tc_fname} requires confirmation: {cand_local}"
                                        resolved_tc = shutil.which(tc_base)
                                        if resolved_tc:
                                            if not is_trusted_executable_path(resolved_tc, workspace_paths, cwd, tc_base):
                                                return 'force_ask', f"go {args[0]} toolchain ({tc_name}) in {tc_fname} resolves to untrusted or workspace path: {resolved_tc}"
                                        else:
                                            return 'force_ask', f"go {args[0]} with custom toolchain ({tc_name}) in {tc_fname} requires confirmation"
                                m_gv = re.search(r'(?m)^\s*go\s+([0-9]+(?:\.[0-9]+)*)', tc_text)
                                if m_gv:
                                    gv_str = m_gv.group(1).strip()
                                    gv_cand = f"go{gv_str}"
                                    cand_local = expand_path(gv_cand, str(curr_go))
                                    if os.path.isfile(cand_local) and not is_trusted_executable_path(cand_local, workspace_paths, cwd, gv_cand):
                                        return 'force_ask', f"go {args[0]} with workspace-controlled Go version executable ({gv_cand}) in {tc_fname} requires confirmation: {cand_local}"
                                    resolved_gv = shutil.which(gv_cand)
                                    if resolved_gv and not is_trusted_executable_path(resolved_gv, workspace_paths, cwd, gv_cand):
                                        return 'force_ask', f"go {args[0]} Go version executable ({gv_cand}) in {tc_fname} resolves to untrusted or workspace path: {resolved_gv}"
                            except Exception:
                                pass
                    if curr_go.parent == curr_go:
                        break
                    curr_go = curr_go.parent

            cgo_flag_vars = ('CGO_CFLAGS', 'CGO_CPPFLAGS', 'CGO_CXXFLAGS', 'CGO_FFLAGS', 'CGO_LDFLAGS')
            for flag_var in cgo_flag_vars:
                fval = get_inherited_go_setting(flag_var)
                if fval and fval.strip():
                    try:
                        fparts = shlex.split(fval)
                    except Exception:
                        fparts = fval.split()
                    for fp in fparts:
                        if is_sensitive_credential_path(fp, cwd) or matches_sensitive_pattern(fp):
                            return 'deny', f"go {args[0]} with {flag_var} referencing sensitive path is forbidden: {fp}"
                        if any(unsafe_opt in fp for unsafe_opt in ('--plugin', '-plugin', '-B')):
                            return 'force_ask', f"go {args[0]} with {flag_var} specifying custom plugin or binary search directory requires confirmation: {fp}"
                        if written_files:
                            norm_fp = os.path.normpath(expand_path(fp, cwd))
                            for wf in written_files:
                                norm_wf = os.path.normpath(wf)
                                if norm_fp == norm_wf or norm_fp.startswith(norm_wf + os.sep) or norm_fp.startswith(norm_fp + os.sep):
                                    return 'force_ask', f"go {args[0]} with {flag_var} file modified earlier in command line requires confirmation: {fp}"

            UNSAFE_GO_FLAGS = {
                '-exec', '--exec',
                '-toolexec', '--toolexec',
                '-vettool', '--vettool',
                '-compiler', '--compiler',
                '-gccgoflags', '--gccgoflags',
                '-ldflags', '--ldflags',
                '-modfile', '--modfile',
                '-overlay', '--overlay',
                '-pkgdir', '--pkgdir',
                '-toolchain', '--toolchain',
            }
            for a in args[1:]:
                opt_name = a.split('=', 1)[0]
                if opt_name in UNSAFE_GO_FLAGS or any(opt_name.startswith(f) for f in UNSAFE_GO_FLAGS):
                    return 'force_ask', f"go {args[0]} with custom tool or execution flag ({a}) requires confirmation: {' '.join(cmd_tokens)}"
                if opt_name in ('-mod', '--mod'):
                    if a not in ('-mod=readonly', '-mod=vendor', '--mod=readonly', '--mod=vendor'):
                        return 'force_ask', f"go {args[0]} with dependency downloading or mutating module flag ({a}) requires confirmation: {' '.join(cmd_tokens)}"
            inherited_goflags = get_inherited_goflags()
            goflags_tokens = []
            if inherited_goflags:
                try:
                    goflags_tokens = shlex.split(inherited_goflags)
                except Exception:
                    goflags_tokens = inherited_goflags.split()
                for a in goflags_tokens:
                    opt_name = a.split('=', 1)[0]
                    if opt_name in UNSAFE_GO_FLAGS or any(opt_name.startswith(f) for f in UNSAFE_GO_FLAGS):
                        return 'force_ask', f"go {args[0]} with inherited unsafe GOFLAGS ({a}) requires confirmation: {' '.join(cmd_tokens)}"
                    if opt_name in ('-mod', '--mod'):
                        if a not in ('-mod=readonly', '-mod=vendor', '--mod=readonly', '--mod=vendor'):
                            return 'force_ask', f"go {args[0]} with inherited module flag ({a}) requires confirmation: {' '.join(cmd_tokens)}"
            if written_files:
                goenv_file = os.environ.get('GOENV') or os.path.expanduser('~/.config/go/env')
                norm_goenv = os.path.normpath(goenv_file)
                for wf in written_files:
                    norm_wf = os.path.normpath(wf)
                    if norm_goenv == norm_wf or norm_goenv.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_goenv + os.sep):
                        return 'force_ask', f"go {args[0]} with Go environment configuration modified earlier in command line requires confirmation: {goenv_file}"
            if args[0] == 'test':
                return 'force_ask', f"go test executes workspace test code and requires confirmation: {' '.join(cmd_tokens)}"
            combined_go_args = list(args[1:]) + goflags_tokens
            nested_go_tool_args = []
            idx_go = 0
            while idx_go < len(combined_go_args):
                ga = combined_go_args[idx_go]
                g_val = None
                if ga in ('-gcflags', '--gcflags', '-asmflags', '--asmflags'):
                    if idx_go + 1 < len(combined_go_args):
                        g_val = combined_go_args[idx_go + 1]
                        idx_go += 1
                elif ga.startswith(('-gcflags=', '--gcflags=', '-asmflags=', '--asmflags=')):
                    g_val = ga.split('=', 1)[1]
                if g_val is not None:
                    if not g_val.startswith('-') and '=' in g_val:
                        g_val = g_val.split('=', 1)[1]
                    try:
                        g_tokens = shlex.split(g_val)
                    except Exception:
                        g_tokens = g_val.split()
                    nested_go_tool_args.extend(g_tokens)
                idx_go += 1

            all_go_check_args = combined_go_args + nested_go_tool_args
            in_check = check_dev_tool_inputs(all_go_check_args, workspace_paths, cwd, f"go {args[0]}")
            if in_check:
                return in_check
            out_check = check_dev_tool_output(all_go_check_args, workspace_paths, cwd, f"go {args[0]}")
            if out_check:
                return out_check

            if args[0] in {'build', 'test', 'vet'}:
                # Inspect Go source files for //go:embed directives targeting sensitive or external paths
                effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
                go_source_files = set()
                explicit_go_args = [ga for ga in args[1:] if ga.endswith('.go') and not ga.startswith('-')]
                for ga in explicit_go_args:
                    go_source_files.add(expand_path(ga, effective_cwd))
                if not explicit_go_args:
                    pkg_dirs = set()
                    skip_next_go_arg = False
                    for ga in args[1:]:
                        if skip_next_go_arg:
                            skip_next_go_arg = False
                            continue
                        if ga.startswith('-'):
                            opt_c = ga.split('=', 1)[0]
                            if opt_c in ('-p', '-asmflags', '-buildmode', '-compiler', '-gccgoflags', '-gcflags', '-installsuffix', '-ldflags', '-mod', '-modfile', '-overlay', '-pkgdir', '-tags', '-toolexec', '-work') and '=' not in ga:
                                skip_next_go_arg = True
                            continue
                        p_cand = expand_path(ga, effective_cwd)
                        if os.path.isdir(p_cand):
                            pkg_dirs.add(p_cand)
                    if not pkg_dirs:
                        pkg_dirs.add(effective_cwd)
                    scan_roots = set(pkg_dirs)
                    curr_mod = Path(effective_cwd).resolve()
                    while True:
                        if (curr_mod / 'go.mod').is_file() or (curr_mod / 'go.work').is_file():
                            scan_roots.add(str(curr_mod))
                            break
                        if curr_mod.parent == curr_mod:
                            break
                        curr_mod = curr_mod.parent

                    for root_dir in scan_roots:
                        try:
                            for root, dirs, files in os.walk(root_dir):
                                dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', 'target', 'vendor', '.hg', '.svn')]
                                for fname in files:
                                    if fname.endswith('.go'):
                                        go_source_files.add(os.path.join(root, fname))
                                        if len(go_source_files) >= 5000:
                                            break
                                if len(go_source_files) >= 5000:
                                    break
                        except Exception:
                            pass
                if written_files:
                    for wf in written_files:
                        if wf.endswith('.go') and os.path.isfile(wf):
                            go_source_files.add(wf)

                for gf_path in go_source_files:
                    if not os.path.isfile(gf_path):
                        continue
                    try:
                        with open(gf_path, 'r', encoding='utf-8', errors='replace') as gf:
                            gf_content = gf.read()
                    except Exception:
                        continue
                    if '//go:embed' not in gf_content:
                        continue
                    gf_dir = os.path.dirname(gf_path)
                    for m in re.finditer(r'(?m)^[ \t]*//go:embed[ \t]+([^\r\n]+)', gf_content):
                        embed_raw = m.group(1).strip()
                        try:
                            patterns = shlex.split(embed_raw)
                        except Exception:
                            patterns = embed_raw.split()
                        for pat in patterns:
                            pat_clean = pat.strip('\'"`')
                            if not pat_clean:
                                continue
                            if is_sensitive_credential_path(pat_clean, gf_dir) or matches_sensitive_pattern(pat_clean):
                                return 'deny', f"go {args[0]} embeds sensitive credential or key via //go:embed: {pat_clean}"
                            pat_full = os.path.normpath(expand_path(pat_clean, gf_dir))
                            if not is_path_in_workspaces(pat_full, workspace_paths, effective_cwd):
                                return 'force_ask', f"go {args[0]} embeds path outside workspace via //go:embed: {pat_clean}"
                            if is_sensitive_credential_path(pat_full, effective_cwd) or matches_sensitive_pattern(pat_full):
                                return 'deny', f"go {args[0]} embeds sensitive credential or key via //go:embed: {pat_full}"
                            if is_security_guard_path(pat_full, effective_cwd):
                                return 'force_ask', f"go {args[0]} embeds security configuration via //go:embed: {pat_full}"
                            if any(c in pat_clean for c in ('*', '?', '[')):
                                for matched_f in glob.glob(os.path.join(gf_dir, pat_clean), recursive=True):
                                    if is_sensitive_credential_path(matched_f, effective_cwd) or matches_sensitive_pattern(matched_f):
                                        return 'deny', f"go {args[0]} embeds sensitive credential or key via //go:embed: {matched_f}"
                                    if is_security_guard_path(matched_f, effective_cwd):
                                        return 'force_ask', f"go {args[0]} embeds security configuration via //go:embed: {matched_f}"
                                    if not is_path_in_workspaces(matched_f, workspace_paths, effective_cwd):
                                        return 'force_ask', f"go {args[0]} embeds path outside workspace via //go:embed: {matched_f}"
                            if written_files:
                                for wf in written_files:
                                    norm_wf = os.path.normpath(wf)
                                    if norm_wf == pat_full or fnmatch.fnmatch(norm_wf, pat_full) or fnmatch.fnmatch(os.path.basename(norm_wf), pat_clean):
                                        if is_sensitive_credential_path(norm_wf, effective_cwd) or matches_sensitive_pattern(norm_wf):
                                            return 'deny', f"go {args[0]} embeds sensitive credential or key via //go:embed: {norm_wf}"
                                        if is_security_guard_path(norm_wf, effective_cwd):
                                            return 'force_ask', f"go {args[0]} embeds security configuration via //go:embed: {norm_wf}"

            if args[0] == 'build':
                has_explicit_o = False
                for ga in all_go_check_args:
                    if ga in ('-o', '--output') or ga.startswith(('-o=', '--output=')):
                        has_explicit_o = True
                        break
                    if ga.startswith('-o') and len(ga) > 2 and not ga.startswith('--'):
                        has_explicit_o = True
                        break

                if not has_explicit_o:
                    candidate_implicit_names = set()
                    # 1. Inspect module name from go.mod in cwd or ancestors
                    curr_mod_dir = os.path.abspath(cwd) if isinstance(cwd, str) and cwd.strip() else os.getcwd()
                    while curr_mod_dir:
                        mod_file = os.path.join(curr_mod_dir, 'go.mod')
                        if os.path.isfile(mod_file):
                            try:
                                with open(mod_file, 'r', encoding='utf-8', errors='replace') as mf:
                                    for mline in mf:
                                        mline = mline.strip()
                                        if mline.startswith(('module ', 'module\t')):
                                            mod_path = mline.split(None, 1)[1].strip().strip('"\'')
                                            mod_base = posixpath.basename(mod_path.rstrip('/'))
                                            if mod_base:
                                                candidate_implicit_names.add(mod_base)
                                            break
                            except Exception:
                                pass
                            break
                        parent_mod = os.path.dirname(curr_mod_dir)
                        if not parent_mod or parent_mod == curr_mod_dir:
                            break
                        curr_mod_dir = parent_mod

                    # 2. Inspect cwd directory name
                    cwd_abs = os.path.abspath(cwd) if isinstance(cwd, str) and cwd.strip() else os.getcwd()
                    cwd_base = os.path.basename(cwd_abs)
                    if cwd_base:
                        candidate_implicit_names.add(cwd_base)

                    # 3. Inspect positional package arguments and source files
                    skip_next_go = False
                    for ga in args[1:]:
                        if skip_next_go:
                            skip_next_go = False
                            continue
                        if ga.startswith('-'):
                            opt_clean = ga.split('=', 1)[0]
                            if opt_clean in {
                                '-p', '--p',
                                '-asmflags', '--asmflags',
                                '-buildmode', '--buildmode',
                                '-buildvcs', '--buildvcs',
                                '-compiler', '--compiler',
                                '-gccgoflags', '--gccgoflags',
                                '-gcflags', '--gcflags',
                                '-installsuffix', '--installsuffix',
                                '-ldflags', '--ldflags',
                                '-mod', '--mod',
                                '-modcacheunzip', '--modcacheunzip',
                                '-modfile', '--modfile',
                                '-overlay', '--overlay',
                                '-pkgdir', '--pkgdir',
                                '-tags', '--tags',
                                '-toolexec', '--toolexec',
                                '-work', '--work',
                            } and '=' not in ga:
                                skip_next_go = True
                            continue
                        # Positional argument (package path or source file)
                        if ga.endswith('.go'):
                            stem = os.path.splitext(os.path.basename(ga))[0]
                            if stem:
                                candidate_implicit_names.add(stem)
                        else:
                            pkg_base = posixpath.basename(ga.rstrip('/'))
                            if pkg_base and pkg_base not in ('.', '..'):
                                candidate_implicit_names.add(pkg_base)
                            try:
                                norm_pkg = os.path.basename(os.path.normpath(expand_path(ga, cwd)))
                                if norm_pkg and norm_pkg not in ('.', '..'):
                                    candidate_implicit_names.add(norm_pkg)
                            except Exception:
                                pass

                    # Expand candidates with Windows .exe
                    for cname in list(candidate_implicit_names):
                        if not cname.endswith('.exe'):
                            candidate_implicit_names.add(cname + '.exe')

                    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
                    for cname in candidate_implicit_names:
                        dest = os.path.join(effective_cwd, cname)
                        if is_sensitive_credential_path(dest, cwd) or matches_sensitive_pattern(cname):
                            return 'deny', f"go build implicit output targets sensitive file: {dest}"
                        if is_system_write_path(dest, cwd):
                            return 'deny', f"go build implicit output targets system path: {dest}"
                        if is_security_guard_path(dest, cwd):
                            return 'force_ask', f"go build implicit output overwrites protected security guard: {dest}"
                        if is_git_admin_path(dest, cwd):
                            return 'force_ask', f"go build implicit output modifies git repository metadata: {dest}"
                        if not is_path_in_workspaces(dest, workspace_paths, cwd):
                            return 'force_ask', f"go build implicit output targeting destination outside workspace requires confirmation: {dest}"
                        if written_files:
                            norm_dest = os.path.normpath(expand_path(dest, cwd))
                            for wf in written_files:
                                norm_wf = os.path.normpath(wf)
                                if norm_dest == norm_wf or norm_dest.startswith(norm_wf + os.sep) or norm_wf.startswith(norm_dest + os.sep):
                                    return 'force_ask', f"go build implicit output file was modified or redirected to earlier in command line: {dest}"

            if args[0] in {'build', 'install', 'test'}:
                buildvcs_disabled = False
                for i_ga, ga in enumerate(all_go_check_args):
                    if ga in ('-buildvcs=false', '--buildvcs=false'):
                        buildvcs_disabled = True
                        break
                    if ga.startswith(('-buildvcs=', '--buildvcs=')) and ga.split('=', 1)[1] == 'false':
                        buildvcs_disabled = True
                        break
                    if ga in ('-buildvcs', '--buildvcs') and i_ga + 1 < len(all_go_check_args) and all_go_check_args[i_ga + 1] == 'false':
                        buildvcs_disabled = True
                        break

                if not buildvcs_disabled:
                    effective_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
                    probe_repo = git_run_probe(['rev-parse', '--is-inside-work-tree'], cwd=effective_cwd)
                    if probe_repo and probe_repo.returncode == 0 and probe_repo.stdout.strip() == 'true':
                        cand_local = os.path.join(effective_cwd, 'git')
                        if os.path.isfile(cand_local) and not is_trusted_executable_path(cand_local, workspace_paths, effective_cwd, 'git'):
                            return 'force_ask', f"go {args[0]} with workspace-controlled git executable requires confirmation: {cand_local}"
                        resolved_git = shutil.which('git')
                        if not resolved_git or not is_trusted_executable_path(resolved_git, workspace_paths, effective_cwd, 'git'):
                            return 'force_ask', f"go {args[0]} invokes git for VCS stamping, but git resolves to untrusted or workspace path: {resolved_git}"
                        if written_files:
                            for wf in written_files:
                                norm_wf = os.path.normpath(wf)
                                if (resolved_git and (norm_wf == os.path.normpath(resolved_git) or norm_wf.startswith(os.path.normpath(resolved_git) + os.sep))) or \
                                   (os.path.isfile(cand_local) and (norm_wf == os.path.normpath(cand_local) or norm_wf.startswith(norm_wf + os.sep))):
                                    return 'force_ask', f"go {args[0]} with git executable modified earlier in command line requires confirmation: {wf}"
                                if is_git_admin_path(wf, effective_cwd) or '.git/hooks' in wf.replace('\\', '/'):
                                    return 'force_ask', f"go {args[0]} with git repository configuration or hooks modified earlier in command line requires confirmation: {wf}"

                        if git_has_fsmonitor_configured(effective_cwd):
                            return 'force_ask', f"go {args[0]} invokes git with configured core.fsmonitor hook: {' '.join(cmd_tokens)}"

            return 'allow', f"Safe Go static tool: go {args[0]}"

    if base_cmd == 'make':
        return 'force_ask', f"make executes repository-controlled Makefile recipes: {' '.join(cmd_tokens)}"

    # 8. Safe Local File Operations (cp / mv)
    if base_cmd in {'cp', 'mv'}:
        # Decode ANSI-C quotes and escape sequences across all arguments
        args = [decode_shell_arg(a) for a in args]

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
            if '$' in a or '`' in a:
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

        # Check for backup options in cp and mv
        has_backup = False
        backup_suffix = os.environ.get('SIMPLE_BACKUP_SUFFIX') or '~'
        backup_type = os.environ.get('VERSION_CONTROL') or 'simple'

        i_arg = 0
        while i_arg < len(args):
            a = args[i_arg]
            if a == '-b':
                has_backup = True
            elif a.startswith('-') and not a.startswith('--') and 'b' in a:
                has_backup = True
            elif a == '--backup' or a.startswith('--backup='):
                has_backup = True
                if '=' in a:
                    backup_type = a.split('=', 1)[1]
            elif a.startswith('--') and any(opt.startswith(a.split('=', 1)[0]) for opt in ('--backup',)) and len(a.split('=', 1)[0]) >= 4:
                has_backup = True
                if '=' in a:
                    backup_type = a.split('=', 1)[1]

            if a.startswith('--'):
                opt = a.split('=', 1)[0]
                if '--suffix'.startswith(opt) and len(opt) >= 4:
                    if '=' in a:
                        backup_suffix = a.split('=', 1)[1]
                    elif i_arg + 1 < len(args):
                        backup_suffix = args[i_arg + 1]
                        i_arg += 1
            elif a.startswith('-') and not a.startswith('--') and 'S' in a:
                idx_s = a.index('S')
                rest = a[idx_s + 1:].lstrip('=')
                if rest:
                    backup_suffix = rest
                elif i_arg + 1 < len(args):
                    backup_suffix = args[i_arg + 1]
                    i_arg += 1
            i_arg += 1

        if has_backup and backup_type not in ('none', 'off', 'never'):
            backup_dests = []
            for ed in effective_dests:
                backup_dests.append(ed + backup_suffix)
                if backup_type in ('numbered', 't') or (backup_type in ('existing', 'nil')):
                    backup_dests.append(f"{ed}.~1~")
            effective_dests.extend(backup_dests)

        all_paths = list(sources) + [dest_dir] + effective_dests
        for p in all_paths:
            if is_sensitive_credential_path(p, cwd) or is_system_write_path(p, cwd):
                return 'deny', f"{base_cmd} targeting sensitive or system path is forbidden: {p}"
            if not is_path_in_workspaces(p, workspace_paths, cwd):
                return 'ask', f"{base_cmd} path outside workspace requires approval: {p}"
            if directory_contains_sensitive_files(p, cwd, workspace_paths):
                return 'deny', f"{base_cmd} targeting directory containing sensitive credential files is forbidden: {p}"

        if written_files:
            for p in all_paths:
                p_norm = os.path.normpath(expand_path(p, cwd))
                for wf in written_files:
                    wf_norm = os.path.normpath(wf)
                    if p_norm == wf_norm or p_norm.startswith(wf_norm + os.sep) or wf_norm.startswith(p_norm + os.sep):
                        return 'force_ask', f"{base_cmd} path was created or modified earlier in the command line: {p}"

        if base_cmd == 'cp':
            has_link_flag = any(
                a in ('-l', '--link', '-s', '--symbolic-link') or
                (a.startswith('-') and not a.startswith('--') and a != '-' and any(c in a for c in ('l', 's'))) or
                (a.startswith('--') and any(opt.startswith(a.split('=', 1)[0]) for opt in ('--link', '--symbolic-link')) and len(a.split('=', 1)[0]) >= 4)
                for a in args
            )
            if has_link_flag:
                return 'force_ask', f"cp with link creation option (-l/--link, -s/--symbolic-link) requires confirmation: {' '.join(cmd_tokens)}"

        for ed in [dest_dir] + effective_dests:
            if is_git_admin_path(ed, cwd):
                return 'ask', f"{base_cmd} destination targeting git administrative file requires confirmation: {ed}"
            if is_security_guard_path(ed, cwd):
                return 'force_ask', f"{base_cmd} destination targeting security configuration requires confirmation: {ed}"
        for src in sources:
            if is_git_admin_path(src, cwd):
                return 'ask', f"{base_cmd} accessing git administrative file requires confirmation: {src}"
            if is_security_guard_path(src, cwd):
                return 'force_ask', f"{base_cmd} accessing security configuration requires confirmation: {src}"

        for ed in [dest_dir] + effective_dests:
            ed_norm = expand_path(ed, cwd)
            curr = Path(ed_norm)
            while str(curr) != str(curr.parent):
                if curr.is_symlink():
                    try:
                        link_target = str(curr.resolve())
                        if not is_path_in_workspaces(link_target, workspace_paths, cwd) or is_sensitive_credential_path(link_target, cwd) or is_system_write_path(link_target, cwd):
                            return 'deny', f"{base_cmd} destination contains symlink pointing to sensitive or external target: {ed}"
                        return 'ask', f"{base_cmd} destination contains an existing symlink: {ed}"
                    except Exception:
                        return 'ask', f"{base_cmd} destination contains an unresolvable symlink: {ed}"
                curr = curr.parent

        return 'allow', f"Safe file {base_cmd} within workspace"

    if base_cmd in {'mkdir', 'touch'}:
        targets = []
        in_positional_only = False
        skip_next = False
        for i, a in enumerate(args):
            if skip_next:
                skip_next = False
                continue
            if in_positional_only:
                targets.append(a)
                continue
            if a == '--':
                in_positional_only = True
                continue
            if base_cmd == 'mkdir' and a in ('-m', '--mode') and i + 1 < len(args):
                skip_next = True
                continue
            if base_cmd == 'mkdir' and (a.startswith('-m') or a.startswith('--mode=')):
                continue
            if base_cmd == 'touch' and a in ('-d', '--date', '-r', '--reference', '-t') and i + 1 < len(args):
                skip_next = True
                continue
            if base_cmd == 'touch' and a.startswith(('-d', '--date=', '-r', '--reference=', '-t')):
                continue
            if not a.startswith('-'):
                targets.append(a)
        if any(is_git_admin_path(t, cwd) for t in targets):
            return 'ask', f"{base_cmd} targeting git administrative path requires confirmation: {' '.join(cmd_tokens)}"
        if any(is_security_guard_path(t, cwd) for t in targets):
            return 'force_ask', f"{base_cmd} targeting security configuration requires confirmation: {' '.join(cmd_tokens)}"
        if written_files:
            for t in targets:
                t_norm = os.path.normpath(expand_path(t, cwd))
                for wf in written_files:
                    wf_norm = os.path.normpath(wf)
                    if t_norm == wf_norm or t_norm.startswith(wf_norm + os.sep) or wf_norm.startswith(t_norm + os.sep):
                        return 'force_ask', f"{base_cmd} target path was created or modified earlier in the command line: {t}"
        if targets and all(is_path_in_workspaces(t, workspace_paths, cwd) and not is_system_write_path(t, cwd) for t in targets):
            return 'allow', f"Safe directory/file creation within workspace: {base_cmd}"

    # Shell interpreter wrappers (bash, sh, zsh, etc.)
    if base_cmd in {'sh', 'bash', 'zsh', 'dash', 'ksh', 'csh', 'tcsh'}:
        cmd_arg = None
        for i, a in enumerate(args):
            if a in ('-c', '-lc') and i + 1 < len(args):
                cmd_arg = args[i + 1]
                break
            elif a.startswith('-c') and len(a) > 2 and not a.startswith('--'):
                cmd_arg = a[2:].lstrip('=')
                break
        if cmd_arg:
            inner_verdict, inner_reason = classify_command_line(cmd_arg, workspace_paths, cwd, depth + 1)
            if inner_verdict == 'deny':
                return 'deny', f"Shell command executes forbidden command: {inner_reason}"
            return 'force_ask', f"Shell wrapper execution requires confirmation: {' '.join(cmd_tokens)}"
        return 'force_ask', f"Interactive shell execution requires confirmation: {' '.join(cmd_tokens)}"

    return 'force_ask', f"Command requires confirmation: {' '.join(cmd_tokens)}"


def extract_parameter_expansions(cmd_str):
    """
    Extract all parameter expansions (${...}) from a shell command string,
    respecting quote contexts and properly balancing nested braces and quotes.
    Returns a list of inner parameter strings (without the enclosing ${ and }).
    """
    if not cmd_str or not isinstance(cmd_str, str):
        return []

    cmd_str = normalize_shell_continuations(cmd_str)
    expansions = []
    i = 0
    n = len(cmd_str)
    in_single_quote = False
    in_double_quote = False
    escape = False

    while i < n:
        c = cmd_str[i]

        if escape:
            escape = False
            i += 1
            continue

        if c == '\\' and not in_single_quote:
            escape = True
            i += 1
            continue

        if c == "'" and not in_double_quote:
            in_single_quote = not in_single_quote
            i += 1
            continue

        if c == '"' and not in_single_quote:
            in_double_quote = not in_double_quote
            i += 1
            continue

        if not in_single_quote:
            if c == '$' and i + 1 < n and cmd_str[i + 1] == '{':
                j = i + 2
                depth = 1
                inner_chars = []
                inner_single_quote = False
                inner_double_quote = False
                inner_escape = False
                found_closing = False

                while j < n:
                    cj = cmd_str[j]
                    if inner_escape:
                        inner_escape = False
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if cj == '\\' and not inner_single_quote:
                        inner_escape = True
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if cj == "'" and not inner_double_quote:
                        inner_single_quote = not inner_single_quote
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if cj == '"' and not inner_single_quote:
                        inner_double_quote = not inner_double_quote
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if not inner_single_quote and not inner_double_quote:
                        if cj == '{':
                            depth += 1
                        elif cj == '}':
                            depth -= 1
                            if depth == 0:
                                found_closing = True
                                break
                    inner_chars.append(cj)
                    j += 1

                exp_content = ''.join(inner_chars)
                expansions.append(exp_content)
                nested = extract_parameter_expansions(exp_content)
                if nested:
                    expansions.extend(nested)
                i = j + 1 if found_closing else n
                continue

        i += 1

    return expansions


def extract_command_substitutions(cmd_str):
    """
    Extract all command substitutions ($(...), `...`, <(...), >(...)) from a shell command string,
    respecting quote contexts and properly balancing nested parentheses.
    Returns a list of inner command strings.
    """
    if not cmd_str or not isinstance(cmd_str, str):
        return []

    cmd_str = normalize_shell_continuations(cmd_str)
    substitutions = []
    i = 0
    n = len(cmd_str)
    in_single_quote = False
    in_double_quote = False
    escape = False

    while i < n:
        c = cmd_str[i]

        if escape:
            escape = False
            i += 1
            continue

        if c == '\\' and not in_single_quote:
            escape = True
            i += 1
            continue

        if c == "'" and not in_double_quote:
            in_single_quote = not in_single_quote
            i += 1
            continue

        if c == '"' and not in_single_quote:
            in_double_quote = not in_double_quote
            i += 1
            continue

        if not in_single_quote:
            if c == '`':
                j = i + 1
                inner_chars = []
                inner_escape = False
                found_closing = False
                while j < n:
                    cj = cmd_str[j]
                    if inner_escape:
                        inner_chars.append(cj)
                        inner_escape = False
                        j += 1
                        continue
                    if cj == '\\':
                        inner_escape = True
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if cj == '`':
                        found_closing = True
                        break
                    inner_chars.append(cj)
                    j += 1
                sub_content = ''.join(inner_chars)
                substitutions.append(sub_content)
                i = j + 1 if found_closing else n
                continue

            is_dollar_sub = (c == '$' and i + 1 < n and cmd_str[i + 1] == '(')
            is_dollar_bracket = (c == '$' and i + 1 < n and cmd_str[i + 1] == '[')
            is_proc_sub = (c in ('<', '>') and i + 1 < n and cmd_str[i + 1] == '(' and not in_double_quote)

            if is_dollar_bracket:
                j = i + 2
                depth = 1
                inner_chars = []
                sub_single_quote = False
                sub_double_quote = False
                sub_escape = False
                found_closing = False

                while j < n:
                    cj = cmd_str[j]
                    if sub_escape:
                        sub_escape = False
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if cj == '\\' and not sub_single_quote:
                        sub_escape = True
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if cj == "'" and not sub_double_quote:
                        sub_single_quote = not sub_single_quote
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if cj == '"' and not sub_single_quote:
                        sub_double_quote = not sub_double_quote
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if not sub_single_quote and not sub_double_quote:
                        if cj == '[':
                            depth += 1
                        elif cj == ']':
                            depth -= 1
                            if depth == 0:
                                found_closing = True
                                break

                    inner_chars.append(cj)
                    j += 1

                sub_content = ''.join(inner_chars)
                substitutions.append(sub_content)
                i = j + 1 if found_closing else n
                continue

            if is_dollar_sub or is_proc_sub:
                j = i + 2
                depth = 1
                inner_chars = []
                sub_single_quote = False
                sub_double_quote = False
                sub_escape = False
                found_closing = False

                while j < n:
                    cj = cmd_str[j]
                    if sub_escape:
                        sub_escape = False
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if cj == '\\' and not sub_single_quote:
                        sub_escape = True
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if cj == "'" and not sub_double_quote:
                        sub_single_quote = not sub_single_quote
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if cj == '"' and not sub_single_quote:
                        sub_double_quote = not sub_double_quote
                        inner_chars.append(cj)
                        j += 1
                        continue
                    if not sub_single_quote and not sub_double_quote:
                        if cj == '(':
                            depth += 1
                        elif cj == ')':
                            depth -= 1
                            if depth == 0:
                                found_closing = True
                                break
                    elif sub_double_quote:
                        if cj == '$' and j + 1 < n and cmd_str[j + 1] == '(':
                            depth += 1
                            inner_chars.append(cj)
                            inner_chars.append('(')
                            j += 2
                            continue
                        elif cj == ')':
                            depth -= 1
                            if depth == 0:
                                found_closing = True
                                break

                    inner_chars.append(cj)
                    j += 1

                sub_content = ''.join(inner_chars)
                substitutions.append(sub_content)
                i = j + 1 if found_closing else n
                continue

        i += 1

    return substitutions


def classify_command_line(cmd_str, workspace_paths, cwd, depth=0):
    """Classify an entire shell command line string across lines, chains, and pipelines."""
    if depth > 5:
        return 'force_ask', 'Nested command recursion limit exceeded'

    if not isinstance(cmd_str, str) or not cmd_str.strip():
        return 'ask', 'Empty command line or invalid type'

    cmd_str = normalize_shell_continuations(cmd_str)

    # Check for parameter expansions ${...} that modify shell state or reference sensitive/dangerous targets
    param_expansions = extract_parameter_expansions(cmd_str)
    if param_expansions:
        for p_inner in param_expansions:
            if not p_inner or not p_inner.strip():
                continue
            # Any reference or modification of BASH_CMDS is strictly forbidden
            if re.search(r'\bBASH_CMDS\b', p_inner):
                return 'deny', f"Referencing or modifying BASH_CMDS via parameter expansion is forbidden: ${{{p_inner}}}"

            # Prompt expansion operator (@P) expands prompt escapes and executes embedded command substitutions
            if re.search(r'@\s*["\']?[Pp]["\']?', p_inner):
                return 'force_ask', f"Parameter expansion with prompt expansion (@P) may execute arbitrary commands: ${{{p_inner}}}"

            # Check for credential variables referenced inside parameter expansion
            if is_credential_env_var('${' + p_inner + '}'):
                return 'deny', f"Access to credential environment variable via parameter expansion is forbidden: ${{{p_inner}}}"
            m_var = re.match(r'^[!#]?(?P<name>[A-Za-z_][A-Za-z0-9_]*)', p_inner)
            if m_var:
                ref_var = m_var.group('name')
                if is_credential_var_name(ref_var):
                    return 'deny', f"Access to credential environment variable via parameter expansion is forbidden: ${{{p_inner}}}"

            # Check for array subscripts: in Bash, any non-literal subscript evaluates arithmetic
            # and recursively expands variable values, which can execute embedded commands
            for m_sub in re.finditer(r'\[([^\]]*)\]', p_inner):
                sub_expr = m_sub.group(1).strip()
                if sub_expr not in ('@', '*') and not re.match(r'^-?\d+$', sub_expr):
                    return 'force_ask', f"Parameter expansion with dynamic or variable array subscript requires confirmation: ${{{p_inner}}}"

            # Check for substring slicing (${var:offset} or ${var:offset:length}):
            # in Bash, offset and length are evaluated as arithmetic expressions
            p_body = re.sub(r'^[!#]?[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?', '', p_inner)
            if p_body.startswith(':') and not p_body.startswith((':=' , ':-', ':+', ':?')):
                parts = p_body[1:].split(':')
                for part in parts:
                    p_clean = part.strip()
                    if not re.match(r'^-?\d+$', p_clean) and not re.match(r'^\(-?\d+\)$', p_clean):
                        return 'force_ask', f"Parameter expansion with dynamic slice offset or length requires confirmation: ${{{p_inner}}}"

            # Check for parameter assignments (${VAR:=val}, ${VAR=val}, ${ARR[idx]:=val}, ${ARR[idx]=val})
            m_assign = re.match(r'^[!#]?(?P<name>[A-Za-z_][A-Za-z0-9_]*)(?:\[(?P<subscript>[^\]]*)\])?(?P<op>:=|=)', p_inner)
            if m_assign:
                assigned_var = m_assign.group('name')
                if is_dangerous_env_var(assigned_var):
                    return 'deny', f"Setting execution-altering environment variable via parameter expansion is forbidden: {assigned_var}"
                if is_credential_var_name(assigned_var):
                    return 'deny', f"Setting credential variable via parameter expansion is forbidden: {assigned_var}"
                return 'force_ask', f"Parameter expansion with variable assignment requires confirmation: ${{{p_inner}}}"

            # Check for arithmetic or inner assignments within subscripts or expressions
            for m in re.finditer(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:[-+*/%&|^]|<<|>>)?=(?!=)', p_inner):
                v_name = m.group(1)
                if is_dangerous_env_var(v_name):
                    return 'deny', f"Setting execution-altering environment variable via parameter expansion is forbidden: {v_name}"
                if is_credential_var_name(v_name):
                    return 'deny', f"Setting credential variable via parameter expansion is forbidden: {v_name}"
                return 'force_ask', f"Parameter expansion with variable assignment requires confirmation: ${{{p_inner}}}"

    # Check for command substitutions $(...) or `...` or process substitutions <(...) >(...)
    substitutions = extract_command_substitutions(cmd_str)
    if substitutions:
        for inner in substitutions:
            if inner and inner.strip():
                for m in re.finditer(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:[-+*/%&|^]|<<|>>)?=(?!=)', inner):
                    var_name = m.group(1)
                    if is_dangerous_env_var(var_name):
                        return 'deny', f"Setting execution-altering environment variable via substitution or arithmetic expansion is forbidden: {var_name}"
                    if is_credential_var_name(var_name):
                        return 'deny', f"Setting credential variable via substitution or arithmetic expansion is forbidden: {var_name}"
                inner_verdict, inner_reason = classify_command_line(inner.strip(), workspace_paths, cwd, depth + 1)
                if inner_verdict == 'deny':
                    return 'deny', f"Command substitution contains forbidden operation: {inner_reason}"
        return 'force_ask', 'Command contains command or process substitution'

    subcmd_strings, pipeline_links_all = split_unquoted_shell_commands(cmd_str)
    if subcmd_strings is None:
        return 'ask', 'Unable to safely parse command line (syntax error, unclosed quote, or dangling escape)'

    if not subcmd_strings:
        return 'allow', 'Empty command'

    subcommands_all = []
    subcmd_raw_all = []
    for sub_str in subcmd_strings:
        sub_str_expanded = expand_unquoted_tildes(sub_str, cwd)
        tokens = tokenize_subcommand(sub_str_expanded)
        if tokens is None:
            return 'ask', f"Unable to safely parse command tokens: {sub_str}"
        if tokens:
            subcommands_all.append(tokens)
            subcmd_raw_all.append(sub_str_expanded)

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
    written_files = set()
    for idx_sub, sub in enumerate(subcommands_all):
        raw_s = subcmd_raw_all[idx_sub] if idx_sub < len(subcmd_raw_all) else None
        verdict, reason = classify_subcommand(sub, workspace_paths, cwd, depth=depth, raw_subcmd=raw_s, written_files=written_files)
        verdicts.append((verdict, reason))

        # Record files written or redirected to by this subcommand
        if raw_s:
            _, ext_redirs = extract_unquoted_redirections(raw_s)
            if ext_redirs:
                for r_tok, r_target in ext_redirs:
                    if is_output_redirection(r_tok, r_target):
                        t_clean = r_target
                        if t_clean and t_clean != '/dev/null':
                            written_files.add(expand_path(t_clean, cwd))
        for i_tok, tok in enumerate(sub):
            if i_tok + 1 < len(sub) and is_output_redirection(tok, sub[i_tok + 1]):
                t_raw = decode_shell_target(unquote_token(sub[i_tok + 1]))
                if t_raw and t_raw != '/dev/null':
                    written_files.add(expand_path(t_raw, cwd))
        # Unwrap inline assignments and wrapper commands (env, command, builtin)
        idx_cmd = 0
        while idx_cmd < len(sub) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', sub[idx_cmd]):
            idx_cmd += 1
        effective_cmd_tokens = sub[idx_cmd:]
        while effective_cmd_tokens:
            base_cand = os.path.basename(unquote_token(effective_cmd_tokens[0]))
            if base_cand in ('command', 'builtin'):
                effective_cmd_tokens = effective_cmd_tokens[1:]
                continue
            if base_cand == 'env':
                idx_env = 1
                while idx_env < len(effective_cmd_tokens):
                    tok_env = effective_cmd_tokens[idx_env]
                    if re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', tok_env):
                        idx_env += 1
                        continue
                    if tok_env in ('-i', '--ignore-environment', '-0', '--null'):
                        idx_env += 1
                        continue
                    if tok_env in ('-u', '--unset', '-C', '--chdir') and idx_env + 1 < len(effective_cmd_tokens):
                        idx_env += 2
                        continue
                    if tok_env.startswith(('-u', '--unset=', '-C', '--chdir=')):
                        idx_env += 1
                        continue
                    break
                effective_cmd_tokens = effective_cmd_tokens[idx_env:]
                continue
            break

        sub_base = os.path.basename(unquote_token(effective_cmd_tokens[0])) if effective_cmd_tokens else ''
        sub_args = effective_cmd_tokens[1:] if effective_cmd_tokens else []

        if sub_base == 'tee':
            for a in sub_args:
                a_unq = unquote_token(a)
                if not a_unq.startswith('-') and a_unq != '/dev/null':
                    written_files.add(expand_path(a_unq, cwd))
        elif sub_base in ('touch', 'mkdir', 'cp', 'mv', 'ln', 'install'):
            pos = []
            target_dir = None
            skip_next = False
            in_pos_only = False
            for i, a in enumerate(sub_args):
                if skip_next:
                    skip_next = False
                    continue
                a_unq = unquote_token(a)
                if in_pos_only:
                    if a_unq != '/dev/null':
                        pos.append(a_unq)
                    continue
                if a_unq == '--':
                    in_pos_only = True
                    continue
                if a_unq in ('-t', '--target-directory'):
                    if i + 1 < len(sub_args):
                        target_dir = unquote_token(sub_args[i + 1])
                        skip_next = True
                    continue
                if a_unq.startswith('--target-directory='):
                    target_dir = a_unq.split('=', 1)[1]
                    continue
                if sub_base == 'touch' and a_unq in ('-d', '--date', '-r', '--reference', '-t') and i + 1 < len(sub_args):
                    skip_next = True
                    continue
                if sub_base == 'touch' and a_unq.startswith(('-d', '--date=', '-r', '--reference=', '-t')):
                    continue
                if sub_base == 'mkdir' and a_unq in ('-m', '--mode') and i + 1 < len(sub_args):
                    skip_next = True
                    continue
                if sub_base == 'mkdir' and (a_unq.startswith('-m') or a_unq.startswith('--mode=')):
                    continue
                if not a_unq.startswith('-') and a_unq != '/dev/null':
                    pos.append(a_unq)
            if sub_base in ('touch', 'mkdir', 'mv'):
                for p in pos:
                    written_files.add(expand_path(p, cwd))
                if target_dir:
                    written_files.add(expand_path(target_dir, cwd))
            elif target_dir:
                written_files.add(expand_path(target_dir, cwd))
            elif pos:
                written_files.add(expand_path(pos[-1], cwd))
        elif sub_base == 'sort':
            i = 0
            while i < len(sub_args):
                a = unquote_token(sub_args[i])
                if a == '--':
                    break
                if a in ('-o', '--output') and i + 1 < len(sub_args):
                    written_files.add(expand_path(unquote_token(sub_args[i + 1]), cwd))
                    i += 2
                    continue
                if a.startswith('--'):
                    opt = a.split('=', 1)[0]
                    if '--output'.startswith(opt) and len(opt) >= 3:
                        if '=' in a:
                            written_files.add(expand_path(a.split('=', 1)[1], cwd))
                        elif i + 1 < len(sub_args):
                            written_files.add(expand_path(unquote_token(sub_args[i + 1]), cwd))
                            i += 1
                        i += 1
                        continue
                elif a.startswith('-o') and len(a) > 2 and not a.startswith('--'):
                    val = a[2:].lstrip('=')
                    if val:
                        written_files.add(expand_path(val, cwd))
                    elif i + 1 < len(sub_args):
                        written_files.add(expand_path(unquote_token(sub_args[i + 1]), cwd))
                        i += 1
                    i += 1
                    continue
                elif a.startswith('-') and 'o' in a and not a.startswith('--'):
                    o_idx = a.index('o')
                    val = a[o_idx + 1:].lstrip('=')
                    if val:
                        written_files.add(expand_path(val, cwd))
                    elif i + 1 < len(sub_args):
                        written_files.add(expand_path(unquote_token(sub_args[i + 1]), cwd))
                        i += 1
                    i += 1
                    continue
                i += 1
        elif sub_base == 'git':
            sub_args = [unquote_token(a) for a in sub_args]
            git_sub = None
            git_sub_idx = -1
            skip_next = False
            effective_git_cwd = cwd if isinstance(cwd, str) and cwd.strip() else os.getcwd()
            for idx, a in enumerate(sub_args):
                if skip_next:
                    skip_next = False
                    continue
                if a == '-C':
                    if idx + 1 < len(sub_args):
                        effective_git_cwd = expand_path(sub_args[idx + 1], effective_git_cwd)
                        skip_next = True
                    continue
                if a.startswith('-C') and len(a) > 2 and not a.startswith('--'):
                    effective_git_cwd = expand_path(a[2:], effective_git_cwd)
                    continue
                if a in ('--git-dir', '--work-tree', '--namespace', '-c', '--config-env'):
                    skip_next = True
                    continue
                if a.startswith(('--git-dir=', '--work-tree=', '--namespace=', '-c', '--config-env=')):
                    continue
                if not a.startswith('-'):
                    git_sub = a
                    git_sub_idx = idx
                    break
            if git_sub in ('switch', 'checkout', 'reset', 'restore', 'pull', 'merge', 'rebase', 'clean', 'apply', 'cherry-pick', 'revert', 'commit'):
                res_top = git_run_probe(['rev-parse', '--show-toplevel'], cwd=effective_git_cwd)
                if res_top and res_top.returncode == 0 and res_top.stdout.strip():
                    written_files.add(os.path.normpath(res_top.stdout.strip()))
                else:
                    written_files.add(os.path.normpath(effective_git_cwd))
            elif git_sub == 'stash':
                if any(tok in ('pop', 'apply', 'drop', 'clear', 'push', 'save') for tok in sub_args):
                    res_top = git_run_probe(['rev-parse', '--show-toplevel'], cwd=effective_git_cwd)
                    if res_top and res_top.returncode == 0 and res_top.stdout.strip():
                        written_files.add(os.path.normpath(res_top.stdout.strip()))
                    else:
                        written_files.add(os.path.normpath(effective_git_cwd))
            elif git_sub == 'worktree':
                if git_sub_idx != -1 and 'add' in sub_args[git_sub_idx:]:
                    add_idx = sub_args.index('add', git_sub_idx)
                    wt_args = sub_args[add_idx + 1:]
                    skip_next = False
                    for wa in wt_args:
                        if skip_next:
                            skip_next = False
                            continue
                        if wa in ('-b', '-B', '--reason'):
                            skip_next = True
                            continue
                        if wa.startswith(('-b', '-B', '--reason=')):
                            continue
                        if not wa.startswith('-'):
                            written_files.add(expand_path(wa, effective_git_cwd))
                            break

            # Record git output destinations
            skip_sub = False
            for idx_a, a_sub in enumerate(sub_args):
                if skip_sub:
                    skip_sub = False
                    continue
                if a_sub.startswith('--o') and '=' in a_sub:
                    opt, val = a_sub.split('=', 1)
                    if ('--output'.startswith(opt) and len(opt) >= 4) or ('--output-directory'.startswith(opt) and len(opt) >= 4):
                        written_files.add(expand_path(decode_shell_target(val), effective_git_cwd))
                elif a_sub.startswith('--o') and (('--output'.startswith(a_sub) and len(a_sub) >= 4) or ('--output-directory'.startswith(a_sub) and len(a_sub) >= 4)):
                    if idx_a + 1 < len(sub_args):
                        written_files.add(expand_path(decode_shell_target(sub_args[idx_a + 1]), effective_git_cwd))
                        skip_sub = True
                elif a_sub in ('--output', '-o', '--output-directory') and idx_a + 1 < len(sub_args):
                    written_files.add(expand_path(decode_shell_target(sub_args[idx_a + 1]), effective_git_cwd))
                    skip_sub = True
                elif a_sub.startswith('-o') and len(a_sub) > 2 and not a_sub.startswith('--'):
                    written_files.add(expand_path(decode_shell_target(a_sub[2:].lstrip('=')), effective_git_cwd))

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

    if is_security_guard_path(target_file, cwd):
        return 'force_ask', f"Modifying permission classifier, hooks, or security configuration requires confirmation: {target_file}"

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

    include_vcs = False
    # Check search filter options (Includes, Pattern) for sensitive patterns
    includes = args.get('Includes')
    if isinstance(includes, list):
        for inc in includes:
            if isinstance(inc, str):
                if matches_sensitive_pattern(inc) or any(c in inc for c in ('.env', 'id_', '.key', '.pem')):
                    return 'deny', f"Search targeting sensitive pattern is forbidden: {inc}"
                if glob_matches_vcs(inc):
                    include_vcs = True

    pattern = args.get('Pattern')
    if isinstance(pattern, str):
        if matches_sensitive_pattern(pattern) or any(c in pattern for c in ('.env', 'id_', '.key', '.pem')):
            return 'deny', f"Search targeting sensitive pattern is forbidden: {pattern}"
        if glob_matches_vcs(pattern):
            include_vcs = True

    # If target is a directory, inspect if it contains descendant sensitive files or symlinks
    if os.path.isdir(norm):
        desc_verdict, desc_reason = check_directory_descendants(norm, cwd, include_vcs=include_vcs)
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
        elif tool_name == 'list_dir':
            target = args.get('DirectoryPath') or args.get('path') or ''
            decision, reason = classify_directory_search(target, args, workspace_paths, cwd)
        elif tool_name == 'send_input':
            decision, reason = 'force_ask', 'Sending input to a running process can execute arbitrary commands and requires confirmation'
        elif tool_name == 'manage_task':
            action = (args.get('Action') or args.get('action') or '').lower()
            if action == 'send_input':
                decision, reason = 'force_ask', 'Sending input to a background task can execute arbitrary commands and requires confirmation'
            elif action in ('list', 'status'):
                decision, reason = 'allow', f"Safe task management query: {action}"
            elif action == 'kill':
                decision, reason = 'allow', 'Terminating background task is safe'
            else:
                decision, reason = 'ask', f"manage_task with action '{action}' requires confirmation"
        elif tool_name == 'schedule':
            decision, reason = 'ask', 'Creating a scheduled timer or recurring job requires confirmation'
        else:
            decision, reason = 'ask', f"Tool {tool_name} requires confirmation"

        print(json.dumps({'decision': decision, 'reason': reason}))
    except Exception as e:
        # Failsafe: never crash unhandled, always emit a valid JSON decision
        print(json.dumps({'decision': 'ask', 'reason': f"Permission classifier internal error: {e}"}))


if __name__ == '__main__':
    main()
