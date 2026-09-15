#!/usr/bin/env bash
# Native CLI is simulated; all fixtures, receipts and transport files are private.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GATE="${TEST_REVIEW_GATE:-$SCRIPT_DIR/../codex-review-gate.sh}"
FIXTURE="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE"' EXIT
mkdir "$FIXTURE/repo" "$FIXTURE/bin" "$FIXTURE/home"
git -C "$FIXTURE/repo" init -q -b main
git -C "$FIXTURE/repo" config user.email fixture@example.test
git -C "$FIXTURE/repo" config user.name fixture
printf 'original\n' > "$FIXTURE/repo/code.txt"
git -C "$FIXTURE/repo" add code.txt
git -C "$FIXTURE/repo" commit -qm base
python3 - "$FIXTURE/repo/code.txt" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text('FIRST_COMPLETE_MARKER\n' + ('fixture😀' * 160 + '\n') * 1000 + 'LAST_COMPLETE_MARKER\n')
PY
cat > "$FIXTURE/bin/codex" <<'PY'
#!/usr/bin/env python3
import hashlib,json,os,re,signal,sqlite3,stat,sys
from pathlib import Path
if sys.argv[1:]==['debug','models','--bundled']:
 print(json.dumps({'models':[{'slug':'fixture-model','context_window':272000,'max_context_window':872000,'effective_context_window_percent':95}]}));sys.exit(0)
capture=Path(os.environ['CAPTURE']); prompt=sys.stdin.read(); mode=os.environ['MODE']
assert len(prompt)<1048576
m=re.search(r'^Review transport part: ([0-9]+)/([0-9]+)\nPart SHA-256: ([a-f0-9]{64})\nPacket SHA-256: ([a-f0-9]{64})\nFragment fence: (REVIEW_PART_[a-f0-9]+_*)$',prompt,re.M)
assert m, 'multipart direct input required'
index,total=int(m[1]),int(m[2]); fence=m[5]
fragment=prompt.split('\n'+fence+'\n')[1]
assert hashlib.sha256(fragment.encode()).hexdigest()==m[3]
(capture/str(index)).write_text(fragment)
assert '-s' in sys.argv and sys.argv[sys.argv.index('-s')+1]=='read-only'
assert '--json' in sys.argv and '--output-schema' in sys.argv
directory=Path(sys.argv[sys.argv.index('-o')+1]).parent
if index<total: (capture/'transport-dir').write_text(str(directory))
thread='11111111-1111-4111-8111-111111111111'
if index>1:
 assert 'model_context_window=872000' in sys.argv
 assert 'resume' in sys.argv and sys.argv[sys.argv.index('resume')+1]==thread
else: assert 'resume' not in sys.argv
assert not Path('.git/review-receipts/codex.json').exists(), 'intermediate approval leaked'
# Simulate native persisted history; checks read records, not reviewer ack claims.
home=Path.home()/'.codex';home.mkdir(exist_ok=True)
rollout=capture/'rollout.jsonl'
if index==1: records=[{'type':'session_meta','payload':{'id':thread}}]
else: records=[json.loads(line) for line in rollout.read_text().splitlines()]
records += [{'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':prompt}]}},
 {'type':'turn_context','payload':{'model':'fixture-model','sandbox_policy':{'type':'read-only'}}},
 {'type':'event_msg','payload':{'type':'token_count','info':{'model_context_window':258400 if index==1 else 828400}}}]
if mode=='compacted': records.append({'type':'compacted','payload':{'message':'summary'}})
if mode=='lost-input': records[-3]['payload']['content'][0]['text']='summary instead'
if mode=='writable': records[-2]['payload']['sandbox_policy']={'type':'workspace-write'}
if mode=='wrong-window' and index>1: records[-1]['payload']['info']['model_context_window']=258400
rollout.write_text(''.join(json.dumps(record)+'\n' for record in records))
with sqlite3.connect(home/'state_5.sqlite') as db:
 db.execute('create table if not exists threads(id text primary key,rollout_path text)')
 db.execute('insert or replace into threads values(?,?)',(thread,str(rollout)))
assert stat.S_IMODE(Path(sys.argv[sys.argv.index('-o')+1]).stat().st_mode)==0o600
if mode=='tamper-part': (directory/f'part-{index}.txt').write_text('tampered')
if mode=='tamper-manifest': (directory/'manifest.json').write_text('{}')
if mode=='failed-cli': sys.exit(7)
if mode=='signal': os.kill(os.getppid(),signal.SIGTERM)
if mode=='repo-change': Path('code.txt').write_text('changed during review\n')
print(json.dumps({'type':'thread.started','thread_id': ('22222222-2222-4222-8222-222222222222' if mode=='wrong-session' and index>1 else thread)}))
if mode!='missing-completion': print(json.dumps({'type':'turn.completed','usage':{}}))
if mode=='event-error': print(json.dumps({'type':'error','message':'failed'}))
if index<total:
 result={'part':index,'sha256':m[3] if mode!='wrong-ack' else '0'*64}
else:
 data=''.join((capture/str(i)).read_text() for i in range(1,total+1))
 assert hashlib.sha256(data.encode()).hexdigest()==m[4]
 assert data.startswith('You are performing a pre-push code review as an independent reviewer.\n')
 expected=Path('code.txt').read_text().splitlines(keepends=True)
 assert ''.join('+'+line for line in expected) in data
 assert 'FIRST_COMPLETE_MARKER' in data and 'LAST_COMPLETE_MARKER' in data
 assert 'Claim to disprove: Complete fixture claim' in data
 assert 'Reproduction command: inspect all fixture lines' in data
 (capture/'complete-request').write_text(data)
 result={'verdict':'approve','summary':'fixture','findings':[],'next_steps':[]}
if mode!='no-result': Path(sys.argv[sys.argv.index('-o')+1]).write_text(json.dumps(result))
PY
chmod +x "$FIXTURE/bin/codex"
export CODEX_GATE_BIN="$FIXTURE/bin/codex"
for MODE in approve compacted lost-input writable wrong-window tamper-part tamper-manifest wrong-session wrong-ack missing-completion event-error no-result failed-cli signal repo-change; do
 export MODE CAPTURE="$FIXTURE/$MODE"
 mkdir "$CAPTURE"
 set +e
 (cd "$FIXTURE/repo" && HOME="$FIXTURE/home" "$GATE" --uncommitted --no-issues --claim 'Complete fixture claim' --repro 'inspect all fixture lines') > "$CAPTURE/output" 2>&1
 rc=$?
 set -e
 if [[ "$MODE" == approve ]]; then
   [[ "$rc" -eq 0 ]] || { cat "$CAPTURE/output"; exit 1; }
   [[ -s "$CAPTURE/complete-request" && -f "$FIXTURE/repo/.git/review-receipts/codex.json" ]]
 else
   [[ "$rc" -ne 0 && ! -f "$FIXTURE/repo/.git/review-receipts/codex.json" ]] || { echo "FAIL: $MODE accepted"; exit 1; }
 fi
 [[ ! -e "$(cat "$CAPTURE/transport-dir")" ]] || { echo "FAIL: transport leaked"; exit 1; }
 echo "ok - $MODE: exact direct multipart input, native session and receipt"
done
