# shellcheck shell=bash
# ~/.bash_aliases — sourced by .bashrc / .bash_profile. Not a standalone script.

# Claude Code scripts + dotfiles bin helpers on PATH. ~/.local/bin is where
# setup.sh symlinks the top-level helper scripts (gh-bootstrap.sh,
# git-hygiene.sh, …); prepend it here so the aliases that call them resolve
# even on a fresh install whose login shell hasn't already added it to PATH.
export PATH="$HOME/.local/bin:$HOME/.claude/scripts:$PATH"

# Claude Code aliases
alias claude-server='claude remote-control --spawn worktree'
alias claude-rc='claude --remote-control'

# Detect dev directory — reads from ~/.claude/dev-dir (written by setup.sh).
# Memoized: this is called on nearly every cc/cx/agy/gh invocation, so cache the
# value after the first read instead of forking `cat` each time.
_dev_dir() {
  if [ -z "${_DEV_DIR_CACHE:-}" ]; then
    if [ -f "$HOME/.claude/dev-dir" ]; then
      _DEV_DIR_CACHE="$(cat "$HOME/.claude/dev-dir")"
    else
      _DEV_DIR_CACHE="$HOME/dev"
    fi
  fi
  printf '%s\n' "$_DEV_DIR_CACHE"
}

# Pull latest for all git repos under dev directory. Pulls are intentionally
# sequential: linked worktrees share fetch/object state, so parallel pulls can
# contend even though their checked-out branches are different.
pull-all() {
  local dev_dir
  dev_dir="$(_dev_dir)"
  if [ ! -d "$dev_dir" ]; then
    echo "Dev directory not found: $dev_dir"
    return 1
  fi
  local failed=0 remote_output upstream output
  local repo name rc
  for repo in "$dev_dir"/*/; do
    [ -e "$repo/.git" ] || [ -L "$repo/.git" ] || continue
    name="$(basename "$repo")"
    if ! output="$(git -C "$repo" rev-parse --is-inside-work-tree 2>&1)"; then
      failed=1
      printf "  %-20s%s\n" "$name" "$(tail -1 <<< "$output")"
      continue
    fi
    if ! remote_output="$(git -C "$repo" remote -v 2>&1)"; then
      failed=1
      printf "  %-20s%s\n" "$name" "$(tail -1 <<< "$remote_output")"
      continue
    fi
    [ -n "$remote_output" ] || continue
    if ! upstream="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
      printf "  %-20s%s\n" "$name" "No upstream branch; skipped"
      continue
    fi
    rc=0
    output="$(git -C "$repo" pull --ff-only 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] || failed=1
    printf "  %-20s%s\n" "$name" "$(tail -1 <<< "$output")"
  done
  return "$failed"
}

# Strict launcher health wrappers. Standalone checkers remain useful as
# reporters, while launchers treat every actionable managed-config warning as
# a stop condition.
_check_claude_launch_health() {
  sync-memory || return 1
  "$(_dev_dir)/dotfiles/check-claude.sh" --heal
}

_check_codex_launch_health() {
  "$(_dev_dir)/dotfiles/check-codex.sh" --strict
}

_check_antigravity_launch_health() {
  "$(_dev_dir)/dotfiles/check-antigravity.sh" --strict
}

_codex_is_resume_invocation() {
  local dev_dir
  dev_dir="$(_dev_dir)"
  if [ -n "${1:-}" ] && [[ "$1" != -* ]] && [ -d "$dev_dir/$1" ]; then
    shift
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      resume|fork) return 0 ;;
      --|-h|--help|-V|--version|-i|--image) return 1 ;;
      --image=*|-i?*) shift ;;
      --strict-config|--oss|--dangerously-bypass-approvals-and-sandbox|--dangerously-bypass-hook-trust|--search|--no-alt-screen)
        shift
        ;;
      --config=*|--enable=*|--disable=*|--remote=*|--remote-auth-token-env=*|--model=*|--local-provider=*|--profile=*|--sandbox=*|--cd=*|--add-dir=*|--ask-for-approval=*)
        shift
        ;;
      -c|-m|-p|-s|-C|-a|--config|--enable|--disable|--remote|--remote-auth-token-env|--model|--local-provider|--profile|--sandbox|--cd|--add-dir|--ask-for-approval)
        [ "$#" -ge 2 ] || return 1
        shift 2
        ;;
      -c?*|-m?*|-p?*|-s?*|-C?*|-a?*)
        shift
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# Check Claude config symlinks are healthy
check-claude() {
  "$(_dev_dir)/dotfiles/check-claude.sh" "$@"
}

# Check Codex public config and private/generated state boundaries
check-codex() {
  "$(_dev_dir)/dotfiles/check-codex.sh" "$@"
}

# Commit and push any pending memory changes from last session
_memory_git() {
  local repo="$1"
  shift
  GIT_NO_REPLACE_OBJECTS=1 git -C "$repo" "$@"
}

_memory_path_is_publishable() {
  local path="$1" folded sensitive_folded
  [[ "$path" =~ ^[^/]+/memory/ ]] || return 1
  folded="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')" || return 1
  # Allow an explicit author/authors document component without weakening the
  # auth/authorization/oauth deny boundary elsewhere in the path.
  sensitive_folded="$(printf '%s' "$folded" \
    | sed -E 's#(^|/)authors?(\.[^/]*)?(/|$)#\1\2\3#g')" || return 1
  [[ ! "$sensitive_folded" =~ auth|session|cache ]] || return 1
  [[ ! "$folded" =~ (^|/)(auth|sessions?|cache|logs?|credentials?|tokens?|secrets?)([^[:alnum:]/][^/]*|/|$)|(^|/)[^/]*\.env([^/]*)(/|$)|\.(key|pem)([^/]*)$|secret|credentials|token ]]
}

_memory_content_is_safe() {
  local content_file="$1" scan_dir
  scan_dir="$(mktemp -d)" || return 1
  if ! (
    unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
    cd "$scan_dir" || exit 1
    gitleaks stdin --redact --exit-code 1 --no-banner \
      --ignore-gitleaks-allow --gitleaks-ignore-path /dev/null < "$content_file"
  ); then
    rm -rf "$scan_dir"
    return 1
  fi
  rm -rf "$scan_dir"
}

_memory_blob_is_safe() {
  local repo="$1" tree="$2" path="$3" listing blob blob_spec
  listing="$(mktemp)" || return 1
  blob="$(mktemp)" || { rm -f "$listing"; return 1; }

  if [ "$tree" = ":" ]; then
    blob_spec=":$path"
    _memory_git "$repo" ls-files --stage -z -- "$path" > "$listing" || {
      rm -f "$listing" "$blob"
      return 1
    }
  else
    blob_spec="$tree:$path"
    _memory_git "$repo" ls-tree -z "$tree" -- "$path" > "$listing" || {
      rm -f "$listing" "$blob"
      return 1
    }
  fi

  # Deletions have no resulting blob to publish. Every other changed entry is
  # scanned as raw content, so binary patches cannot hide embedded credentials.
  if [ ! -s "$listing" ]; then
    rm -f "$listing" "$blob"
    return 0
  fi
  if ! _memory_git "$repo" cat-file blob "$blob_spec" > "$blob" \
    || ! _memory_content_is_safe "$blob"; then
    rm -f "$listing" "$blob"
    return 1
  fi
  rm -f "$listing" "$blob"
}

_memory_range_is_safe() {
  local repo="$1" upstream="$2" memory_pathspec="$3" validated_head="${4:-HEAD}"
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "  Memory sync requires gitleaks before publishing commits." >&2
    return 1
  fi

  local commits_file paths_file commit_file commit path unsafe
  commits_file="$(mktemp)" || return 1
  if ! _memory_git "$repo" rev-list --reverse "$upstream".."$validated_head" > "$commits_file"; then
    rm -f "$commits_file"
    return 1
  fi

  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    commit_file="$(mktemp)" || { rm -f "$commits_file"; return 1; }
    if ! _memory_git "$repo" cat-file commit "$commit" > "$commit_file" \
      || ! _memory_content_is_safe "$commit_file"; then
      rm -f "$commit_file" "$commits_file"
      echo "  SECRET-LIKE COMMIT METADATA IN PENDING MEMORY HISTORY — refusing to push." >&2
      return 1
    fi
    rm -f "$commit_file"
    paths_file="$(mktemp)" || { rm -f "$commits_file"; return 1; }
    if ! _memory_git "$repo" diff-tree --root --no-commit-id --name-only -z -r -m "$commit" > "$paths_file"; then
      rm -f "$paths_file" "$commits_file"
      return 1
    fi
    unsafe=0
    while IFS= read -r -d '' path; do
      [ -n "$path" ] || continue
      if ! _memory_path_is_publishable "$path"; then
        unsafe=1
        break
      fi
      if ! _memory_blob_is_safe "$repo" "$commit" "$path"; then
        echo "  SECRET-LIKE CONTENT IN PENDING MEMORY COMMIT — refusing to push." >&2
        rm -f "$paths_file" "$commits_file"
        return 1
      fi
    done < "$paths_file"
    rm -f "$paths_file"
    if [ "$unsafe" -eq 1 ]; then
      echo "  Memory sync paused: commit $commit includes non-memory paths." >&2
      rm -f "$commits_file"
      return 1
    fi

  done < "$commits_file"
  rm -f "$commits_file"
}

_memory_push_upstream() {
  local repo="$1" validated_head="$2" remote="$3" merge_ref="$4" expected_upstream="$5"
  if [ "$remote" = "." ] || [[ "$merge_ref" != refs/heads/* ]] \
    || ! git check-ref-format "$merge_ref" >/dev/null 2>&1; then
    echo "  Memory sync requires a remote branch upstream." >&2
    return 1
  fi
  if ! _memory_git "$repo" merge-base --is-ancestor \
      "$expected_upstream" "$validated_head"; then
    echo "  Memory sync boundary is not an ancestor of the reviewed commit." >&2
    return 1
  fi

  # An explicit destination ref prevents push.default, remote.*.push, or a
  # configured mirror from publishing any refs outside the validated range.
  # The source is the immutable reviewed OID, never a mutable HEAD reference.
  _memory_git "$repo" -c "remote.$remote.mirror=false" -c push.followTags=false \
    push -q --force-with-lease="$merge_ref:$expected_upstream" -- \
      "$remote" "$validated_head:$merge_ref"
}

_memory_snapshot_upstream() {
  local repo="$1" branch_ref branch current_ref current_head
  branch_ref="$(_memory_git "$repo" symbolic-ref --quiet HEAD)" || return 1
  branch="${branch_ref#refs/heads/}"
  _memory_remote="$(_memory_git "$repo" config --get "branch.$branch.remote")" || return 1
  _memory_merge_ref="$(_memory_git "$repo" config --get "branch.$branch.merge")" || return 1
  _memory_upstream_oid="$(_memory_git "$repo" rev-parse "$branch@{upstream}^{commit}")" || return 1
  _memory_validated_head="$(_memory_git "$repo" rev-parse "$branch_ref^{commit}")" || return 1
  current_ref="$(_memory_git "$repo" symbolic-ref --quiet HEAD)" || return 1
  current_head="$(_memory_git "$repo" rev-parse HEAD)" || return 1
  [ "$current_ref" = "$branch_ref" ] && [ "$current_head" = "$_memory_validated_head" ]
}

sync-memory() {
  local dev_dir
  dev_dir="$(_dev_dir)"
  local mem_repo="$dev_dir/claude-memory"
  if [ ! -e "$mem_repo/.git" ] && [ ! -L "$mem_repo/.git" ]; then
    return 0
  fi
  if ! _memory_git "$mem_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "  Claude memory path exists but is not a healthy Git worktree." >&2
    return 1
  fi

  # Claude's auto-memory contract writes only immediate-project memory trees
  # such as dev/memory and dotfiles/memory. Preferences, settings, identity,
  # auth, sessions, caches, and arbitrary repo files require an intentional
  # commit and can never ride this automatic path.
  local memory_pathspec=':(glob)*/memory/**'

  # Retry a commit whose earlier push failed even when the worktree is now
  # clean. Without this, an interrupted cross-machine sync stays local forever.
  local upstream ahead remote merge_ref validated_head
  upstream="$(git -C "$mem_repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || {
    echo "  Memory sync has no upstream branch; configure one before automatic sync." >&2
    return 1
  }
  _memory_snapshot_upstream "$mem_repo" || return 1
  upstream="$_memory_upstream_oid"
  remote="$_memory_remote"
  merge_ref="$_memory_merge_ref"
  validated_head="$_memory_validated_head"
  ahead="$(_memory_git "$mem_repo" rev-list --count "$upstream".."$validated_head" 2>/dev/null)" || return 1
  if [ "$ahead" -gt 0 ]; then
    _memory_range_is_safe "$mem_repo" "$upstream" "$memory_pathspec" "$validated_head" || return 1
    echo "  Publishing pending memory commit..."
    if ! _memory_push_upstream "$mem_repo" "$validated_head" "$remote" \
        "$merge_ref" "$upstream"; then
      echo "  Memory push failed; the local commit remains pending." >&2
      return 1
    fi
    echo "  Memory saved."
  fi

  local status_output
  if ! status_output="$(_memory_git "$mem_repo" -c status.showUntrackedFiles=all \
      status --porcelain --untracked-files=all -- "$memory_pathspec" 2>/dev/null)"; then
    echo "  Memory sync could not read repository status." >&2
    return 1
  fi
  [ -n "$status_output" ] || return 0

  # Never absorb or disturb work the user already staged for a separate commit.
  if ! git -C "$mem_repo" diff --cached --quiet; then
    echo "  Memory sync paused: claude-memory already has staged user work." >&2
    return 1
  fi

  echo "  Saving memory..."
  git -C "$mem_repo" add -- "$memory_pathspec" || return 1
  if git -C "$mem_repo" diff --cached --quiet; then
    return 0
  fi

  if ! command -v gitleaks >/dev/null 2>&1; then
    echo "  Memory sync requires gitleaks for staged-content scanning (run ./setup.sh)." >&2
    git -C "$mem_repo" restore --staged -- "$memory_pathspec"
    return 1
  fi

  local staged_paths staged_path
  staged_paths="$(mktemp)" || {
    git -C "$mem_repo" restore --staged -- "$memory_pathspec"
    return 1
  }
  if ! git -C "$mem_repo" diff --cached --name-only -z -- "$memory_pathspec" > "$staged_paths"; then
    rm -f "$staged_paths"
    git -C "$mem_repo" restore --staged -- "$memory_pathspec"
    return 1
  fi
  while IFS= read -r -d '' staged_path; do
    if ! _memory_path_is_publishable "$staged_path"; then
      rm -f "$staged_paths"
      echo "  SECRET-LIKE MEMORY PATH STAGED — aborting memory sync." >&2
      git -C "$mem_repo" restore --staged -- "$memory_pathspec"
      return 1
    fi
    if ! _memory_blob_is_safe "$mem_repo" ":" "$staged_path"; then
      rm -f "$staged_paths"
      echo "  SECRET-LIKE MEMORY CONTENT DETECTED — aborting memory sync." >&2
      git -C "$mem_repo" restore --staged -- "$memory_pathspec"
      return 1
    fi
  done < "$staged_paths"
  rm -f "$staged_paths"

  if ! git -C "$mem_repo" commit -q --only \
      -m "auto: sync memory $(date +%Y-%m-%d)" -- "$memory_pathspec"; then
    git -C "$mem_repo" restore --staged -- "$memory_pathspec"
    echo "  Memory commit failed; nothing was pushed." >&2
    return 1
  fi
  _memory_snapshot_upstream "$mem_repo" || return 1
  upstream="$_memory_upstream_oid"
  remote="$_memory_remote"
  merge_ref="$_memory_merge_ref"
  validated_head="$_memory_validated_head"
  if ! _memory_range_is_safe "$mem_repo" "$upstream" "$memory_pathspec" "$validated_head"; then
    echo "  Memory commit stayed local because its committed history failed validation." >&2
    return 1
  fi
  if ! _memory_push_upstream "$mem_repo" "$validated_head" "$remote" \
      "$merge_ref" "$upstream"; then
    echo "  Memory push failed; the local commit remains pending." >&2
    return 1
  fi
  echo "  Memory saved."
}

# Validate critical claude-memory symlinks before launching Claude
# Fast check: just tests the 4 most important symlinks exist and aren't broken
_check_critical_symlinks() {
  local broken=0
  for f in "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md"; do
    if [ ! -L "$f" ]; then
      echo "WARNING: $f is not a symlink (expected symlink from claude-memory)"
      broken=1
    elif [ ! -e "$f" ]; then
      echo "WARNING: $f is a broken symlink -> $(readlink "$f")"
      broken=1
    fi
  done
  if [ "$broken" -eq 1 ]; then
    echo "Critical symlinks broken — attempting auto-repair..."
    if [ -f "$(_dev_dir)/claude-memory/bootstrap.sh" ]; then
      bash "$(_dev_dir)/claude-memory/bootstrap.sh" && echo "Repair complete." || echo "Repair failed — run bootstrap.sh manually."
    elif [ -f "$(_dev_dir)/dotfiles/setup.sh" ]; then
      bash "$(_dev_dir)/dotfiles/setup.sh" --repair && echo "Repair complete." || echo "Repair failed — run setup.sh --repair manually."
    else
      echo "No repair script found. Run setup.sh or bootstrap.sh manually."
    fi
  fi
}

# Shared agent preflight: resume detection, project cd, and the "Syncing repos…"
# sequence (pull-all + a per-tool health check). Keep cc/cx/agy on this path so
# their machine-sync behavior cannot drift independently.
#   $1  — space-separated resume keywords (e.g. "--resume -r --continue -c")
#   $2  — health-check command run inside the sync block (e.g. "sync-memory")
#   $3… — the caller's original positional args ("$@")
# Runs in the caller's shell, so any `cd` persists. Communicates back through
# two globals the caller reads after the call:
#   _agent_resuming — 1 if a resume/session arg was detected (sync was skipped)
#   _agent_shifted  — 1 if $3 was a <project> dir the caller should `shift` out
#                     so it never reaches the tool as a positional prompt arg
_agent_preflight() {
  local resume_keys="$1" health_cmd="$2"
  shift 2

  local dev_dir
  dev_dir="$(_dev_dir)"

  # Detect resume-style invocation anywhere in the args. resume_keys is left
  # unquoted so it word-splits into the individual keywords to match against.
  _agent_resuming="${_agent_force_resuming:-0}"
  _agent_force_resuming=0
  local arg key arg_index=0 runtime_arg_index=1
  if [ -n "${1:-}" ] && [[ "$1" != -* ]] && [ -d "$dev_dir/$1" ]; then
    runtime_arg_index=2
  fi
  if [ "$_agent_resuming" -eq 0 ]; then
    for arg in "$@"; do
      arg_index=$((arg_index + 1))
      [ "$arg" = "--" ] && break
      for key in $resume_keys; do
        if [[ "$key" != -* ]] && [ "$arg_index" -ne "$runtime_arg_index" ]; then
          continue
        fi
        case "$key" in
          *=) [[ "$arg" == "$key"* ]] || continue ;;
          *) [ "$arg" = "$key" ] || continue ;;
        esac
        _agent_resuming=1
        break 2
      done
    done
  fi

  # If a project name was passed, cd into it (honored even when resuming) and
  # tell the caller to shift it out.
  _agent_shifted=0
  if [ -n "$1" ] && [[ "$1" != -* ]] && [ -d "$dev_dir/$1" ]; then
    cd "$dev_dir/$1" || return 1
    _agent_shifted=1
  elif [ "$_agent_resuming" -eq 0 ] && ! git rev-parse --is-inside-work-tree &>/dev/null; then
    # Not resuming and not in a git repo — default to dev directory
    cd "$dev_dir" || return 1
  fi

  if [ "$_agent_resuming" -eq 0 ]; then
    echo "Syncing repos..."
    if ! pull-all; then
      echo "Repository sync failed — resolve the pull error before launching the agent." >&2
      return 1
    fi
    echo ""
  fi
  if ! "$health_cmd"; then
    echo "Agent health check failed — repair the reported drift before launch." >&2
    return 1
  fi
  echo ""
}

# Launch Claude, syncing everything first
# Usage: cc                — launch from current dir (defaults to ~/dev if outside a git repo)
#        cc <project>       — cd into ~/dev/<project> first, then launch
#        cc --resume        — resume a session in the current dir (skips sync for fast path)
#        cc -c / --continue — continue most recent session in current dir (skips sync)
#        cc --resume <id>   — resume a specific session id (skips sync)
# Any --resume/-r/--continue/-c in the args triggers the quick-resume path:
# no repository pulls, but memory publication and runtime health still run.
# shellcheck disable=SC2120  # args come from interactive use, not in-file callers
cc() {
  # Quick critical symlink validation (fast — just 2 stat calls; cwd-independent,
  # so running it before the preflight cd is equivalent to running it after).
  _check_critical_symlinks

  # Shared preflight: resume detection, project cd, and the repo + memory sync.
  _agent_preflight "--resume --resume= -r --continue --continue= -c" \
    "_check_claude_launch_health" "$@" || return 1
  [ "$_agent_shifted" -eq 1 ] && shift
  local resuming="$_agent_resuming"

  # The preflight always runs --heal after any fresh repository pull (or
  # directly on resume), and propagates every remaining drift failure.

  # Heal plugin drift before the session loads its plugins — the pre-exec
  # analogue to --heal above. Because the install runs before `claude` starts,
  # the plugins take effect in the session we're about to launch (no restart).
  # Skip on resume: a resumed session can't reload plugins and we don't want a
  # network round-trip on every -r. sync-plugins.sh has a fast path that exits
  # silently when nothing is missing, so the common (no-drift) case is free.
  if [ "$resuming" -eq 0 ] && command -v claude >/dev/null 2>&1; then
    "$(_dev_dir)/dotfiles/claude/scripts/sync-plugins.sh" \
      || echo "⚠ plugin sync had failures — run claude/scripts/sync-plugins.sh" >&2
  fi

  # Preload architecture diagrams if the project has them.
  # Treated as untrusted content: requires .ai/diagrams/.trusted opt-in marker,
  # capped at 16 KB, and XML-fenced so a CLAUDE.md rule can recognize it.
  local diagram_args=()
  if [ -d ".ai/diagrams" ] && ls .ai/diagrams/*.md &>/dev/null; then
    if [ ! -f ".ai/diagrams/.trusted" ]; then
      echo "# diagram preload skipped (no .ai/diagrams/.trusted marker)" >&2
    else
      local diagrams=""
      local total_bytes=0
      local cap=16384
      local skipped_size=0
      for f in .ai/diagrams/*.md; do
        local chunk
        chunk="<untrusted_diagram source=\"$f\">"$'\n'"$(cat "$f")"$'\n'"</untrusted_diagram>"$'\n'
        total_bytes=$(( total_bytes + ${#chunk} ))
        if [ "$total_bytes" -gt "$cap" ]; then
          skipped_size=1
          break
        fi
        diagrams+="$chunk"
      done
      if [ "$skipped_size" -eq 1 ]; then
        echo "# diagram preload skipped (content exceeds ${cap}-byte cap)" >&2
      elif [ -n "$diagrams" ]; then
        diagram_args=(--append-system-prompt "$diagrams")
      fi
    fi
  fi

  # Set terminal tab color from .claude-color if present
  if [ -f ".claude-color" ]; then
    local hex
    hex=$(head -1 .claude-color | tr -d '[:space:]#')
    if [[ "$hex" =~ ^[0-9a-fA-F]{6}$ ]]; then
      local r=$((16#${hex:0:2})) g=$((16#${hex:2:2})) b=$((16#${hex:4:2}))
      # Windows Terminal tab color (OSC 9;9)
      printf '\033]9;9;rgb(%d,%d,%d)\033\\' "$r" "$g" "$b"
    fi
  fi

  claude --remote-control --chrome "${diagram_args[@]}" "$@"

  # Reset tab color on exit
  printf '\033]9;9;\033\\' 2>/dev/null
}

# Launch Codex with the same project-selection ergonomics as cc, but without
# touching Claude memory or ~/.claude health checks.
# Usage: cx                 — launch from current dir (defaults to ~/dev outside git)
#        cx <project>        — cd into ~/dev/<project> first, then launch
#        cx resume|fork ...  — resume/fork without repo sync
_codex_with_timeout() {
  local timeout_seconds="$1" rc started
  shift
  started=$SECONDS

  local timeout_bin
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  else
    return 125
  fi

  # Let timeout own the child's process group so its TERM/KILL escalation
  # reaches ordinary descendants. Session-escaping children are handled by
  # the bounded capture in _codex_remote_run.
  "$timeout_bin" --kill-after=1s "${timeout_seconds}s" "$@" && return 0
  rc=$?
  # GNU timeout exits 137 when its KILL escalation was needed. Normalize that
  # to the documented deadline status consumed by the launcher.
  if [ "$rc" -eq 137 ] && [ "$((SECONDS - started))" -ge "$timeout_seconds" ]; then
    return 124
  fi
  return "$rc"
}

_codex_remote_run() (
  local timeout_seconds="$1" output_file rc
  local -a pipeline_status
  shift
  output_file="$(mktemp)" || return 125
  trap 'rm -f "$output_file"' EXIT

  # A separately timed collector bounds both retained output and how long an
  # escaped child may hold the pipeline open. Closing that pipe stops further
  # capture without imposing a file-size limit on Codex's own state writes.
  _codex_with_timeout "$timeout_seconds" codex "$@" 2>&1 \
    | _codex_with_timeout "$timeout_seconds" tail -c 8192 > "$output_file"
  pipeline_status=("${PIPESTATUS[@]}")
  rc="${pipeline_status[0]}"
  if [ "$rc" -ne 0 ]; then
    command cat "$output_file"
  fi
  return "$rc"
)

_codex_remote_is_stale_socket_failure() {
  local failure="$1"
  grep -Fq 'app server did not become ready' <<< "$failure" \
    && grep -Fq 'app-server-control.sock' <<< "$failure" \
    && grep -Fq 'No such file or directory' <<< "$failure"
}

_codex_remote_identity() {
  local action="$1"
  local pid_file="$HOME/.codex/app-server-daemon/app-server-updater.pid"
  local identity_file="$HOME/.codex/app-server-daemon/app-server-updater.identity.json"
  local helper
  helper="$(_dev_dir)/dotfiles/codex/remote_control_recover.py"

  command -v python3 >/dev/null 2>&1 || return 1
  [ -f "$helper" ] || return 1
  _codex_with_timeout 7 python3 "$helper" "$action" "$pid_file" "$identity_file" \
    >/dev/null 2>&1
}

_codex_remote_snapshot_updater() {
  _codex_remote_identity snapshot
}

_codex_remote_recover_stale_updater() {
  _codex_remote_identity recover
}

_codex_ensure_remote_control() {
  local timeout_seconds=15 stop_timeout_seconds=8 failure rc

  if failure="$(_codex_remote_run "$timeout_seconds" remote-control start --json 2>&1)"; then
    _codex_remote_snapshot_updater || true
    return 0
  else
    rc=$?
  fi

  if [ "$rc" -eq 125 ]; then
    echo "⚠ Codex Remote Control auto-start skipped — no timeout command is available." >&2
    return 0
  fi

  if _codex_remote_is_stale_socket_failure "$failure" \
    && _codex_remote_recover_stale_updater; then
    _codex_remote_run "$stop_timeout_seconds" remote-control stop --json \
      >/dev/null 2>&1 || true
    if failure="$(_codex_remote_run "$timeout_seconds" remote-control start --json 2>&1)"; then
      _codex_remote_snapshot_updater || true
      echo "⚠ Codex Remote Control recovered a stale managed daemon." >&2
      return 0
    else
      rc=$?
    fi
  fi

  if [ "$rc" -eq 124 ]; then
    echo "⚠ Codex Remote Control timed out after $timeout_seconds seconds — mobile access is off for this session." >&2
  else
    echo "⚠ Codex Remote Control unavailable (exit $rc) — mobile access is off for this session." >&2
  fi
  # Remote Control stderr can contain relay URLs, pairing codes, or tokens.
  # Offer a direct diagnostic command without trying to redact unknown formats.
  echo "  Run: codex remote-control start --json" >&2
}

cx() {
  _agent_force_resuming=0
  _codex_is_resume_invocation "$@" && _agent_force_resuming=1
  # Shared preflight: resume/fork detection, project cd, and the repo sync +
  # Codex config health check (no Claude memory or ~/.claude healing).
  _agent_preflight "" "_check_codex_launch_health" "$@" || return 1
  [ "$_agent_shifted" -eq 1 ] && shift

  # Reapply portable private defaults after the repo sync without replacing the
  # machine-local config that holds project trust and integration settings.
  local codex_memory_bootstrap
  codex_memory_bootstrap="${CODEX_MEMORY_REPO:-$(_dev_dir)/codex-memory}/bootstrap.sh"
  if [ -f "$codex_memory_bootstrap" ] \
    && ! bash "$codex_memory_bootstrap"; then
    echo "⚠ Codex private defaults could not be applied — continuing with the existing local config." >&2
  fi

  # Idempotently restore mobile access after a reboot or WSL shutdown, but only
  # on hosts where the user already enabled it. Pairing persists in Codex state,
  # so reconnecting does not create a new pairing code on every launch.
  local remote_settings="$HOME/.codex/app-server-daemon/settings.json"
  if [ -f "$remote_settings" ] \
    && jq -e '.remoteControlEnabled == true' "$remote_settings" >/dev/null 2>&1; then
    # Remote Control is optional: bounded recovery failures never prevent the
    # local CLI from launching.
    _codex_ensure_remote_control
  fi

  codex --strict-config "$@"
}

# Launch Antigravity with the same project-selection and sync ergonomics as
# cc/cx. `command` bypasses this function and resolves the installed agy binary.
# Usage: agy                         — launch from the current project
#        agy <project>               — cd into ~/dev/<project> first
#        agy --continue|-c           — continue without the sync preflight
#        agy --conversation <id>     — resume by id without the sync preflight
agy() {
  _agent_preflight "--continue --continue= -continue -continue= -c --conversation --conversation= -conversation -conversation=" \
    "_check_antigravity_launch_health" "$@" || return 1
  [ "$_agent_shifted" -eq 1 ] && shift

  command agy "$@"
}

codex-update() {
  codex update
}

# Update dotfiles: pull latest and re-run setup
dotfiles-update() {
  local dotfiles_dir
  dotfiles_dir="$(_dev_dir)/dotfiles"
  if [ ! -d "$dotfiles_dir/.git" ]; then
    echo "Dotfiles repo not found at $dotfiles_dir"
    return 1
  fi
  echo "Pulling latest dotfiles..."
  git -C "$dotfiles_dir" pull --ff-only || { echo "Pull failed — resolve manually."; return 1; }
  echo "Re-running setup..."
  bash "$dotfiles_dir/setup.sh"
}

# ─── gh wrapper: auto-bootstrap auto-hygiene on new repos ────────────
# Wraps `gh repo create` and `gh repo clone` so the canonical 8 auto-hygiene
# settings (delete-branch-on-merge, allow-auto-merge, squash-only, etc.) are
# applied the moment a new repo touches your filesystem. Pass-through for all
# other gh subcommands.
gh() {
  local bootstrap
  bootstrap="$(_dev_dir)/dotfiles/gh-bootstrap.sh"
  case "${1:-}" in
    repo)
      case "${2:-}" in
        create)
          command gh "$@" || return $?
          # Determine the slug from args; --source means a local path with origin remote
          local slug=""
          local i=0 a
          for a in "$@"; do
            i=$((i+1))
            if [[ "$i" -ge 3 && "$a" != -* && "$a" != "--"* ]]; then
              slug="$a"; break
            fi
          done
          if [[ -z "$slug" ]]; then
            slug="$(command gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
          fi
          [[ -n "$slug" && -x "$bootstrap" ]] && "$bootstrap" "$slug" || true
          ;;
        clone)
          command gh "$@" || return $?
          # Last positional arg without a leading dash is the dest dir or slug
          local dest=""
          local a
          for a in "$@"; do
            [[ "$a" != -* ]] && dest="$a"
          done
          local target_slug="$dest"
          if [[ -d "$dest" ]]; then
            target_slug="$(git -C "$dest" remote get-url origin 2>/dev/null | sed -E 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|; s|.*[:/]([^/:]+/[^/]+)$|\1|')"
          fi
          [[ -n "$target_slug" && -x "$bootstrap" ]] && "$bootstrap" "$target_slug" || true
          ;;
        *) command gh "$@" ;;
      esac
      ;;
    *) command gh "$@" ;;
  esac
}

# ─── Git worktree shortcuts (Boris's #1 productivity tip) ────────────
# Quick jump to worktrees: za, zb, zc, zd, ze
# Create them with: git worktree add ../project-a -b feature-a
alias za='cd ../$(basename "$PWD")-a 2>/dev/null || echo "Worktree -a not found. Create with: git worktree add ../$(basename "$PWD")-a -b branch-name"'
alias zb='cd ../$(basename "$PWD")-b 2>/dev/null || echo "Worktree -b not found. Create with: git worktree add ../$(basename "$PWD")-b -b branch-name"'
alias zc='cd ../$(basename "$PWD")-c 2>/dev/null || echo "Worktree -c not found. Create with: git worktree add ../$(basename "$PWD")-c -b branch-name"'
alias zd='cd ../$(basename "$PWD")-d 2>/dev/null || echo "Worktree -d not found. Create with: git worktree add ../$(basename "$PWD")-d -b branch-name"'
alias ze='cd ../$(basename "$PWD")-e 2>/dev/null || echo "Worktree -e not found. Create with: git worktree add ../$(basename "$PWD")-e -b branch-name"'
alias z0='cd "$(git rev-parse --show-toplevel 2>/dev/null)" || echo "Not in a git repo"'

# Worktree management
alias gwl='git worktree list'
alias gwa='git worktree add'
alias gwr='git worktree remove'

# Quick Claude in a new worktree (uses cc for full sync + tab color)
wt-claude() {
  local name="${1:?Usage: wt-claude <name> [branch]}"
  local branch="${2:-$name}"
  local base
  base="$(git rev-parse --show-toplevel)"
  local wt_path="${base}-${name}"
  if [ ! -d "$wt_path" ]; then
    git worktree add "$wt_path" -b "$branch" 2>/dev/null || git worktree add "$wt_path" "$branch"
  fi
  echo "Starting Claude in worktree: $wt_path"
  (cd "$wt_path" && cc)
}

# ─── Multi-session: Windows Terminal integration ───────────────────
# These commands let you spin up Claude sessions in new panes/tabs
# without leaving your current terminal. Requires Windows Terminal (wt.exe).

# List available projects in your dev directory
projects() {
  local dev_dir
  dev_dir="$(_dev_dir)"
  echo "Projects in $dev_dir:"
  for repo in "$dev_dir"/*/; do
    [ -d "$repo/.git" ] && printf "  %s\n" "$(basename "$repo")"
  done
}

# Reject project names that aren't a plain slug before they reach wt.exe/wsl.exe
# — mirrors the PowerShell helper's Test-SafeProjectName. Blocks path traversal
# (../) and shell-metacharacter names even though the value is passed as a
# positional arg.
_valid_project_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# Open project in a new split pane
# Usage: cc-pane <project>        (vertical split, default)
#        cc-pane <project> -H     (horizontal split)
cc-pane() {
  if ! command -v wt.exe &>/dev/null; then
    echo "wt.exe not found — requires Windows Terminal on WSL"
    return 1
  fi
  local project="$1"
  local split_flag="${2:--V}"
  if [ -z "$project" ]; then
    echo "Usage: cc-pane <project> [-H|-V]"
    echo ""
    projects
    return 1
  fi
  if ! _valid_project_name "$project"; then
    echo "Invalid project name: $project"
    return 1
  fi
  local dev_dir
  dev_dir="$(_dev_dir)"
  if [ ! -d "$dev_dir/$project" ]; then
    echo "Project not found: $dev_dir/$project"
    echo ""
    projects
    return 1
  fi
  wt.exe -w 0 sp "$split_flag" -- wsl.exe bash -ic 'cc "$1"' _ "$project"
}

# Open project in a new Windows Terminal tab
cc-tab() {
  if ! command -v wt.exe &>/dev/null; then
    echo "wt.exe not found — requires Windows Terminal on WSL"
    return 1
  fi
  local project="$1"
  if [ -z "$project" ]; then
    echo "Usage: cc-tab <project>"
    echo ""
    projects
    return 1
  fi
  if ! _valid_project_name "$project"; then
    echo "Invalid project name: $project"
    return 1
  fi
  local dev_dir
  dev_dir="$(_dev_dir)"
  if [ ! -d "$dev_dir/$project" ]; then
    echo "Project not found: $dev_dir/$project"
    echo ""
    projects
    return 1
  fi
  wt.exe -w 0 nt -- wsl.exe bash -ic 'cc "$1"' _ "$project"
}

# Open multiple projects, each in its own tab
# Usage: cc-multi dotfiles atlas stringer
cc-multi() {
  if [ $# -eq 0 ]; then
    echo "Usage: cc-multi <project1> <project2> ..."
    echo ""
    projects
    return 1
  fi
  for project in "$@"; do
    cc-tab "$project"
  done
}

# Show active Claude sessions and their working directories.
# pgrep -x matches the claude binary by exact process name — the old
# "node.*claude" pattern matched plugin broker processes (paths containing
# .claude/) instead of the actual sessions now that claude ships native.
sessions() {
  local found=0
  while IFS= read -r pid; do
    local cwd
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || continue
    if [ $found -eq 0 ]; then
      echo "Active Claude sessions:"
      echo "────────────────────────────────────────"
      found=1
    fi
    printf "  PID %-7s  %s\n" "$pid" "$cwd"
  done < <(pgrep -x claude 2>/dev/null)
  [ $found -eq 0 ] && echo "No active Claude sessions"
}

# Claude session spend summary. Data: one tiny TSV per session under
# ~/.claude/ledger/ (date, project, cost USD, minutes), written by
# statusline.sh as sessions run. `ledger` shows per-day/project totals;
# `ledger --prune` drops entries older than 90 days.
ledger() {
  local dir="$HOME/.claude/ledger"
  [ -d "$dir" ] && compgen -G "$dir/*.tsv" >/dev/null || { echo "No ledger data yet — it accrues as sessions run."; return 0; }
  if [ "${1:-}" = "--prune" ]; then
    find "$dir" -name '*.tsv' -mtime +90 -delete
    echo "Pruned ledger entries older than 90 days."
    return 0
  fi
  awk -F'\t' '{ key = $1 "  " $2; cost[key] += $3; mins[key] += $4 }
    END { for (k in cost) printf "  %s  $%.2f  (%d min)\n", k, cost[k], mins[k] }' \
    "$dir"/*.tsv | sort
  awk -F'\t' '{ total += $3 } END { printf "  ─────\n  Total: $%.2f across %d sessions\n", total, NR }' "$dir"/*.tsv
}

# WSL: open URLs in Windows Chrome
export BROWSER="/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
# WSL: force-enable Claude in Chrome
export CLAUDE_CODE_ENABLE_CFC=1
# Extend prompt cache TTL from 5m to 1h (v2.1.108+) for long agent sessions
export ENABLE_PROMPT_CACHING_1H=1
