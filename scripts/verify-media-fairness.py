#!/usr/bin/env python3
"""Screenshots must get an embedding turn before the entire document backlog finishes."""
from pathlib import Path
import argparse,json,os,queue,shutil,subprocess,threading

ROOT=Path(__file__).resolve().parent.parent
VERIFY=ROOT/'verification'
parser=argparse.ArgumentParser();parser.add_argument('--installed',action='store_true');args=parser.parse_args()
bundle=Path.home()/'Applications/Swiftlight.app' if args.installed else ROOT/'build.noindex/Swiftlight.app'
case=VERIFY/'media-fairness-case'
if case.exists():shutil.rmtree(case)
home=case/'home';home.mkdir(parents=True)
for i in range(5):(home/f'note-{i}.txt').write_text('The sailing trip requires repairing the anchor chain and checking the boat bilge pump at the harbor.')
shutil.copyfile(VERIFY/'ocr-fixture/Screenshot.png',home/'Screenshot.png')
support=Path.home()/'Library/Application Support/Swiftlight'
p=subprocess.Popen([str(bundle/'Contents/Helpers/Swiftlight Indexer'),'index-service',str(home),'--index',str(case/'index'),'--backfill','--linger','0'],env=dict(os.environ,DIGUP_MODELS=str(support/'Models')),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=(case/'runtime.log').open('w'),text=True,bufsize=1)
events=queue.Queue();threading.Thread(target=lambda:[events.put(json.loads(line)) for line in p.stdout],daemon=True).start()
kinds=[]
try:
    while len(kinds)<3:
        event=events.get(timeout=20)
        assert event['event']!='error',event
        if event['event']=='file':
            assert event['state']=='done',event
            kinds.append(event['kind'])
    assert kinds==['doc','doc','screenshot'],f'Screenshot starved behind documents: {kinds}'
    report=dict(first_three_files=kinds,screenshots_get_a_turn_before_document_backlog_finishes=True)
    (VERIFY/'media-fairness-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
finally:
    if p.poll() is None:
        p.stdin.write('stop\n');p.stdin.flush()
        try:p.wait(timeout=10)
        except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10)
