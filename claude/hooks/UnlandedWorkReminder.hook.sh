#!/usr/bin/env bash
# UnlandedWorkReminder.hook.sh — warn or block when ending a turn with unlanded work.
#
# Prevents sessions and delegated lanes from abandoning dirty edits or local
# commits in a linked worktree without landing or handing off.
#
# The output is status only (checkout kind, dirty file count, and unpushed commit
# count). It never emits imperative instructions to commit, push, clean, or
# stash, so pre-existing third-party work and task-specific delivery
# authorization remain governed by the session's own instructions.
#
# Modes:
#   - Default (interactive): prints an advisory `systemMessage` when dirty files
#     or unpushed linked-worktree commits exist.
#   - Autonomous (`CLAUDE_AUTONOMOUS_RUN=1`):
#     returns `{"decision":"block","reason":...}` for up to 3 stop attempts per
#     session and checkout, then degrades to an advisory `systemMessage` until that checkout is clean.
#
# TRIGGER: Stop, SubagentStop
# TEST: claude/scripts/tests/unlanded-work-reminder.test.sh

set -uo pipefail

input="{}"
if [ ! -t 0 ]; then
  raw="$(cat 2>/dev/null || true)"
  [ -n "$raw" ] && input="$raw"
fi

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

hook_cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null || true)"
session_raw="$(jq -r '.session_id // "default"' <<<"$input" 2>/dev/null || true)"
session="$(printf '%s' "$session_raw" | tr -cd 'A-Za-z0-9_-')"
[ -n "$session" ] || session="default"

if [ -n "$hook_cwd" ]; then
  cd "$hook_cwd" 2>/dev/null || exit 0
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

state_dir="${XDG_RUNTIME_DIR:-$HOME/.cache}/unlanded-work-stop"

status_tmp=""
scratch_dir=""
trap 'rm -rf "${status_tmp:-}" "${scratch_dir:-}"' EXIT

resolve_push_remote() {
  local branch="$1" val="" sole_remote=""
  for key in "branch.${branch}.pushRemote" "remote.pushDefault" "branch.${branch}.remote"; do
    val="$(git -C "$repo_root" config --get "$key" 2>/dev/null || true)"
    if [ -n "$val" ] && [ "$val" != "." ]; then
      printf '%s\n' "$val"
      return 0
    fi
  done
  if git -C "$repo_root" remote get-url --push origin >/dev/null 2>&1; then
    printf 'origin\n'
    return 0
  fi
  sole_remote="$(git -C "$repo_root" remote 2>/dev/null | awk 'NF { c++; r=$0 } END { if (c == 1) print r }')"
  if [ -n "$sole_remote" ]; then
    printf '%s\n' "$sole_remote"
    return 0
  fi
  printf 'origin\n'
}

count_unpushed_from_live_push_url() {
  local push_url="$1" head_oid="$2"
  local count="" rc=0 obj_format=""
  local -a init_args=(--bare -q)

  [ -n "$common_dir_abs" ] && [ -d "$common_dir_abs/objects" ] || return 1
  case "$common_dir_abs" in
    *$'\n'*) return 1 ;;
  esac

  obj_format="$(git -C "$repo_root" rev-parse --show-object-format 2>/dev/null || true)"
  if [ -n "$obj_format" ]; then
    init_args+=(--object-format="$obj_format")
  fi

  scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/unlanded-remote.XXXXXX" 2>/dev/null || true)"
  [ -n "$scratch_dir" ] || return 1

  if ! git init "${init_args[@]}" "$scratch_dir" 2>/dev/null \
    || ! printf '%s\n' "$common_dir_abs/objects" > "$scratch_dir/objects/info/alternates" 2>/dev/null; then
    rm -rf "$scratch_dir" 2>/dev/null || true
    scratch_dir=""
    return 1
  fi

  python3 - "$scratch_dir" "$push_url" "$repo_root" <<'PY' >/dev/null 2>&1 || rc=$?
import os
import signal
import subprocess
import sys

scratch_dir, push_url, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]

cfg_proc = subprocess.run(
    ["git", "-C", repo_root, "config", "--includes", "--list", "--null"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=False,
)
if cfg_proc.returncode != 0:
    sys.exit(2)

skip_exact = {"core.bare", "core.worktree", "core.repositoryformatversion"}
skip_prefixes = ("extensions.", "include.", "includeif.")
pairs = []
has_ssh_command = bool(os.environ.get("GIT_SSH_COMMAND") or os.environ.get("GIT_SSH"))

for entry in cfg_proc.stdout.split(b"\0"):
    if not entry:
        continue
    k_b, sep, v_b = entry.partition(b"\n")
    k = k_b.decode("utf-8", errors="surrogateescape")
    k_low = k.lower()
    v = v_b.decode("utf-8", errors="surrogateescape") if sep else "true"
    if k_low in skip_exact or k_low.startswith(skip_prefixes):
        continue
    if k_low == "core.sshcommand" and v:
        has_ssh_command = True
    pairs.append((k, v))

env = dict(
    os.environ,
    GIT_TERMINAL_PROMPT="0",
    GIT_ASKPASS="/bin/false",
    SSH_ASKPASS="/bin/false",
    SSH_ASKPASS_REQUIRE="never",
    GCM_INTERACTIVE="never",
    GIT_CONFIG_GLOBAL="/dev/null",
    GIT_CONFIG_NOSYSTEM="1",
    GIT_CONFIG_COUNT=str(len(pairs)),
)
env.pop("GIT_CONFIG_PARAMETERS", None)
for idx, (k, v) in enumerate(pairs):
    env[f"GIT_CONFIG_KEY_{idx}"] = k
    env[f"GIT_CONFIG_VALUE_{idx}"] = v

if not has_ssh_command:
    env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=1"

proc = None
try:
    proc = subprocess.Popen(
        [
            "git",
            "--git-dir",
            scratch_dir,
            "fetch",
            "-q",
            "--no-tags",
            "--",
            push_url,
            "+refs/heads/*:refs/remotes/live/*",
        ],
        cwd=repo_root,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
        start_new_session=True,
    )
    rc = proc.wait(timeout=2)
except subprocess.TimeoutExpired:
    rc = 124
except Exception:
    rc = 2
finally:
    if proc is not None and proc.pid:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except Exception:
            pass
        try:
            proc.wait(timeout=1)
        except Exception:
            pass
sys.exit(rc)
PY

  if [ "$rc" -eq 0 ]; then
    count="$(git --git-dir="$scratch_dir" rev-list --count "$head_oid" --not --glob='refs/remotes/live/*' 2>/dev/null)" || rc=1
  fi

  rm -rf "$scratch_dir" 2>/dev/null || true
  scratch_dir=""

  [ "$rc" -eq 0 ] && [ -n "$count" ] || return 1
  printf '%s\n' "$count"
}

git_dir_raw="$(git -C "$repo_root" rev-parse --git-dir 2>/dev/null || true)"
common_dir_raw="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || true)"
git_dir_abs=""
common_dir_abs=""
if [ -n "$git_dir_raw" ]; then
  git_dir_abs="$(cd "$repo_root" 2>/dev/null && cd -P "$git_dir_raw" 2>/dev/null && pwd || printf '%s' "$git_dir_raw")"
fi
if [ -n "$common_dir_raw" ]; then
  common_dir_abs="$(cd "$repo_root" 2>/dev/null && cd -P "$common_dir_raw" 2>/dev/null && pwd || printf '%s' "$common_dir_raw")"
fi

checkout_id="$(python3 - "${git_dir_abs:-$repo_root}" <<'PY' 2>/dev/null || true
import hashlib
import os
import sys

p = os.path.realpath(sys.argv[1])
print(hashlib.sha256(p.encode("utf-8", errors="surrogateescape")).hexdigest()[:16])
PY
)"
[ -n "$checkout_id" ] || checkout_id="default"
budget="$state_dir/${session}_${checkout_id}"

status_failed=0
status_tmp="$(mktemp "${TMPDIR:-/tmp}/unlanded-status.XXXXXX" 2>/dev/null || true)"
if [ -z "$status_tmp" ] \
  || ! git -C "$repo_root" status --porcelain -z -uall >"$status_tmp" 2>/dev/null; then
  status_failed=1
fi

dirty_count=0
if [ "$status_failed" -eq 0 ]; then
  while IFS= read -r -d '' entry; do
    dirty_count=$((dirty_count + 1))
    status_xy="${entry:0:2}"
    case "$status_xy" in
      R*|*R|C*|*C)
        IFS= read -r -d '' _orig_path || true
        ;;
    esac
  done < "$status_tmp"
fi

unpushed_count=0
is_linked=0

if [ -n "$git_dir_abs" ] && [ -n "$common_dir_abs" ] && [ "$git_dir_abs" != "$common_dir_abs" ]; then
  is_linked=1
  head_oid="$(git -C "$repo_root" rev-parse --verify HEAD 2>/dev/null || true)"
  if [ -n "$head_oid" ]; then
    remotes_list="$(git -C "$repo_root" remote 2>/dev/null || true)"
    if [ -z "$remotes_list" ]; then
      if ! unpushed_count="$(git -C "$repo_root" rev-list --count "$head_oid" 2>/dev/null)"; then
        unpushed_count=0
        status_failed=1
      fi
    else
      branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
      [ "$branch" != "HEAD" ] || branch=""
      remote_name="$(resolve_push_remote "$branch")"
      push_urls=""
      if [ -n "$remote_name" ] && [ "$remote_name" != "." ]; then
        push_urls="$(git -C "$repo_root" remote get-url --push --all "$remote_name" 2>/dev/null || true)"
      fi

      if [ -z "$push_urls" ]; then
        unpushed_count=0
        status_failed=1
      else
        max_unpushed=0
        while IFS= read -r push_url; do
          [ -n "$push_url" ] || continue
          if live_count="$(count_unpushed_from_live_push_url "$push_url" "$head_oid")"; then
            if [ "$live_count" -gt "$max_unpushed" ]; then
              max_unpushed="$live_count"
            fi
          else
            max_unpushed=0
            status_failed=1
            break
          fi
        done <<< "$push_urls"
        unpushed_count="$max_unpushed"
      fi
    fi
  fi
fi

reset_budget_locked() {
  [ -f "$budget" ] || return 0
  python3 - "$budget" <<'PY' 2>/dev/null || true
import fcntl
import os
import sys

fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.ftruncate(fd, 0)
finally:
    os.close(fd)
PY
}

increment_budget_locked() {
  python3 - "$budget" <<'PY' 2>/dev/null
import fcntl
import os
import sys

fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX)
    raw = os.read(fd, 64).decode("utf-8", errors="ignore").strip()
    prev = int(raw) if raw.isdigit() and len(raw) <= 6 else 0
    n = min(prev + 1, 999999)
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, f"{n}\n".encode("utf-8"))
    print(n)
finally:
    os.close(fd)
PY
}

if [ "$status_failed" -eq 0 ] && [ "$dirty_count" -eq 0 ] && [ "$unpushed_count" -eq 0 ]; then
  reset_budget_locked
  exit 0
fi

summary="primary checkout"
[ "$is_linked" -eq 1 ] && summary="linked worktree"
if [ "$status_failed" -eq 1 ]; then
  details="git inspection failed (${dirty_count} dirty file(s), ${unpushed_count} unpushed commit(s))"
else
  details="${dirty_count} dirty file(s), ${unpushed_count} unpushed commit(s)"
fi

autonomous=0
if [ "${CLAUDE_AUTONOMOUS_RUN:-0}" = "1" ]; then
  autonomous=1
fi

if [ "$autonomous" -eq 1 ]; then
  if ! mkdir -p "$state_dir" 2>/dev/null || ! chmod 700 "$state_dir" 2>/dev/null; then
    jq -nc --arg m "[UnlandedWorkReminder] ${summary}: ${details}." \
      '{"systemMessage":$m}'
    exit 0
  fi
  n="$(increment_budget_locked)"
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    jq -nc --arg m "[UnlandedWorkReminder] ${summary}: ${details}." \
      '{"systemMessage":$m}'
    exit 0
  fi
  if [ "$n" -le 3 ]; then
    jq -nc --arg r "[UnlandedWorkReminder] ${summary}: ${details} (stop check ${n}/3)." \
      '{"decision":"block","reason":$r}'
    exit 0
  fi
  jq -nc --arg m "[UnlandedWorkReminder] ${summary}: ${details} (stop check cap 3/3 reached)." \
    '{"systemMessage":$m}'
  exit 0
fi

jq -nc --arg m "[UnlandedWorkReminder] ${summary}: ${details}." \
  '{"systemMessage":$m}'
exit 0
