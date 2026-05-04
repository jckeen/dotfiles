# Security Findings — dotfiles — 2026-05-03

> Weekly automated security sweep. Static analysis only — no code was executed.
>
> Remediation update: this PR now includes fixes for the confirmed high-risk
> command/argument injection findings and small hardening changes for local file
> permissions, bun path validation, and port-cleanup error reporting.

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 3 |
| MEDIUM | 4 |
| LOW | 2 |
| **Total** | **9** |

---

## Findings

### [HIGH] FULL_AUTO=true bypasses all Claude permission checks — CWE-250

- **File:** `claude/scripts/common.sh:86–92`
- **Description:** Setting the environment variable `FULL_AUTO=true` passes `--dangerously-skip-permissions` to Claude, bypassing all permission prompts and safety checks. Any process with access to this shell environment (a malicious script, an accidental env var leak, or a compromised `.env` file) gains the ability to execute arbitrary code without confirmation.
- **Remediation:** Remove the `FULL_AUTO` bypass entirely, or replace it with a non-env-var mechanism (e.g., require a file token at a fixed path with `chmod 600`). If the bypass must exist, require it to be explicitly passed as a CLI argument rather than set as an environment variable. Document in SECURITY.md that `--dangerously-skip-permissions` must never be used in production or on machines with sensitive data.
- **CWE:** CWE-250 (Execution with Unnecessary Privileges)

---

### [HIGH] Unquoted variable in command substitution — CWE-77

- **File:** `setup.sh:458`
- **Description:** The Windows username is extracted and used in subsequent heredoc constructions without quoting: `WIN_USER=$(/mnt/c/Windows/System32/cmd.exe /c "echo %USERNAME%"...)`. If the Windows username contains shell metacharacters, command injection is possible in downstream uses at lines 464 and 466.
- **Remediation:** Quote `"${WIN_USER}"` in all heredoc and command expansions. Validate the username against a safe character allowlist (alphanumeric + underscore + hyphen) immediately after extraction.
- **CWE:** CWE-77 (Improper Neutralization of Special Elements in a Command)

---

### [HIGH] Unquoted FULL_AUTO_FLAG variable enables argument injection — CWE-88

- **File:** `claude/scripts/overnight.sh:109, 130, 139`
- **Description:** `$FULL_AUTO_FLAG` is passed unquoted to child scripts: `"$SCRIPT_DIR/health-check.sh" "$repo" $FULL_AUTO_FLAG &`. If `FULL_AUTO_FLAG` were set to a value containing spaces or shell metacharacters (via environment variable injection), word splitting would allow arbitrary argument injection.
- **Remediation:** Quote the variable: `"$SCRIPT_DIR/health-check.sh" "$repo" "$FULL_AUTO_FLAG" &`.
- **CWE:** CWE-88 (Argument Injection or Modification)

---

### [MEDIUM] Git identity written without explicit permission restriction — CWE-798

- **File:** `setup.sh:448–477`
- **Description:** The script writes `.gitconfig.local` containing the user's name and email but does not explicitly set file permissions (`chmod 600`) after writing. If this file is world-readable, personal email addresses are exposed to all users on shared systems.
- **Remediation:** Add `chmod 600 "$DOTFILES_DIR/.gitconfig.local"` immediately after the heredoc write. Add `.gitconfig.local` to `.gitignore` to prevent accidental commits.
- **CWE:** CWE-798 (Use of Hard-Coded Credentials)

---

### [MEDIUM] Symlink targets not validated against dotfiles directory — CWE-426

- **File:** `setup.sh:126–162` (`audit_link` function)
- **Description:** `audit_link()` validates symlinks by comparing `readlink` output but does not verify that the resolved source path is within `$DOTFILES_DIR`. A compromised `.claude/` directory containing symlinks pointing to `/etc/passwd` or other sensitive system files could be silently processed.
- **Remediation:** Validate with `realpath`: ensure `$(realpath "$src")` starts with `$DOTFILES_DIR` before proceeding. Reject symlinks with sources outside the dotfiles tree.
- **CWE:** CWE-426 (Untrusted Search Path)

---

### [MEDIUM] Scripts set to world-executable without explicit base permission — CWE-276

- **Files:** `claude/scripts/` and `claude/hooks/` (chmod lines 509, 520, 550, 588)
- **Description:** Scripts are `chmod +x` (mode 755) rather than mode 700. If any script is later modified to contain credentials or sensitive logic, world-readable permissions expose that content to all users on the system.
- **Remediation:** Use `chmod 700` on all scripts in `claude/scripts/` and `claude/hooks/`. Document the expected permission in setup comments.
- **CWE:** CWE-276 (Incorrect Default Permissions)

---

### [MEDIUM] Insecure PowerShell variable interpolation in WSL commands — CWE-77

- **File:** `windows/cc-functions.ps1:68, 85, 139, 146`
- **Description:** PowerShell functions interpolate `$p` (project name) directly into bash commands: `wsl.exe -d $script:WslDistro -- bash -ic "cc $p"`. A project name containing spaces or quotes could enable command injection. A `Test-SafeProjectName` check exists but is not applied consistently before all uses of `$p`.
- **Remediation:** Apply `Test-SafeProjectName` validation before `$p` is used in any command. Add quoting as an additional defense: `"cc '$p'"`.
- **CWE:** CWE-77 (Improper Neutralization of Special Elements in a Command)

---

### [LOW] Hardcoded bun path in systemd unit — CWE-427

- **File:** `setup.sh:298–333`, `claude/systemd/install.sh:38, 178`
- **Description:** Scripts hardcode `~/.bun/bin/bun` as the systemd unit path. If `bun` is installed in a different location, the symlink creation may fail silently without a clear error.
- **Remediation:** Add explicit validation after symlink creation: `[ -e ~/.bun/bin/bun ] || die "Failed to create bun symlink"`. Fall back to `which bun` if the fixed path does not exist.
- **CWE:** CWE-427 (Uncontrolled Search Path Element)

---

### [LOW] Process kill errors silently ignored in port cleanup — CWE-252

- **File:** `claude/systemd/install.sh:71–82`
- **Description:** Port 8888 cleanup uses `kill "$p" 2>/dev/null || true`, masking failures. If a process cannot be killed, the service will fail to start but the error is not surfaced.
- **Remediation:** Replace `|| true` with an explicit warning: `if ! kill "$p" 2>/dev/null; then yell "! Failed to kill PID $p"; fi`.
- **CWE:** CWE-252 (Unchecked Return Value)

---

## Positive Security Controls Observed

- Git identity stored in `.gitconfig.local` (separate from committed `.gitconfig`) ✓
- `.env*` excluded from version control ✓
- Automated health checks with logging ✓
- No hardcoded API keys or secrets in source or git history ✓
