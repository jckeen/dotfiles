# Security Findings — dotfiles — 2026-05-31

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 3 |
| LOW | 3 |
| INFO | 2 |
| **Total** | **9** |

> Static analysis only. No code executed. Scan date: 2026-05-31.

---

## Findings

### [HIGH-1] Unverified `curl | bash` Supply-Chain Escape Hatch in Setup Script

**Severity:** HIGH  
**File:** `setup.sh:519–527`  
**CWE:** CWE-494 (Download of Code Without Integrity Check), CWE-829 (Inclusion from Untrusted Control Sphere)

The setup script has a `BUN_UNPINNED=1` environment variable bypass that executes an unverified bun installer from the internet:

```bash
if [ "${BUN_UNPINNED:-0}" = "1" ]; then
  run curl -fsSL https://bun.sh/install | bash
```

Any environment where `BUN_UNPINNED=1` is set (inherited from CI, compromised shell configs) bypasses SHA-256 verification and executes unverified code with the installing user’s privileges.

**Remediation:** Remove the environment-variable bypass, or require BOTH an env var AND an explicit interactive CLI flag (`--force-unpinned`) to activate. The current escape hatch can be silently triggered by upstream environment poisoning.

---

### [MEDIUM-1] User Input Interpolation Without Escaping in Git Config Heredoc

**Severity:** MEDIUM  
**File:** `setup.sh:749–794`  
**CWE:** CWE-116 (Improper Encoding of Output)

`GIT_NAME` and `GIT_EMAIL` variables are interpolated directly into a heredoc without quoting. Special characters (newlines, square brackets) in the user’s name or email will corrupt the git config file, causing setup failures or unexpected git behavior.

**Remediation:** Use `git config --file` instead of heredoc interpolation:
```bash
git config --file "$DOTFILES_DIR/.gitconfig.local" user.name "$GIT_NAME"
git config --file "$DOTFILES_DIR/.gitconfig.local" user.email "$GIT_EMAIL"
```

---

### [MEDIUM-2] Hardcoded `localhost:31337` Unauthenticated Endpoint in PromptProcessing Hook

**Severity:** MEDIUM  
**File:** `claude/hooks/PromptProcessing.hook.ts:1010–1021`  
**CWE:** CWE-441 (Unintended Proxy/Intermediary), CWE-346 (Origin Validation Error)

The hook POSTs session names and voice configuration to `http://localhost:31337/notify` without authentication. On shared hosts or WSL2 with port forwarding, any process binding port 31337 receives Claude session data without authorization.

**Remediation:** Add `Authorization: Bearer <token>` header with a cryptographically random token validated server-side. Consider Unix domain socket (`/tmp/claude-voice-server.sock`) instead of TCP.

---

### [MEDIUM-3] `HygieneStatus.hook.sh` Executes Hardcoded Path Without Symlink Validation

**Severity:** MEDIUM  
**File:** `claude/hooks/HygieneStatus.hook.sh:6`  
**CWE:** CWE-426 (Untrusted Search Path), CWE-59 (Improper Link Resolution)

```bash
exec "$HOME/dev/dotfiles/hygiene-status.sh" --reminder
```

If `$HOME/dev/dotfiles` is replaced with a symlink to an attacker-controlled location, the hook executes an arbitrary script with Claude’s privileges.

**Remediation:**
```bash
TARGET="$(realpath "$HOME/dev/dotfiles/hygiene-status.sh" 2>/dev/null)"
[[ "$TARGET" == "$HOME/dev/dotfiles/"* ]] || { echo "ERROR: symlink escape detected" >&2; exit 1; }
exec "$TARGET" --reminder
```

---

### [LOW-1] SHA-256 Pin Has No Automated Staleness Detection

**Severity:** LOW  
**File:** `setup.sh:508–552`  
**CWE:** CWE-494 (Download of Code Without Integrity Check)

The bun installer SHA-256 pin is correct practice but has no automated check for when the upstream installer changes. This encourages use of the `BUN_UNPINNED=1` bypass (see HIGH-1).

**Remediation:** Create a `check-bun-pin.sh` script that fetches the current installer digest and compares it. Run in CI to alert when the pin becomes stale.

---

### [LOW-2] ntfy Hook Sends Session Summaries to Public Server by Default

**Severity:** LOW  
**File:** `claude/hooks/ntfy-awaiting-input.sh:18–79`  
**CWE:** CWE-200 (Exposure of Sensitive Information), CWE-319 (Cleartext Transmission)

When `$NTFY_TOPIC` is set, session context (question headers, summaries) is sent to `ntfy.sh` (public server) by default. ntfy.sh topics are publicly readable by anyone who knows the topic name.

**Mitigation already present:** Topic validated against `^[A-Za-z0-9_-]+$`. Document that users MUST use a high-entropy topic (32+ random characters) and consider recommending self-hosted ntfy for sensitive work.

---

### [LOW-3] WSL Distro Name Not Validated Before UNC Path Embed

**Severity:** LOW  
**File:** `setup.sh:1123–1124`  
**CWE:** CWE-74 (Improper Neutralization of Special Elements)

`WSL_DISTRO_NAME` embedded into a UNC path without validation. Characters like `` ` ``, `$`, or path separators could affect the PowerShell `Copy-Item` operation.

**Remediation:** Validate against `^[A-Za-z0-9_-]+$` before embedding.

---

### [INFO-1] `cc-functions.ps1` Self-Update Copies from Unverified WSL Source

**Severity:** INFO  
**File:** `windows/cc-functions.ps1:91–118`  
**CWE:** CWE-494 (Download of Code Without Integrity Check)

`ccupdate` copies from WSL via UNC path without hash verification. If the WSL filesystem is compromised, the compromise propagates to Windows PowerShell profile. Low risk; document the trust assumption explicitly.

---

### [INFO-2] Hardcoded Owner References in Documentation

**Severity:** INFO  
**Files:** `docs/BRANCH_PROTECTION.md:7,54,64,70,99`; `claude/PAI/MEMORY/PR_WATCH/README.md:34,36,43`; `README.md:9,67,102,125`  
**CWE:** CWE-200 (minor)

Documentation contains hardcoded `jckeen/` GitHub owner references and `/home/jckee/` paths in examples. Low risk. Replace with `<owner>/dotfiles` or `$REPO_OWNER/dotfiles` placeholder syntax.

---

## Clean Areas

- No hardcoded secrets (API keys, tokens, passwords) in source files
- PRWatcherAutoLaunch uses `spawn(..., args)` (not `bash -c`) — no shell injection
- Owner/repo allowlist validation applied to GitHub API responses
- Secret redaction in PromptProcessing hook (`sk-`, `ghp_`, `xoxb-` patterns)
- systemd hardening: `ProtectSystem=strict`, `RestrictAddressFamilies`, `SystemCallFilter`
- Secret staging prevention: sync-memory() aborts if `.env`, `.key`, `.pem`, or `secret` files are staged
- Path traversal guards in format-on-edit.sh
