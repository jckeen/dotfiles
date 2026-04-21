# Security Findings — dotfiles — 2026-04-19

> Static analysis only. No code was executed. All secret values are redacted.
> **This report is for triage purposes only — no fixes have been applied.**

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 5 |
| LOW | 1 |
| INFO | 0 |
| **Total** | **7** |

## Findings

### [HIGH] sync-memory function uses git add -A, risking accidental secret commits

- **File:** `.bash_aliases:49`
- **CWE:** CWE-530 (Exposure of Backup File to an Unauthorized Control Sphere)
- **Description:** The `sync-memory` shell function runs `git -C "$mem_repo" add -A`, staging all untracked and modified files — including any `.env`, `*.key`, `credentials.json`, or other sensitive files that might be created in the `claude-memory` directory. There is no filtering mechanism.
- **Remediation:** Replace `git add -A` with explicit staging of only the intended directories (e.g., `git -C "$mem_repo" add dev/memory pai-user pai-config`). Add `.gitignore` entries for `*.key`, `*.pem`, `.env*`, `credentials*.json`.

---

### [MEDIUM] Windows cmd.exe output used unsanitised in heredoc

- **File:** `setup.sh:361`
- **CWE:** CWE-78 (Improper Neutralization of Special Elements Used in an OS Command)
- **Description:** `WIN_USER=$(/mnt/c/Windows/System32/cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')` captures output from the Windows environment and uses it directly in a heredoc without format validation. A compromised or attacker-controlled `%USERNAME%` could inject shell metacharacters.
- **Remediation:** Sanitise immediately after capture: `WIN_USER=$(echo "$WIN_USER" | sed 's/[^a-zA-Z0-9._-]//g')`. Document the assumption that the Windows mount is trusted.

---

### [MEDIUM] ~/.claude/scripts/ prepended to PATH without permission verification

- **File:** `.bash_aliases:2`
- **CWE:** CWE-426 (Untrusted Search Path)
- **Description:** `export PATH="$HOME/.claude/scripts:$PATH"` runs at every shell start without verifying that `~/.claude/scripts/` is owned by the user and not group/world-writable. A world-writable directory allows privilege escalation via PATH hijacking.
- **Remediation:** Add a startup guard: `[ "$(stat -c '%a %u' ~/.claude/scripts 2>/dev/null)" = "700 $(id -u)" ] || echo "WARNING: unsafe permissions on ~/.claude/scripts"`.

---

### [MEDIUM] git safe.directory entries set without path validation

- **File:** `setup.sh:388–389`
- **CWE:** CWE-426 (Untrusted Search Path)
- **Description:** `git config --global --add safe.directory "$DOTFILES_DIR"` and `"$DEV_DIR/claude-memory"` are added without verifying the paths exist or are under `$HOME`. A symlink attack could add an attacker-controlled directory to the global git safe list.
- **Remediation:** Validate paths with `realpath` before adding: confirm each resolves under `$HOME` and contains a `.git` directory.

---

### [MEDIUM] NTFY_TOPIC value not validated before use in curl URL

- **File:** `hooks/ntfy-awaiting-input.sh:49`
- **CWE:** CWE-95 (Improper Neutralization of Directives in Dynamically Evaluated Code)
- **Description:** `curl ... "https://${NTFY_SERVER}/${NTFY_TOPIC}"` constructs the URL directly from the environment variable without validating that `NTFY_TOPIC` contains only safe URL-path characters. A topic value with special characters could alter the target URL.
- **Remediation:** Validate topic format before use: `[[ "$NTFY_TOPIC" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 1`.

---

### [MEDIUM] Notification hook may transmit sensitive data from Claude responses

- **File:** `hooks/ntfy-awaiting-input.sh:27–41`
- **CWE:** CWE-532 (Insertion of Sensitive Information into Log File)
- **Description:** The hook reads arbitrary JSON from stdin and forwards extracted `header`/`question` text to external services (ntfy.sh, Discord, Twilio). If Claude's response contains sensitive information (credentials, PII), it is transmitted to third-party endpoints.
- **Remediation:** Scrub common secret patterns from notification text before sending. Document that notifications should not be enabled for sensitive workloads.

---

### [LOW] Hardcoded Windows Chrome path with no existence check

- **File:** `.bash_aliases:303`
- **CWE:** CWE-426 (Untrusted Search Path)
- **Description:** `export BROWSER="/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"` assumes a standard Chrome installation path with no existence check. If the path is invalid or symlinked to a different binary, `BROWSER` points to an unexpected executable.
- **Remediation:** Add an existence check: `[ -f "$BROWSER" ] || unset BROWSER`.
