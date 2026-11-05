## 2026-10-22 — fix(plugins): disable per-project plugins after install so reruns stop re-enabling them (#720)

- **setup.sh and sync-plugins.sh**: `claude plugin install` enables the plugin
  in the user `enabledPlugins` map, so every install of a `[per-project]`
  plugin put it back in the global settings and the scoping warning returned
  at the next session start. Both now run `claude plugin disable --scope user`
  right after installing each plugin under the `[per-project]` marker. A
  failed disable fails the sync run and prints the command to run by hand in
  setup.sh.
- **lib-checks.sh**: new `manifest_per_project_plugins` reads the manifest's
  section markers with the same rules as the drift hook, so both installers
  share one parser.
- **plugin-drift.test.sh**: the claude stub now models `enabledPlugins`; new
  cases assert a `[per-project]` install is not left enabled, a `[global]`
  install stays enabled, and setup.sh uses the shared helper.
