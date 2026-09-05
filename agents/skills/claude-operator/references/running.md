# File-backed Claude turns

`scripts/claude_run.py` runs one native Claude Code print-mode turn from a
prompt file and records evidence. Python 3 standard library only; run it inside
WSL, Linux, or macOS. Write the UTF-8 prompt in your private workspace and
choose a new output directory for every turn.

```bash
python3 ~/.agents/skills/claude-operator/scripts/claude_run.py \
  --cwd <dev-dir>/<project> \
  --prompt-file <workspace>/brief.txt \
  --output-dir <workspace>/run-01 \
  --allow-tool Read --allow-tool 'Bash(bun run build)' --allow-tool 'Bash(bun test)'
```

From Windows, prefix with `wsl.exe -d <distro> --exec` and use `/mnt/c/…`
paths for files on the Windows side.

Defaults: the native `~/.local/bin/claude` (`PATH` is never searched; pass
`--claude-bin` for another install), the configured model, `--permission-mode acceptEdits`, and `--permission-prompts none` so
anything that would prompt is denied and recorded instead of hanging. Hooks,
skills, project instructions, and session persistence stay on. The prompt is
sent on stdin as bytes and then stdin is closed; the runner never puts prompt
text into a shell string or argv, so quotes, `$VAR`, backticks, and non-ASCII
text arrive literally.

## Artifacts

The output directory receives:

- `run.json`: cwd, the exact requested session ID, the executable used and
  why, the owned process group, start and finish times, status, and exit code.
- `prompt.txt`: the exact bytes sent for this turn.
- `events.jsonl`: every stream-json event Claude emitted.
- `stderr.log`: Claude's stderr plus any shell startup-file chatter.
- `result.json`: the final result event, when one arrived.

Stdout carries one JSON line per event for the operator to read while the run
is in progress: `started` (with the runner PID and process group), `progress`
(assistant text), `tool` (tool name), and `finished`.

## Exit codes and states

| Exit | `run.json` status | Meaning |
| --- | --- | --- |
| 0 | `turn_complete` | Claude returned a success result for this exact session. It does **not** establish the acceptance criteria; verify the work. |
| 1 | `failed` | No result, an error result, a nonzero Claude exit, an auth or quota failure, or a rejected CLI flag (`unsupported_flag` names it). |
| 1 | `session_mismatch` | The result's session ID differs from the requested one or is missing; `actual_session_id` records what came back. Do not treat as a resumable continuation. |
| 2 | `needs_permission` | The turn finished but recorded permission denials. Read them in `result.json` before continuing, even if Claude's prose says it is done. |
| 124 | `timed_out` | `--timeout` elapsed; the owned run was stopped. |
| 130 / 143 | `interrupted` | The runner received SIGINT / SIGTERM and stopped the owned run; `interrupted_by` names the signal. |
| 64 | (no run directory) | Usage error, including any attempt to pass a bypass flag. |

If the installed Claude rejects `--permission-prompts` (older CLI), the run is
reported as failed with the flag named. Upgrade Claude Code; the runner never
retries with weaker permission handling.

## Follow-ups

For another turn in the same conversation, write a fresh prompt file, choose a
fresh output directory, read the exact `session_id` from the previous
`run.json`, and pass `--resume SESSION_ID` with the same `--cwd`. Confirm the
previous process finished first. Never use `--continue`, which could select a
different session. A run that failed before Claude created the session may not
be resumable; an interrupted run still records the requested ID for inspection.

```bash
python3 ~/.agents/skills/claude-operator/scripts/claude_run.py \
  --cwd <dev-dir>/<project> --prompt-file <workspace>/fix.txt \
  --output-dir <workspace>/run-02 --resume SESSION_ID --allow-tool 'Bash(bun test)'
```

## Stopping a run you own

The runner puts Claude in its own process group and records it as
`claude_process_group`. To stop only that run, send SIGINT or SIGTERM to the
`runner_pid` from `run.json`; the runner sends SIGTERM to the whole group
(even if the original Claude process already exited and left children
behind), escalates to SIGKILL after ten seconds for anything that ignored it,
and records the interrupted state with the evidence gathered so far. Never stop all Claude processes or
another user's session. Inspect `git status` before resuming an interrupted
edit. `--timeout SECONDS` applies the same stop automatically.

## Options

- `--permission-mode manual|acceptEdits|auto|dontAsk|plan`: choose a
  supported mode. No bypass mode is exposed.
- `--allow-tool RULE` (repeatable): task-specific permission rules, e.g.
  `'Bash(bun test)'`. They add to the user's existing permissions.
- `--tools LIST`: restrict the built-in tool set, e.g. `Read,Edit,Bash`.
- `--model VALUE`: only when the user chooses a model.
- `--timeout SECONDS`: stop the owned run after this long.
- `--claude-bin PATH`: explicit executable.
- `--safe-mode`: customizations disabled; troubleshooting only.
- `--dry-run`: resolve inputs and print the planned command as JSON without
  creating files, launching Claude, or contacting its service.

For an interactive Claude session that needs keyboard control, use an owned
terminal or tmux session and inspect its screen before typing. A session ID
that is open interactively must not be resumed concurrently.
