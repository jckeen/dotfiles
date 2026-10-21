## 2026-10-21 — fix: Antigravity gate defaults to Gemini 4 Argon (High)

- **`claude/scripts/antigravity-review-gate.sh`**: the default pin
  `Gemini 3.1 Pro (High)` is no longer a valid agy model, so every ordinary
  review exited 1 and degraded open (#696). The default is now
  `Gemini 4 Argon (High)`; `ANTIGRAVITY_GATE_MODEL` still overrides it.
