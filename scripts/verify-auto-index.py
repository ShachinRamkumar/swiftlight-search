#!/usr/bin/env python3
"""A new document must reach semantic search through the Rust index supervisor."""
from pathlib import Path
import argparse, json, os, queue, shutil, sqlite3, subprocess, threading, time

ROOT = Path(__file__).resolve().parent.parent
VERIFY = ROOT / 'verification'
parser = argparse.ArgumentParser()
parser.add_argument('--installed', action='store_true')
args = parser.parse_args()
bundle = Path.home() / 'Applications/Swiftlight.app' if args.installed else ROOT / 'build.noindex/Swiftlight.app'
case = VERIFY / 'auto-index-case'
if case.exists(): shutil.rmtree(case)
home = case / 'home'
home.mkdir(parents=True)
doc = home / 'note.txt'
doc.write_text('The harbor maintenance plan requires replacing the corroded anchor chain on the sailboat and inspecting the bilge pump before leaving the marina.')
shutil.copyfile(VERIFY / 'ocr-fixture/Screenshot.png', home / 'Screenshot.png')
index = case / 'index'
config = case / 'config.json'
config.write_text(json.dumps(dict(home=str(home), helper=str(bundle / 'Contents/Helpers/Swiftlight Indexer'), index=str(index), models=str(Path.home() / 'Library/Application Support/Swiftlight/Models'), auto_index=True, excluded=[])))
events = queue.Queue()
p = subprocess.Popen([str(bundle / 'Contents/Helpers/Swiftlight Search'), '--config', str(config)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(case / 'runtime.log').open('w'), text=True, bufsize=1)
threading.Thread(target=lambda: [events.put(json.loads(line)) for line in p.stdout], daemon=True).start()
start = time.monotonic()
try:
    deadline = start + 30
    found = False
    while time.monotonic() < deadline:
        dbpath = index / 'index.sqlite'
        if dbpath.exists():
            with sqlite3.connect(dbpath) as db:
                tables = db.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','segments')").fetchone()[0]
                if tables == 2:
                    document_ready = db.execute("SELECT COUNT(*) FROM segments s JOIN files f ON f.id=s.file WHERE f.path=? AND s.vec IS NOT NULL", [str(doc)]).fetchone()[0] > 0
                    image_ready = db.execute("SELECT COUNT(*) FROM segments s JOIN files f ON f.id=s.file WHERE f.path=? AND s.kind='image' AND s.vec IS NOT NULL", [str(home/'Screenshot.png')]).fetchone()[0] > 0
                    found = document_ready and image_ready
        if found: break
        assert p.poll() is None, (case / 'runtime.log').read_text()
        time.sleep(.1)
    assert found, 'Automatic indexing did not embed both document and screenshot within 30 seconds'
    indexed_seconds = time.monotonic() - start
    query = 'repairing a boat before a sailing trip'
    p.stdin.write(json.dumps(dict(op='query', generation=1, text=query))+'\n'); p.stdin.flush()
    while True:
        event = events.get(timeout=20)
        assert event.get('event') != 'diagnostic' or event.get('source') == 'fsearch', event
        if event.get('generation') == 1 and event.get('phase') == 'semantic': break
    assert event['hits'] and event['hits'][0]['path'] == str(doc) and event['hits'][0]['source'] == 'semantic', event
    report = dict(automatic_ingestion_seconds=round(indexed_seconds, 3), automatic_screenshot_embedding=True, query=query, semantic_top_match='note.txt', cosine=event['hits'][0]['cosine'])
    (VERIFY / 'auto-index-verification.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report))
finally:
    if p.poll() is None:
        p.stdin.write('{"op":"quit"}\n'); p.stdin.flush()
        try: p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, 15); p.wait(timeout=10)
