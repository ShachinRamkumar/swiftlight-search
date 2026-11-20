#!/usr/bin/env python3
"""Measure search quality and speed on the real index: known answers, queries with no answer, latency.

Runs the built backend read-only against the production index (no indexing, no opens).
Usage: eval-search.py LABEL   ->  verification/search-eval-LABEL.json
"""
from pathlib import Path
import atexit, json, os, queue, signal, statistics, subprocess, sys, threading, time

root = Path(__file__).resolve().parent.parent
verify = root / "verification"
label = sys.argv[1] if len(sys.argv) > 1 else "current"
cases = json.loads((verify / "search-eval-queries.json").read_text())
# SPOTLIGHT_EVAL_BACKEND / SPOTLIGHT_EVAL_CONFIG compare another build or a copy of the index.
backend = os.environ.get("SPOTLIGHT_EVAL_BACKEND", root / "build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Search")
config = os.environ.get("SPOTLIGHT_EVAL_CONFIG", verify / "production-readonly-config.json")
# The live indexing helper's model work inflates latency: it's paused while measuring.
paused = [int(x) for x in subprocess.run(["pgrep", "-f", "Swiftlight Indexer index-service"], capture_output=True, text=True).stdout.split()]
for pid in paused: os.kill(pid, signal.SIGSTOP)
atexit.register(lambda: [os.kill(pid, signal.SIGCONT) for pid in paused])
p = subprocess.Popen([str(backend), "--config", str(config)], env={"SPOTLIGHT_VERIFY": "1", "HOME": str(Path.home()), **{k: os.environ[k] for k in ("P3B_SPECIALIZATION_AUDIT_DIR", "P3B_SPECIALIZATION_LIMIT", "DIGUP_COREAI_MIN_FREE_DISK_BYTES", "SPOTLIGHT_PROFILE", "TMPDIR", "HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE") if k in os.environ}},
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(verify / f"search-eval-{label}.stderr").open("w"), text=True)
events = queue.Queue()
threading.Thread(target=lambda: [events.put(json.loads(line)) for line in p.stdout], daemon=True).start()
def send(request): p.stdin.write(json.dumps(request) + "\n"); p.stdin.flush()
send({"op": "active", "value": True}); time.sleep(8)
generation = 0
def search(text):
    """Final merged list once meaning search has answered (or 15 s), and when it did."""
    global generation
    generation += 1; send({"op": "query", "generation": generation, "text": text})
    started, final, meaning_ms = time.monotonic(), [], None
    phases, diagnostics = [], []
    while time.monotonic() - started < 15:
        try: event = events.get(timeout=15 - (time.monotonic() - started))
        except queue.Empty: break
        if event.get("generation") == generation and event.get("event") == "diagnostic": diagnostics.append(event)
        if event.get("generation") != generation or event.get("event") != "results": continue
        final = event["hits"]
        phases.append(event)
        if event.get("phase") == "semantic": meaning_ms = (time.monotonic() - started) * 1000
        if event.get("complete"): break
    # Name and keyword phases can land after meaning; take the list as it settles.
    settle = time.monotonic() + .5
    while (left := settle - time.monotonic()) > 0:
        try: event = events.get(timeout=left)
        except queue.Empty: break
        if event.get("generation") == generation and event.get("event") == "results": final = event["hits"]
    report.setdefault("raw_results", {})[text] = {"final": final, "phases": phases, "diagnostics": diagnostics}
    report.setdefault("final_hit_lists", {})[text] = [{"path": h["path"], "category": h["category"]} for h in final]
    return final[:12], meaning_ms
report = {"answers": [], "no_answer": []}
for case in cases["answers"]:
    hits, ms = search(case["query"])
    rank = next((i + 1 for i, h in enumerate(hits) if any(e in h["path"] for e in case["expect"])), None)
    report["answers"].append({"query": case["query"], "rank": rank, "meaning_ms": ms, "top": [h["path"].replace(str(Path.home()), "~") for h in hits[:5]]})
    print(f"{rank or '-':>3}  {round(ms or -1):5} ms  {case['query']}", flush=True)
for text in cases["no_answer"]:
    hits, ms = search(text)
    noise = [h["path"].replace(str(Path.home()), "~") for h in hits if h["category"] in ("meaning", "content")]
    report["no_answer"].append({"query": text, "content_hits": len(noise), "meaning_ms": ms, "top": noise[:3]})
    print(f"{len(noise):>3} noise {round(ms or -1):5} ms  {text}", flush=True)
send({"op": "quit"})
p.wait(timeout=30)
ranks = [a["rank"] for a in report["answers"]]
latencies = [x["meaning_ms"] for x in report["answers"] + report["no_answer"] if x["meaning_ms"]]
report["summary"] = {
    "queries": len(ranks),
    "first": sum(r == 1 for r in ranks), "top3": sum(bool(r and r <= 3) for r in ranks), "top12": sum(bool(r) for r in ranks),
    "mrr": round(sum(1 / r for r in ranks if r) / len(ranks), 3),
    "noise_hits_per_no_answer_query": round(statistics.mean(x["content_hits"] for x in report["no_answer"]), 1),
    "meaning_ms_median": round(statistics.median(latencies)), "meaning_ms_max": round(max(latencies)),
}
(verify / f"search-eval-{label}.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report["summary"], indent=2))
