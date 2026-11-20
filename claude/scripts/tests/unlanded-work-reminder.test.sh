#!/usr/bin/env bash
# unlanded-work-reminder.test.sh — fixture tests for UnlandedWorkReminder.hook.sh.
# Exercises clean primary checkout, fork pushDefault + pushurl resolution, dirty
# primary checkout, linked worktree with unpushed vs explicit-URL pushed commits,
# local-main linked worktree without remotes, corrupt index fail-closed handling,
# and 3-attempt block + advisory fallback in CLAUDE_AUTONOMOUS_RUN=1 mode.
# Run directly; exit 1 on failure.
set -uo pipefail

# shellcheck source=claude/scripts/checker-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../checker-lib.sh"
SCRIPT_DIR="$(resolve_script_path "${BASH_SOURCE[0]}")"
HOOK="$SCRIPT_DIR/../../hooks/UnlandedWorkReminder.hook.sh"

pass=0
failed=0
ok()   { pass=$((pass + 1));   echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

command -v jq >/dev/null 2>&1 || { echo "unlanded-work-reminder: jq is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "unlanded-work-reminder: git is required" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Isolate runtime counter directory so tests never touch live user state.
XDG_RUNTIME_DIR="$T/runtime"
export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR"

# Seed bare origin + primary clone + initial commit on main.
git init --bare -q "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo"
git -C "$T/repo" checkout -q -B main
git -C "$T/repo" config user.email "test@example.com"
git -C "$T/repo" config user.name "Test User"
printf 'init\n' > "$T/repo/README.md"
git -C "$T/repo" add README.md
git -C "$T/repo" commit -q -m "chore: init"
git -C "$T/repo" push -q -u origin main

run_hook() {
  local dir="$1" sid="${2:-sess-1}"
  jq -nc --arg cwd "$dir" --arg sid "$sid" '{"cwd":$cwd,"session_id":$sid}' | "$HOOK"
}

# 1. Clean primary checkout -> silent.
out="$(run_hook "$T/repo" "s1")"
if [ -z "$out" ]; then
  ok "clean primary checkout emits nothing"
else
  fail "clean primary checkout expected empty output, got: $out"
fi

# 2. Fork workflow: remote.pushDefault + separate remote.<name>.pushurl resolved for pushed check.
git init --bare -q "$T/upstream.git"
git init --bare -q "$T/push-dest.git"
git -C "$T/repo" remote add upstream "$T/upstream.git"
git -C "$T/repo" push -q upstream main
git -C "$T/repo" remote set-url --push origin "$T/push-dest.git"
git -C "$T/repo" config remote.pushDefault origin
git -C "$T/repo" worktree add -q -b feat/wt-pushdefault "$T/wt-pd" upstream/main
git -C "$T/wt-pd" config user.email "test@example.com"
git -C "$T/wt-pd" config user.name "Test User"
printf 'pushdefault\n' > "$T/wt-pd/pd.txt"
git -C "$T/wt-pd" add pd.txt
git -C "$T/wt-pd" commit -q -m "feat: pushDefault + pushurl"
git -C "$T/wt-pd" push -q "$T/push-dest.git" HEAD:refs/heads/feat/wt-pushdefault
out_pd="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt-pd" "s2-pd")"
if [ -z "$out_pd" ]; then
  ok "remote.pushDefault and remote.<name>.pushurl push recognized as landed"
else
  fail "pushDefault/pushurl commit still reported unpushed: $out_pd"
fi
git -C "$T/repo" worktree remove --force "$T/wt-pd" >/dev/null 2>&1
git -C "$T/repo" config --unset remote.pushDefault
git -C "$T/repo" remote set-url --push --delete origin "$T/push-dest.git" 2>/dev/null || git -C "$T/repo" remote set-url --push origin "$T/origin.git"
git -C "$T/repo" remote remove upstream

# 3. Dirty primary checkout -> advisory systemMessage in interactive mode.
printf 'dirty\n' > "$T/repo/untracked.txt"
out="$(CLAUDE_AUTONOMOUS_RUN=0 run_hook "$T/repo" "s2")"
if grep -q '"systemMessage"' <<<"$out" && grep -q '1 dirty file(s)' <<<"$out"; then
  ok "dirty primary checkout emits advisory systemMessage"
else
  fail "dirty primary checkout output wrong: $out"
fi
rm -f "$T/repo/untracked.txt"

# 4. Linked worktree with unpushed commit -> advisory systemMessage in interactive mode.
git -C "$T/repo" worktree add -q -b feat/wt-test "$T/wt" main
git -C "$T/wt" config user.email "test@example.com"
git -C "$T/wt" config user.name "Test User"
printf 'feature\n' > "$T/wt/feature.txt"
git -C "$T/wt" add feature.txt
git -C "$T/wt" commit -q -m "feat: add feature"

out="$(CLAUDE_AUTONOMOUS_RUN=0 run_hook "$T/wt" "s3")"
if grep -q '"systemMessage"' <<<"$out" && grep -q '1 unpushed commit(s)' <<<"$out"; then
  ok "linked worktree with unpushed commit warns in interactive mode"
else
  fail "linked worktree interactive warning wrong: $out"
fi

# 5. Autonomous mode -> blocks attempts 1..3, then degrades to systemMessage on 4.
a1="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s4")"
a2="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s4")"
a3="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s4")"
a4="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s4")"
if grep -q '"decision":"block"' <<<"$a1" && grep -q 'stop check 1/3' <<<"$a1" \
  && grep -q '"decision":"block"' <<<"$a2" && grep -q 'stop check 2/3' <<<"$a2" \
  && grep -q '"decision":"block"' <<<"$a3" && grep -q 'stop check 3/3' <<<"$a3" \
  && grep -q '"systemMessage"' <<<"$a4" && grep -q 'stop check cap 3/3 reached' <<<"$a4" \
  && ! grep -q '"decision":"block"' <<<"$a4"; then
  ok "autonomous mode blocks attempts 1-3 and degrades to systemMessage at cap"
else
  fail "autonomous mode sequence wrong: a1=$a1 a2=$a2 a3=$a3 a4=$a4"
fi

# 6. Linked worktree pushed to upstream -> silent and clears any counter.
git -C "$T/wt" push -q -u origin feat/wt-test
out="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s4")"
if [ -z "$out" ]; then
  ok "pushed linked worktree with clean tree emits nothing"
else
  fail "pushed linked worktree expected empty output, got: $out"
fi

# 6b. Live remote deletion / unfetched force-push overrides stale local tracking ref.
orig_sha="$(git -C "$T/origin.git" rev-parse refs/heads/feat/wt-test)"
if ! git -C "$T/origin.git" branch -D feat/wt-test >/dev/null; then
  fail "test setup failed deleting remote branch feat/wt-test"
fi
out_deleted="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s6b-del")"
unfetched_sha=""
if ! unfetched_sha="$(git -C "$T/origin.git" -c user.name="Test User" -c user.email="test@example.com" commit-tree "$(git -C "$T/origin.git" rev-parse "${orig_sha}^{tree}")" -m "remote force-push")" \
  || [ -z "$unfetched_sha" ] \
  || ! git -C "$T/origin.git" update-ref refs/heads/feat/wt-test "$unfetched_sha" \
  || [ "$(git -C "$T/origin.git" rev-parse refs/heads/feat/wt-test)" != "$unfetched_sha" ]; then
  fail "test setup failed creating unfetched replacement commit on origin"
fi
out_replaced="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s6b-rep")"
git -C "$T/origin.git" update-ref refs/heads/feat/wt-test "$orig_sha"
if grep -q '"decision":"block"' <<<"$out_deleted" && grep -q '1 unpushed commit(s)' <<<"$out_deleted" \
  && grep -q '"decision":"block"' <<<"$out_replaced" && grep -q '1 unpushed commit(s)' <<<"$out_replaced"; then
  ok "deleted or force-pushed remote branch overrides stale local tracking ref"
else
  fail "stale tracking ref concealed remote branch deletion/replacement: del=$out_deleted rep=$out_replaced"
fi

# 7. Linked worktree branched from origin/main and pushed via explicit URL refspec without -u -> silent.
git -C "$T/repo" worktree add -q -b feat/wt-url-push "$T/wt2" origin/main
git -C "$T/wt2" config user.email "test@example.com"
git -C "$T/wt2" config user.name "Test User"
printf 'url push\n' > "$T/wt2/url.txt"
git -C "$T/wt2" add url.txt
git -C "$T/wt2" commit -q -m "feat: url push test"
git -C "$T/wt2" push -q "$T/origin.git" HEAD:refs/heads/feat/wt-url-push
out="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt2" "s7")"
if [ -z "$out" ]; then
  ok "linked worktree pushed via explicit URL refspec without -u emits nothing"
else
  fail "explicit URL refspec push still flagged as unpushed: $out"
fi

# 8. Linked worktree tracking local main (branch.*.remote = .) with unpushed commit still warns/blocks.
git -C "$T/repo" worktree add -q -b feat/wt-local-track "$T/wt3" main
git -C "$T/wt3" config user.email "test@example.com"
git -C "$T/wt3" config user.name "Test User"
git -C "$T/wt3" branch -q --set-upstream-to=main
printf 'localtrack\n' > "$T/wt3/local.txt"
git -C "$T/wt3" add local.txt
git -C "$T/wt3" commit -q -m "feat: local tracking test"
out_lt="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt3" "s8")"
if grep -q '"decision":"block"' <<<"$out_lt" && grep -q '1 unpushed commit(s)' <<<"$out_lt"; then
  ok "linked worktree tracking local main does not treat '.' as a remote"
else
  fail "local upstream branch hid unpushed commits: $out_lt"
fi

# 9. Linked worktree checked out on local main in remoteless repo still reports commits.
git init -q "$T/noremo"
git -C "$T/noremo" checkout -q -B main
git -C "$T/noremo" config user.email "test@example.com"
git -C "$T/noremo" config user.name "Test User"
printf 'noremo\n' > "$T/noremo/a.txt"
git -C "$T/noremo" add a.txt
git -C "$T/noremo" commit -q -m "chore: noremo init"
git -C "$T/noremo" checkout -q --detach
git -C "$T/noremo" worktree add -q "$T/noremo-wt" main
out_nr="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/noremo-wt" "s9")"
if grep -q '"decision":"block"' <<<"$out_nr" && grep -q '1 unpushed commit(s)' <<<"$out_nr"; then
  ok "remoteless linked worktree on local main counts local commits as unpushed"
else
  fail "remoteless linked worktree on main concealed commits: $out_nr"
fi

# 10. Corrupt index causes git status failure -> fail closed instead of silent clean exit.
cp "$T/repo/.git/index" "$T/repo-index.bak"
printf 'bad' > "$T/repo/.git/index"
out_corrupt="$(CLAUDE_AUTONOMOUS_RUN=0 run_hook "$T/repo" "s10")"
mv "$T/repo-index.bak" "$T/repo/.git/index"
if grep -q '"systemMessage"' <<<"$out_corrupt" && grep -q 'git inspection failed' <<<"$out_corrupt"; then
  ok "corrupt index fails closed with inspection failure warning"
else
  fail "corrupt index exited silently or lacked warning: $out_corrupt"
fi

# 11. Rename-on-push (local branch differs from pushed remote branch) emits nothing.
git -C "$T/repo" worktree add -q -b feat/local-name "$T/wt4" origin/main
git -C "$T/wt4" config user.email "test@example.com"
git -C "$T/wt4" config user.name "Test User"
printf 'renamed push\n' > "$T/wt4/rename.txt"
git -C "$T/wt4" add rename.txt
git -C "$T/wt4" commit -q -m "feat: push renamed remote branch"
git -C "$T/wt4" push -q -u origin HEAD:refs/heads/published
out_rn="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt4" "s11")"
if [ -z "$out_rn" ]; then
  ok "rename-on-push branch (HEAD:refs/heads/published) emits nothing"
else
  fail "rename-on-push branch still flagged unpushed: $out_rn"
fi

# 12. Repo with default branch 'trunk' (no main/master) counts zero unpushed at origin/trunk.
git init --bare -q "$T/trunk-origin.git"
git clone -q "$T/trunk-origin.git" "$T/trunk-repo"
git -C "$T/trunk-repo" checkout -q -B trunk
git -C "$T/trunk-repo" config user.email "test@example.com"
git -C "$T/trunk-repo" config user.name "Test User"
printf 'trunk\n' > "$T/trunk-repo/trunk.txt"
git -C "$T/trunk-repo" add trunk.txt
git -C "$T/trunk-repo" commit -q -m "chore: trunk init"
git -C "$T/trunk-repo" push -q -u origin trunk
git -C "$T/trunk-repo" worktree add -q -b feat/on-trunk "$T/trunk-wt" origin/trunk
out_tr="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/trunk-wt" "s12")"
if [ -z "$out_tr" ]; then
  ok "default branch 'trunk' (no main/master) emits nothing for clean branch"
else
  fail "trunk default branch triggered false unpushed warning: $out_tr"
fi

# 13. Unfetched remote descendant commit means local HEAD is already landed.
wt_orig_sha="$(git -C "$T/wt" rev-parse HEAD)"
desc_sha=""
if ! desc_sha="$(git -C "$T/origin.git" -c user.name="Test User" -c user.email="test@example.com" commit-tree "$(git -C "$T/origin.git" rev-parse "${wt_orig_sha}^{tree}")" -p "$wt_orig_sha" -m "remote descendant")" \
  || [ -z "$desc_sha" ] \
  || ! git -C "$T/origin.git" update-ref refs/heads/feat/wt-test "$desc_sha"; then
  fail "test setup failed creating unfetched descendant commit on origin"
fi
out_desc="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s13")"
git -C "$T/origin.git" update-ref refs/heads/feat/wt-test "$wt_orig_sha"
if [ -z "$out_desc" ]; then
  ok "unfetched remote descendant commit keeps ancestor HEAD clean"
else
  fail "unfetched remote descendant commit triggered false unpushed warning: $out_desc"
fi

# 14. Unreachable remote fails closed instead of trusting stale refs/remotes/*.
git -C "$T/repo" config remote.origin.pushurl "$T/nonexistent-remote.git"
out_unreach="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s14")"
git -C "$T/repo" config --unset remote.origin.pushurl
if grep -q '"decision":"block"' <<<"$out_unreach" \
  && grep -q 'linked worktree' <<<"$out_unreach" \
  && grep -q 'git inspection failed' <<<"$out_unreach"; then
  ok "unreachable remote fails closed with inspection failure block"
else
  fail "unreachable remote trusted stale refs or leaked basename: $out_unreach"
fi

# 15. Repository-local core.sshCommand is preserved during live remote inspection.
cat > "$T/fake-ssh.sh" <<'SH'
#!/usr/bin/env bash
while [[ "${1:-}" == -* ]]; do
  shift
  [[ "${1:-}" == [0-9]* ]] && shift
done
shift
exec /bin/sh -c "$*"
SH
chmod +x "$T/fake-ssh.sh"
git -C "$T/repo" config core.sshCommand "$T/fake-ssh.sh"
git -C "$T/repo" config remote.origin.pushurl "ssh://dummy$T/origin.git"
out_ssh="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s15")"
git -C "$T/repo" config --unset core.sshCommand
git -C "$T/repo" config --unset remote.origin.pushurl
if [ -z "$out_ssh" ]; then
  ok "repo-local core.sshCommand is preserved and not overridden by GIT_SSH_COMMAND"
else
  fail "repo-local core.sshCommand was dropped or overridden: $out_ssh"
fi

# 16. Timed-out remote transport kills entire process group including descendants.
cat > "$T/hang-ssh.sh" <<SH
#!/usr/bin/env bash
sleep 30 </dev/null >/dev/null 2>&1 &
echo \$! > "$T/hang-child.pid"
wait
SH
chmod +x "$T/hang-ssh.sh"
git -C "$T/repo" config core.sshCommand "$T/hang-ssh.sh"
git -C "$T/repo" config remote.origin.pushurl "ssh://dummy$T/origin.git"
out_hang="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s16")"
git -C "$T/repo" config --unset core.sshCommand
git -C "$T/repo" config --unset remote.origin.pushurl
hang_pid="$(cat "$T/hang-child.pid" 2>/dev/null || true)"
if grep -q 'git inspection failed' <<<"$out_hang" \
  && [ -n "$hang_pid" ] \
  && ! kill -0 "$hang_pid" 2>/dev/null; then
  ok "timed-out remote transport terminates descendant processes in process group"
else
  [ -n "$hang_pid" ] && kill -9 "$hang_pid" 2>/dev/null || true
  fail "timed-out remote transport failed wrong or left descendant alive: pid=$hang_pid out=$out_hang"
fi

# 17. Path-dependent include.path and includeIf.gitdir authentication settings are preserved.
cat > "$T/repo/.git/rel-ssh.cfg" <<CFG
[core]
	sshCommand = $T/fake-ssh.sh
CFG
git -C "$T/repo" config include.path ./rel-ssh.cfg
git -C "$T/repo" config remote.origin.pushurl "ssh://dummy$T/origin.git"
out_rel="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s17-rel")"
git -C "$T/repo" config --unset include.path
cat > "$T/global-inc.cfg" <<CFG
[includeIf "gitdir:$T/"]
	path = $T/repo/.git/rel-ssh.cfg
CFG
out_if="$(GIT_CONFIG_GLOBAL="$T/global-inc.cfg" CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s17-if")"
git -C "$T/repo" config --unset remote.origin.pushurl
if [ -z "$out_rel" ] && [ -z "$out_if" ]; then
  ok "path-dependent include.path and includeIf.gitdir auth settings are preserved"
else
  fail "path-dependent git config lost: out_rel=$out_rel out_if=$out_if"
fi

# 18. Concurrent SubagentStop invocations serialize retry budget and never exceed 3 blocks.
printf 'conc\n' > "$T/repo/conc.txt"
pids=()
for i in 1 2 3 4 5 6; do
  CLAUDE_AUTONOMOUS_RUN=1 "$HOOK" <<<"{\"cwd\":\"$T/repo\",\"session_id\":\"s18-conc\",\"agent_id\":\"sub-$i\"}" > "$T/conc-$i.out" &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" || true
done
rm -f "$T/repo/conc.txt"
block_count=0
cap_count=0
for i in 1 2 3 4 5 6; do
  if grep -q '"decision":"block"' "$T/conc-$i.out"; then
    block_count=$((block_count + 1))
  elif grep -q 'stop check cap 3/3 reached' "$T/conc-$i.out"; then
    cap_count=$((cap_count + 1))
  fi
done
if [ "$block_count" -eq 3 ] && [ "$cap_count" -eq 3 ]; then
  ok "concurrent SubagentStop invocations serialize retry budget (3 blocks, 3 cap msgs)"
else
  fail "concurrent retry budget race: block_count=$block_count cap_count=$cap_count"
fi

# 19. Case-sensitive Git configuration subsections are preserved during live inspection.
ln -s "$T/origin.git" "$T/TeamOrigin.git"
git -C "$T/repo" config "url.$T/TeamOrigin.git.insteadOf" "https://example.invalid/Team/repo.git"
git -C "$T/repo" config remote.origin.pushurl "https://example.invalid/Team/repo.git"
out_case="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s19")"
git -C "$T/repo" config --remove-section "url.$T/TeamOrigin.git"
git -C "$T/repo" config --unset remote.origin.pushurl
rm -f "$T/TeamOrigin.git"
if [ -z "$out_case" ]; then
  ok "case-sensitive Git configuration subsections are preserved"
else
  fail "case-sensitive config subsection was lowercased and broke remote resolution: $out_case"
fi

# 20. Clone with sole non-origin remote (--origin fork) recognizes pushed branch without -u.
git clone -q --origin fork "$T/origin.git" "$T/fork-repo"
git -C "$T/fork-repo" worktree add -q -b feat/fork-wt "$T/fork-wt" fork/main
git -C "$T/fork-wt" config user.email "test@example.com"
git -C "$T/fork-wt" config user.name "Test User"
printf 'fork work\n' > "$T/fork-wt/fork.txt"
git -C "$T/fork-wt" add fork.txt
git -C "$T/fork-wt" commit -q -m "feat: fork push without -u"
git -C "$T/fork-wt" push -q fork HEAD:refs/heads/feat/fork-wt
out_fork="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/fork-wt" "s20")"
if [ -z "$out_fork" ]; then
  ok "sole non-origin remote (--origin fork) push without -u emits nothing"
else
  fail "sole non-origin remote failed inspection: $out_fork"
fi

# 21. Clean sibling checkout in the same session does not reset dirty checkout's retry cap.
printf 'dirty-sib\n' > "$T/repo/dirty-sib.txt"
sb1="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/repo" "s21-shared")"
_clean1="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s21-shared")"
sb2="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/repo" "s21-shared")"
_clean2="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s21-shared")"
sb3="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/repo" "s21-shared")"
_clean3="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s21-shared")"
sb4="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/repo" "s21-shared")"
rm -f "$T/repo/dirty-sib.txt"
if grep -q 'stop check 1/3' <<<"$sb1" \
  && grep -q 'stop check 2/3' <<<"$sb2" \
  && grep -q 'stop check 3/3' <<<"$sb3" \
  && grep -q 'stop check cap 3/3 reached' <<<"$sb4"; then
  ok "clean sibling checkout does not reset dirty checkout retry counter"
else
  fail "clean sibling checkout reset dirty retry counter: sb1=$sb1 sb2=$sb2 sb3=$sb3 sb4=$sb4"
fi

# 22. SHA-256 repository and linked worktree preserve object format during live inspection.
git init --bare -q --object-format=sha256 "$T/sha256-origin.git"
git clone -q "$T/sha256-origin.git" "$T/sha256-repo"
git -C "$T/sha256-repo" checkout -q -B main
git -C "$T/sha256-repo" config user.email "test@example.com"
git -C "$T/sha256-repo" config user.name "Test User"
printf 'sha256\n' > "$T/sha256-repo/f.txt"
git -C "$T/sha256-repo" add f.txt
git -C "$T/sha256-repo" commit -q -m "chore: sha256 init"
git -C "$T/sha256-repo" push -q -u origin main
git -C "$T/sha256-repo" worktree add -q -b feat/sha256-wt "$T/sha256-wt" origin/main
out_sha256="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/sha256-wt" "s22")"
if [ -z "$out_sha256" ]; then
  ok "SHA-256 linked worktree preserves object format in scratch inspection"
else
  fail "SHA-256 linked worktree failed scratch inspection: $out_sha256"
fi

# 23. Multiple pushurl destinations: all must have HEAD landed before reporting clean.
git init --bare -q "$T/mirror-origin.git"
git -C "$T/repo" config --add remote.origin.pushurl "$T/origin.git"
git -C "$T/repo" config --add remote.origin.pushurl "$T/mirror-origin.git"
out_multi_unlanded="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s23")"
git -C "$T/wt" push -q "$T/mirror-origin.git" HEAD:refs/heads/feat/wt-test
out_multi_landed="$(CLAUDE_AUTONOMOUS_RUN=1 run_hook "$T/wt" "s23")"
git -C "$T/repo" config --unset-all remote.origin.pushurl
if grep -q '"decision":"block"' <<<"$out_multi_unlanded" \
  && grep -q 'unpushed commit(s)' <<<"$out_multi_unlanded" \
  && [ -z "$out_multi_landed" ]; then
  ok "multiple pushurl destinations are all inspected before clearing unpushed state"
else
  fail "multiple pushurl handling wrong: unlanded=$out_multi_unlanded landed=$out_multi_landed"
fi

echo ""
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
