#!/usr/bin/env python3
"""Measure what typing feels like on the real index: every keystroke's name results, and the final query's
content and meaning results, from the built backend (read-only: no indexing, no opens).

Types each query a character at a time at GAP_MS, as a quick typist does, then waits for the last phase.
The live indexing helper is paused (SIGSTOP) while measuring and resumed after, so its model work doesn't
skew the timings. Usage: profile-typing.py LABEL  ->  verification/typing-LABEL.json
"""
from pathlib import Path
import json, os, queue, signal, statistics, subprocess, sys, threading, time

GAP_MS = 90
root = Path(__file__).resolve().parent.parent
verify = root / "verification"
label = sys.argv[1] if len(sys.argv) > 1 else "current"
backend = root / "build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Search"
queries = [
    "safari", "chrome", "resume", "notes", "screenshot", "syllabus", "system settings", "terminal",
    "how do tidal turbines generate power", "quicksort partition", "red and blue screenshot",
    "my resume for the job application", "registration form confirmation number", "calculus textbook",
    "physics syllabus", "photo of a dog",
]

def helpers():
    out = subprocess.run(["pgrep", "-f", "Swiftlight Indexer index-service"], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]

def rss_mb(pid):
    """Resident memory of `pid` and its descendants."""
    table = subprocess.run(["ps", "-axo", "pid=,ppid=,rss="], capture_output=True, text=True).stdout.split("\n")
    rows = [tuple(map(int, line.split())) for line in table if line.strip()]
    family, total, changed = {pid}, 0, True
    while changed:
        changed = False
        for p, pp, _ in rows:
            if pp in family and p not in family:
                family.add(p); changed = True
    return {p: r / 1024 for p, _, r in rows if p in family}

paused = helpers()
for pid in paused: os.kill(pid, signal.SIGSTOP)
try:
    p = subprocess.Popen([str(backend), "--config", str(verify / "production-readonly-config.json")],
                         env={"SPOTLIGHT_VERIFY": "1", "SPOTLIGHT_PROFILE": "1", "HOME": str(Path.home())},
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=(verify / f"typing-{label}.stderr").open("w"), text=True)
    events = queue.Queue()
    def read():
        for line in p.stdout: events.put((time.monotonic(), json.loads(line)))
    threading.Thread(target=read, daemon=True).start()
    def send(request): p.stdin.write(json.dumps(request) + "\n"); p.stdin.flush()
    started = time.monotonic()
    send({"op": "active", "value": True})
    time.sleep(8)
    generation, sent, seen = 0, {}, {}
    def drain(until):
        while (left := until - time.monotonic()) > 0:
            try: at, event = events.get(timeout=left)
            except queue.Empty: return
            if event.get("event") != "results" or event.get("phase") == "pending": continue
            g = event["generation"]
            record = seen.setdefault(g, {})
            # Names, then keyword content, then meaning ("fast" twice from builds that sent keywords with names).
            phase = event["phase"]
            key = {"semantic": "semantic", "keyword": "content"}.get(phase, "names" if "names" not in record else "content")
            record.setdefault(key, (at - sent[g]) * 1000)
            record["last"] = (at - sent[g]) * 1000
    report = {"keystrokes": [], "queries": []}
    for text in queries:
        for i in range(1, len(text) + 1):
            generation += 1
            sent[generation] = time.monotonic()
            send({"op": "query", "generation": generation, "text": text[:i]})
            drain(time.monotonic() + GAP_MS / 1000)
        final = generation
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline and "semantic" not in seen.get(final, {}):
            drain(min(deadline, time.monotonic() + 0.05))
        drain(time.monotonic() + 0.3)
        first = final - len(text) + 1
        for g in range(first, final + 1):
            report["keystrokes"].append({"text": text[: g - first + 1], **seen.get(g, {})})
        report["queries"].append({"text": text, **seen.get(final, {})})
        print(f"{text:45} names {seen.get(final, {}).get('names', -1):7.1f}  content {seen.get(final, {}).get('content', -1):7.1f}  meaning {seen.get(final, {}).get('semantic', -1):7.1f} ms", flush=True)
        # Clear the field between queries, as the launcher does.
        generation += 1; sent[generation] = time.monotonic(); send({"op": "query", "generation": generation, "text": ""})
        drain(time.monotonic() + 0.4)
    memory = rss_mb(p.pid)
    send({"op": "quit"})
    p.wait(timeout=10)
finally:
    for pid in paused:
        try: os.kill(pid, signal.SIGCONT)
        except ProcessLookupError: pass

names = [k["names"] for k in report["keystrokes"] if "names" in k]
missing = sum("names" not in k for k in report["keystrokes"])
def pct(values, q): return round(sorted(values)[min(len(values) - 1, int(q * len(values)))], 1) if values else None
meaning = [q["semantic"] for q in report["queries"] if "semantic" in q]
content = [q["content"] for q in report["queries"] if "content" in q]
report["summary"] = {
    "keystrokes": len(report["keystrokes"]), "keystrokes_without_names": missing,
    "names_ms_p50": pct(names, .5), "names_ms_p95": pct(names, .95), "names_ms_max": pct(names, 1),
    "final_content_ms_p50": pct(content, .5), "final_content_ms_max": pct(content, 1),
    "final_meaning_ms_p50": pct(meaning, .5), "final_meaning_ms_max": pct(meaning, 1),
    "rss_mb": {str(k): round(v, 1) for k, v in memory.items()},
}
(verify / f"typing-{label}.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report["summary"], indent=2))
