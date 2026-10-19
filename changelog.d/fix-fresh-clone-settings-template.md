## 2026-10-19 — fix: a fresh clone without claude-memory gets a settings.json that wires the hooks

- **`claude/settings.example.json`** (new): a public `hooks` block that
  registers every hook in `claude/hooks/` with its event and matcher, plus
  the `statusLine` for `statusline.sh`. It holds no permissions, MCP servers
  or env. Listed in `claude/nolink.txt`, so the symlink pass never deploys it
  (#588).
- **`setup.sh`**: when Claude Code is selected and neither
  `~/.claude/settings.json` (a dangling symlink counts) nor
  `claude-memory/bootstrap.sh` exists, `seed_claude_settings` copies the
  example in as a real file. A noclobber write means it never overwrites a
  file. `--dry-run` previews the copy, and the summary says which of the two
  happened. A real run that leaves hooks linked but `settings.json` missing
  ends with a warning and the `cp` command that fixes it. Before, such a
  clone reported a successful setup while every hook and the status line
  were inert.
- **`claude/scripts/tests/settings-example.test.sh`** (new; run from
  `setup-dry-run.test.sh`): the public counterpart of
  `check-hooks-wired.sh`. Every hook file must be registered and every
  registration must name a real file. The status line must run
  `statusline.sh`, the template must carry no private keys, and the symlink
  pass must never link it. The seed must create the file once, never
  overwrite it, leave a dangling link alone, defer to the bootstrap, and only
  preview under `--dry-run`.
- **Docs**: README no longer claims hooks and the status line work without
  `claude-memory`. Its `touch settings.json` recipe (not valid JSON) is now a
  copy of the example plus a working `bootstrap.sh`. CLAUDE-GUIDE's Hooks
  section, `claude/scripts/README.md` and `check-hooks-wired.sh`'s hints
  point at the template.
