#!/usr/bin/env python3
"""Reproduce screenshot starvation using the actual supervised helper protocol."""
from pathlib import Path
import json
import os
import shutil
import sqlite3
import subprocess
import time

root = Path(__file__).resolve().parent.parent
verify = root / "verification"
fixture = verify / "indexing-fixture"
fixture.mkdir(exist_ok=True)
(fixture / "harbor.txt").write_text("Harbor maintenance report. Replace the corroded anchor chain on the sailboat and inspect the bilge pump before leaving the marina.")
(fixture / "journey.txt").write_text("Plan a railway journey through Japan. Reserve a hotel in Kyoto and buy tickets for the train from Osaka.")
shutil.copyfile(verify / "ocr-fixture/Screenshot.png", fixture / "Screenshot.png")
index = verify / "indexing-regression-index"
helper = root / "build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Indexer"
models = Path.home() / "Library/Application Support/Swiftlight/Models"
start = time.monotonic()
p = subprocess.Popen([str(helper), "index-service", str(fixture), "--index", str(index), "--backfill", "--linger", "0", "--new-limit", "25", "--memory-limit", "1536", "--time-limit", "120"], env=dict(os.environ, DIGUP_MODELS=str(models)), stdin=subprocess.PIPE, stdout=(verify / "indexing-regression.jsonl").open("w"), stderr=(verify / "indexing-regression-runtime.log").open("w"))
try:
    p.wait(timeout=35)
    assert p.returncode == 0, (verify / "indexing-regression.jsonl").read_text()
finally:
    if p.poll() is None:
        p.terminate()
        p.wait(timeout=5)
events = [json.loads(s) for s in (verify / "indexing-regression.jsonl").read_text().splitlines()]
files = [e for e in events if e.get("event") == "file"]
assert len(files) == 3 and all(e["state"] == "done" for e in files), files
assert [e["kind"] for e in files] == ["doc", "doc", "screenshot"], files
shot = files[-1]
assert shot["seconds"] < 10, shot
with sqlite3.connect(index / "index.sqlite") as db:
    vectors = db.execute("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL").fetchone()[0]
    ocr = db.execute("SELECT excerpt FROM segments WHERE kind='ocr'").fetchone()[0]
    assert vectors == 3, vectors
    assert "Helium" in ocr and "Webcam Helper" in ocr, ocr
report = dict(documents_before_screenshots=True, screenshot_seconds=shot["seconds"], total_seconds=time.monotonic()-start, vectors=vectors, screenshot_ocr_reads_app_names=True)
(verify / "indexing-verification.json").write_text(json.dumps(report, indent=2)+"\n")
print(json.dumps(report, indent=2))
