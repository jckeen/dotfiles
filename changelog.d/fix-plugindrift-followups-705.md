## 2026-10-22 — fix(hooks): PluginDriftCheck input cap, per-checkout project mods, root-safe test (#705)

- **PluginDriftCheck hook**: a prompt large enough to push the hook input past
  1 MiB cut the JSON before parsing, so the event read as missing and the
  hook ran the SessionStart branch, a full scan and report, on every such
  prompt. The leading event, session and cwd fields are now recovered from
  the truncated input, and input whose event cannot be read at all takes the
  cheap rescan path.
- **PluginDriftCheck hook**: a project mod already reported was remembered by
  name only, so the same name appearing in a second checkout (the cwd and
  `CLAUDE_PROJECT_DIR`) stayed silent. Project reports are now remembered per
  checkout.
- **plugin-drift test**: the permission case skips under root, which ignores
  mode bits, as the other root-sensitive suites do.
