#!/usr/bin/env python3
"""A queued rescan must not bypass the pending backlog after one new file finishes."""
from pathlib import Path
import json, os, queue, shutil, subprocess, threading, time

ROOT = Path(__file__).resolve().parent.parent
VERIFY = ROOT / 'verification'
case = VERIFY / 'index-fairness-case'
if case.exists(): shutil.rmtree(case)
home = case / 'home'
home.mkdir(parents=True)
for i in range(40):
    (home / f'old-{i}.txt').write_text('Vacation itinerary for Kyoto. Visit temples and gardens, reserve a hotel near the train station, and buy a rail ticket.')
helper = ROOT / 'build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Indexer'
env = dict(os.environ, DIGUP_MODELS=str(Path.home() / 'Library/Application Support/Swiftlight/Models'))
index = case / 'index'
def launch(extra):
    return subprocess.Popen([str(helper), 'index-service', str(home), '--index', str(index), '--text-only', '--linger', '0']+extra, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(case/'runtime.log').open('a'), text=True, bufsize=1)
p = launch(['--new-limit','0'])
try: p.communicate(timeout=10)
finally:
    if p.poll() is None: p.terminate(); p.wait(timeout=10)
assert p.returncode==0
(home / 'new.txt').write_text('A newly created maintenance note about repairing the boat anchor and replacing the rusty chain.')
p = launch(['--backfill','--new-limit','1'])
events = queue.Queue()
threading.Thread(target=lambda: [events.put(json.loads(line)) for line in p.stdout], daemon=True).start()
trace = []
try:
    sync = events.get(timeout=10)
    assert sync['event']=='sync' and sync['new']==1,sync
    p.stdin.write('sync\n');p.stdin.flush()
    deadline = time.monotonic()+20
    new_done = False
    while time.monotonic()<deadline:
        event = events.get(timeout=max(.1,deadline-time.monotonic()))
        trace.append(event)
        if event['event']=='file' and event['new']:
            assert event['seconds']<1.8, 'Cold model loading consumed the entire sync budget; retry this timing check'
            new_done=True
        elif new_done and event['event']=='sync':
            raise AssertionError('A rescan ran before any pending backlog file was embedded')
        elif new_done and event['event']=='file' and not event['new']:
            assert event['state']=='done',event
            break
    else: raise AssertionError('No backlog progress')
    report = dict(new_file_first=True, queued_sync_does_not_starve_backlog=True)
    (VERIFY/'index-fairness-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
finally:
    (case/'events.json').write_text(json.dumps(trace,indent=2)+'\n')
    if p.poll() is None:
        p.stdin.write('stop\n');p.stdin.flush()
        try:p.wait(timeout=10)
        except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10)
