## 2026-10-22 — chore(plugins): retire the eleven plugins dropped in #500 on every machine

- **`claude/plugins.txt`**: #500 dropped eleven unused plugins from the
  manifest, but deleting a line never uninstalls anything, so their
  user-scope installs survived on existing machines and `PluginDriftCheck`
  warned about reverse drift at every session start. Each now has a
  `# removed:` line, which `sync-plugins.sh` (run by `cc` at every fresh
  launch) turns into a one-time uninstall.
