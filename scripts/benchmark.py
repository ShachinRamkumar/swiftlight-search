#!/usr/bin/env python3
"""Measure warm filename responses from the packaged Rust process."""
from pathlib import Path
import json, queue, subprocess, threading, statistics
r = Path(__file__).resolve().parent.parent
p = subprocess.Popen([str(r / "build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Search"), "--config", str(r / "verification/fixture-config.json")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(r / "verification/latency.log").open("w"), text=True, bufsize=1)
events = queue.Queue()
threading.Thread(target=lambda: [events.put(json.loads(s)) for s in p.stdout], daemon=True).start()
samples = []
try:
    for generation in range(1,21):
        text = ["saf", "chrome", "notes", "readme"][generation % 4]
        p.stdin.write(json.dumps(dict(op="query", generation=generation, text=text)) + "\n")
        p.stdin.flush()
        while True:
            e = events.get(timeout=10)
            if e.get("event") == "results" and e.get("phase") == "fast" and e.get("generation") == generation:
                samples.append(e["elapsed_ms"])
                break
    p.stdin.write('{"op":"quit"}\n')
    p.stdin.flush()
    p.wait(timeout=10)
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
report = dict(queries=len(samples), median_ms=statistics.median(samples), p95_ms=sorted(samples)[18], first_ms=samples[0], min_ms=min(samples), max_ms=max(samples))
(r / "verification/latency.json").write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps(report,indent=2))
