#!/usr/bin/env python3
"""Document mode defers media, then full mode resumes without resetting vectors."""
from pathlib import Path
import hashlib, json, os, shutil, sqlite3, subprocess

ROOT = Path(__file__).resolve().parent.parent
VERIFY = ROOT / 'verification'
case = VERIFY / 'index-modes-case'
if case.exists(): shutil.rmtree(case)
home = case / 'home'
home.mkdir(parents=True)
(home / 'note.txt').write_text('The landlord must return the tenant security deposit after the apartment inspection, deducting only unpaid rent and damage beyond normal wear.')
shutil.copyfile(VERIFY / 'ocr-fixture/Screenshot.png', home / 'Screenshot.png')
index = case / 'index'
helper = ROOT / 'build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Indexer'
env = dict(os.environ, DIGUP_MODELS=str(Path.home() / 'Library/Application Support/Swiftlight/Models'))
def snapshot():
    with sqlite3.connect(index / 'index.sqlite') as db:
        states = dict(db.execute('SELECT kind,state FROM files'))
        blob = db.execute("SELECT vec FROM segments WHERE kind='chunk'").fetchone()[0]
        source = db.execute("SELECT value FROM meta WHERE key='vector_source'").fetchone()[0]
        return states, hashlib.sha256(blob).hexdigest(), source
# EOF means stop, so keep stdin open until the helper reaches idle.
def index_pass(mode):
    command = [str(helper), 'index-service', str(home), '--index', str(index), '--backfill', '--linger', '0']
    if mode == 'documents': command.append('--text-only')
    p = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=(case / (mode+'.jsonl')).open('w'), stderr=(case / (mode+'.log')).open('w'))
    try:
        assert p.wait(timeout=30) == 0
    finally:
        if p.poll() is None: p.terminate(); p.wait(timeout=10)
index_pass('documents')
before, digest, source = snapshot()
assert before == {'doc':'done', 'screenshot':'pending'}, before
assert 'text-only' in (index / 'worker.log').read_text()
index_pass('full')
after, final_digest, final_source = snapshot()
assert after == {'doc':'done', 'screenshot':'done'}, after
assert digest == final_digest and source == final_source, 'Changing pressure modes reset or replaced existing document embeddings'
with sqlite3.connect(index / 'index.sqlite') as db:
    assert db.execute("SELECT COUNT(*) FROM segments WHERE kind='image' AND vec IS NOT NULL").fetchone()[0] > 0
    assert db.execute("SELECT COUNT(*) FROM segments WHERE kind='ocr' AND LENGTH(excerpt)>0").fetchone()[0] > 0
report = dict(documents_embedded_with_smaller_model=True, media_retained_pending=True, media_resumed_in_full_mode=True, existing_vectors_preserved=True)
(VERIFY / 'index-modes-verification.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report))
