## 2026-11-21 — test(antigravity): skip permission-denial fixtures when running as root (#799)

- **`antigravity-config.test.sh`**: guarded section 10 (`chmod 111/444/000` on `AGY_BIN_DIR` and `chmod 000` on its parent directory) behind `id -u -ne 0` so running the suite as `root` skips `chmod`-based permission-denial assertions that kernel discretionary access bypasses, keeping the earlier `EXIT` trap active so `set -u` never references an unset `UNREAD_PARENT`.
