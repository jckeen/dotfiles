## 2026-10-21 — fix: pin Node v24.22.1 (October 2026 security release) and upgrade existing installs

- **`setup.sh`**: `NODE_VERSION` v24.18.0 → v24.22.1, the 24.x release
  carrying the 2026-10-21 Node.js security fixes (four high: TLS hostname
  bypasses CVE-2026-105483/-106069, `dns.resolve` NUL truncation
  CVE-2026-105482, Brotli OOB write CVE-2026-111497).
- **Upgrade path**: Node was only installed when `node` was missing, so a
  bumped pin never reached an existing machine, and apt's EOL v18 silently
  satisfied the check. Re-running `setup.sh` now re-pins when
  `~/.local/bin/node` is the pinned install at a different version, or when
  the active node is an older major (`NODE_INSTALL_METHOD=pinned`, Linux).
