# Security Findings — 2026-05-10

**Repository:** jckeen/dotfiles  
**Audit date:** 2026-05-10  
**Auditor:** Claude Sonnet 4.6 (static analysis only — no code executed)  
**Scope:** Hardcoded secrets, injection, path traversal, insecure deserialization, weak crypto, auth flaws, authz gaps, CORS/headers, dependency CVEs

## Summary

| ID | Severity | Category | File |
|----|----------|----------|------|
| DF-1 | HIGH | curl-pipe-bash without integrity check | `setup.sh` |
| DF-2 | MEDIUM | User input interpolated into git config heredoc | `setup.sh` |
| DF-3 | MEDIUM | Unsanitized env var in curl URL / POST body | `claude/hooks/ntfy-awaiting-input.sh` |
| DF-4 | MEDIUM | Path traversal risk in dynamic formatter path | `claude/hooks/format-on-edit.sh` |
| DF-5 | MEDIUM | Prompt injection via diagram file preloading | `.bash_aliases` |
| DF-6 | LOW | Brittle regex-based commit message parsing | `claude/hooks/conventional-commit.sh` |
| DF-7 | LOW | WSL distro name not validated before UNC embed | `setup.sh` |
| DF-8 | LOW | Prompt injection risk from PR content in context | `claude/hooks/PRWatcherSurface.hook.ts` |
| DF-9 | INFO | Partial systemd service hardening | `claude/systemd/pai-voice-server.service` |
| DF-10 | INFO | `git add -A` in auto-commit could include secrets | `.bash_aliases` |

---

## DF-1 — HIGH: curl-pipe-bash Without Integrity Check

**File:** `setup.sh` (~line 310–315)  
**CWE:** CWE-494 (Download of Code Without Integrity Check), CWE-829 (Inclusion from Untrusted Sphere)

The Bun installer fallback uses:
```bash
curl -fsSL https://bun.sh/install | bash
```
The download is not verified against a checksum or GPG signature. A DNS hijack, MITM attack, or CDN compromise at `bun.sh` would execute arbitrary code with the installing user's privileges. The `-L` flag follows redirects silently.

**Remediation:**
- Download to a temp file, verify SHA-256 against a pinned expected hash, then execute.
- Or use Homebrew (`brew install oven-sh/bun/bun`) which the macOS path already handles correctly — extend that to all platforms.
- At minimum, add `--proto '=https'` and remove `-L` to prevent redirect-following to HTTP.

---

## DF-2 — MEDIUM: User Input Interpolated Into git Config Heredoc

**File:** `setup.sh` (~lines 390–430)  
**CWE:** CWE-116 (Improper Encoding), CWE-74 (Improper Neutralization of Special Elements)

`GIT_NAME` and `GIT_EMAIL` (collected from user or `git config`) are interpolated directly into a heredoc that writes `.gitconfig.local`. Special characters (newlines, `]`, shell metacharacters) in these values would corrupt the git config. The WSL branch additionally interpolates `WIN_USER` (sourced from `cmd.exe /c "echo %USERNAME%"`) into file paths and heredoc content.

**Remediation:**
- Use `git config --file "$DOTFILES_DIR/.gitconfig.local" user.name "$GIT_NAME"` instead of heredoc interpolation — git handles escaping correctly.
- Enforce the existing `WIN_USER` character-set regex check _before_ embedding in paths, and exit rather than silently continuing on mismatch.

---

## DF-3 — MEDIUM: Unsanitized Variables in curl URL and POST Body

**File:** `claude/hooks/ntfy-awaiting-input.sh:44–47`  
**CWE:** CWE-93 (CRLF Injection), CWE-601 (URL Redirection to Untrusted Site)

`$SUMMARY` (extracted from Claude JSON input via `jq`) is passed unquoted to `curl -d`. `$NTFY_SERVER` comes from environment with no validation beyond empty-check — a crafted value redirects push notifications to an attacker-controlled server, leaking the content of Claude's questions.

**Remediation:**
- Validate `NTFY_SERVER` against an allowlist or hostname regex.
- Double-quote `$SUMMARY` in the curl invocation.
- Truncate/sanitize `$SUMMARY` to printable ASCII (currently only length-truncated).

---

## DF-4 — MEDIUM: Path Traversal Risk in Dynamic Formatter Path

**File:** `claude/hooks/format-on-edit.sh:28–32`  
**CWE:** CWE-22 (Path Traversal), CWE-78 (OS Command Injection)

`$FILE_PATH` comes from Claude's JSON tool input via `jq` and is used in a directory-traversal loop to locate a project-local `prettier` binary. While the final execution line double-quotes the variable, the loop logic relies on clean input. AI tool input could theoretically be manipulated via prompt injection to target an unexpected path.

**Remediation:**
- Validate `$FILE_PATH` is an absolute path with no `..` components before use: `[[ "$FILE_PATH" == /* ]] && [[ "$FILE_PATH" != *..* ]]`
- Assert the path resolves within an expected project root.

---

## DF-5 — MEDIUM: Prompt Injection via Diagram File Preloading

**File:** `.bash_aliases` (~lines 100–115, `cc()` function)  
**CWE:** CWE-77 (Prompt Injection), CWE-20 (Improper Input Validation)

```bash
for f in .ai/diagrams/*.md; do
  diagrams+="$(cat "$f")"$'\n'
done
--append-system-prompt "$diagrams"
```
Content from `.ai/diagrams/*.md` is passed unsanitized into the Claude Code system prompt on every launch. Files written by Claude in prior sessions or committed by a third party could inject adversarial instructions into the base prompt.

**Remediation:**
- Validate that diagram files are not world-writable before including them.
- Strip or escape content that matches system-prompt injection patterns (XML tags, `SYSTEM:` prefixes).
- Consider a `--no-diagrams` flag to disable preloading in automated contexts.

---

## DF-6 — LOW: Brittle Regex-Based Commit Message Parsing

**File:** `claude/hooks/conventional-commit.sh:50–60`  
**CWE:** CWE-20 (Improper Input Validation)

The hook attempts to extract a commit message from Claude's shell command string using `sed`/`grep` patterns. A crafted command using alternative heredoc delimiters or escape sequences could bypass the conventional-commit policy check.

**Remediation:** Parse the commit message from the git object after commit (in a `PostToolUse` hook) rather than parsing the shell command string, which is ambiguous.

---

## DF-7 — LOW: WSL Distro Name Not Validated Before UNC Path Embed

**File:** `setup.sh` (~lines 460–510)  
**CWE:** CWE-74 (Improper Neutralization of Special Elements)

`WSL_DISTRO_NAME` is embedded into a UNC path and passed to PowerShell via `WSLENV`. A distro name containing UNC path separators or PowerShell metacharacters could affect the `Copy-Item` operation.

**Remediation:** Validate `WSL_DISTRO_NAME` against `^[A-Za-z0-9-]+$` before embedding in the UNC path.

---

## DF-8 — LOW: Prompt Injection from PR Content in Claude Context

**File:** `claude/hooks/PRWatcherSurface.hook.ts:110–120`  
**CWE:** CWE-77 (Prompt Injection), CWE-116 (Improper Encoding)

The `sanitize()` function truncates to 200 chars and removes ASCII control characters, but does not strip Unicode direction-override characters or structured injection patterns. The `UNTRUSTED_PR_FEEDBACK` fencing is a good mitigation but relies entirely on model prompt-following.

**Remediation:** Extend sanitization to strip Unicode bidi overrides and known injection markers. Consider HTML-encoding the content before placing it in the context block.

---

## DF-9 — INFO: Partial Systemd Service Hardening

**File:** `claude/systemd/pai-voice-server.service`  
**CWE:** CWE-250 (Execution with Unnecessary Privileges)

Service includes `NoNewPrivileges=true` and `PrivateTmp=true` but is missing `ProtectSystem=strict`, `ProtectHome=read-only`, `RestrictAddressFamilies`, and `SystemCallFilter`. The service runs arbitrary TypeScript — hardening the syscall surface reduces blast radius.

**Remediation:** Run `systemd-analyze security pai-voice-server.service` and address the scored gaps.

---

## DF-10 — INFO: `git add -A` in Auto-Commit

**File:** `.bash_aliases` (~lines 70–80, `sync-memory()`)  
**CWE:** CWE-312 (Cleartext Storage of Sensitive Information)

`git add -A` stages all changes including any new files, potentially including temporary secrets placed in the repo directory. Consider `git add -u` (update tracked files only) to prevent accidental secret commits.

---

## Positive Findings

- No hardcoded API keys, tokens, or passwords found in source files.
- All credential references use environment variable placeholders.
