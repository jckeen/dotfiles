# Security Findings — 2026-04-26

**Repository:** jckeen/dotfiles  
**Scan Date:** 2026-04-26  
**Method:** Static analysis only — no code execution  
**Previous report:** SECURITY_FINDINGS_20260419.md — all findings remain unresolved.

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 5 |
| LOW | 1 |
| **Total** | **7** |

---

## Findings

### [HIGH] `sync-memory` function uses `git add -A`, risking accidental secret commits
**File:** `.bash_aliases:49`  
**CWE:** CWE-530 (Exposure of Backup File to Unauthorized Control Sphere)

`sync-memory` stages all untracked and modified files with `git -C "$mem_repo" add -A` without filtering. Any `.env`, `*.key`, or `credentials.json` file created in the `claude-memory` directory will be staged and committed.

**Remediation:** Replace `git add -A` with explicit staging of intended directories only: `git -C "$mem_repo" add dev/memory pai-user pai-config`. Add `.gitignore` entries for `*.key`, `*.pem`, `.env*`, `credentials*.json`.

---

### [MEDIUM] Windows `cmd.exe` output used unsanitised in heredoc
**File:** `setup.sh:458`  
**CWE:** CWE-78 (Improper Neutralization of Special Elements in an OS Command)

`WIN_USER` is captured from `%USERNAME%` via `cmd.exe` and interpolated directly into a git config heredoc at line 464. A compromised or attacker-controlled `%USERNAME%` could inject shell metacharacters.

**Remediation:** Sanitise immediately after capture: `WIN_USER=$(echo "$WIN_USER" | sed 's/[^a-zA-Z0-9._-]//g')`

---

### [MEDIUM] `~/.claude/scripts/` prepended to PATH without permission verification
**File:** `.bash_aliases:2`  
**CWE:** CWE-426 (Untrusted Search Path)

Every shell start adds `$HOME/.claude/scripts` to `PATH` without verifying directory ownership or permissions. A world-writable directory enables PATH hijacking for privilege escalation.

**Remediation:**
```bash
[ "$(stat -c '%a %u' ~/.claude/scripts 2>/dev/null)" = "700 $(id -u)" ] ||
  echo "WARNING: unsafe permissions on ~/.claude/scripts"
```

---

### [MEDIUM] `git safe.directory` entries set without path validation
**File:** `setup.sh:485`  
**CWE:** CWE-426

Directories are added to the global git safe list without verifying they resolve under `$HOME`, contain a `.git` directory, or are not symlinks pointing elsewhere. A symlink attack could add an attacker-controlled directory to the global safe list.

**Remediation:** Confirm each path resolves under `$HOME` via `realpath` and contains a `.git` directory before calling `git config --global --add safe.directory`.

---

### [MEDIUM] `NTFY_TOPIC` not validated before use in curl URL
**File:** `claude/hooks/ntfy-awaiting-input.sh:49`  
**CWE:** CWE-95

`NTFY_TOPIC` is interpolated directly into an ntfy.sh URL without format validation. A topic containing `../`, `?`, or `#` characters could redirect notifications to unintended services.

**Remediation:** `[[ "$NTFY_TOPIC" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 1`

---

### [MEDIUM] Notification hook may transmit sensitive Claude response content to third parties
**File:** `claude/hooks/ntfy-awaiting-input.sh:27`  
**CWE:** CWE-532 (Sensitive Information into Log File)

The hook extracts `header` and `question` fields from Claude's JSON output and forwards them to external services (ntfy.sh, Discord, Twilio) without scrubbing. If Claude's response contains credentials, PII, or internal tokens, they are transmitted to third-party endpoints.

**Remediation:** Add a regex filter to scrub common secret patterns (API keys, emails, phone numbers) before forwarding. Document that notification hooks should not be enabled for sensitive workloads.

---

### [LOW] Hardcoded Windows Chrome path with no existence check
**File:** `.bash_aliases:303`  
**CWE:** CWE-426

`BROWSER` is set to a hardcoded `Program Files` path with no check that the binary exists. If the path is invalid or symlinked to a different binary, `$BROWSER` points to an unexpected executable.

**Remediation:** `[ -f "$BROWSER" ] || unset BROWSER`
