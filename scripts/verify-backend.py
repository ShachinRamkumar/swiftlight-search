#!/usr/bin/env python3
"""Exercise the real Rust process, FSearch socket, model and local index."""
from pathlib import Path
import json, os, queue, sqlite3, subprocess, threading, time

root = Path(__file__).resolve().parent.parent
verify = root / "verification"
fixtures = verify / "fixtures"
index = verify / "fixture-index"
fixtures.mkdir(exist_ok=True)
index.mkdir(exist_ok=True)
docs = {
    "blue-note.txt": "Residential rental agreement. The landlord must return the tenant's security deposit within thirty days after moving out. Deductions are allowed for unpaid rent and damage beyond normal wear. The tenant should provide a forwarding address and keep the inspection photographs.",
    "green-note.txt": "Vacation itinerary for Kyoto. Visit temples and gardens in Japan, take the train from Osaka, and reserve a hotel near the station. Bring comfortable walking shoes and purchase a regional rail ticket.",
    "red-note.txt": "Chocolate cake recipe. Mix flour, cocoa powder, eggs, butter, and sugar. Bake the batter in a round pan for thirty minutes. Let it cool before spreading chocolate frosting on the cake.",
}
for name, content in docs.items():
    (fixtures / name).write_text(content)
hidden = fixtures / ".hidden"
hidden.mkdir(exist_ok=True)
(hidden / "never-index.txt").write_text("A hidden document that must never enter search.")
(fixtures / "credentials.txt").write_text("Synthetic credential fixture. Never index this file.")
helper = root / "build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Indexer"
backend = root / "build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Search"
models = Path.home() / "Library/Application Support/Swiftlight/Models"
env = dict(os.environ, DIGUP_MODELS=str(models))
subprocess.run([str(helper), "index", str(fixtures), "--index", str(index)], env=env, check=True, stdout=(verify / "fixture-index.log").open("w"), stderr=(verify / "fixture-runtime.log").open("w"), timeout=120)
with sqlite3.connect(index / "index.sqlite") as db:
    paths = [r[0] for r in db.execute("SELECT path FROM files")]
    assert len(paths) == 3, paths
    assert db.execute("SELECT count(*) FROM segments WHERE vec IS NOT NULL").fetchone()[0] == 3
config = dict(home=str(Path.home()), helper=str(helper), index=str(index), models=str(models), auto_index=False, excluded=[])
config_path = verify / "fixture-config.json"
config_path.write_text(json.dumps(config))
p = subprocess.Popen([str(backend), "--config", str(config_path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(verify / "backend.log").open("w"), text=True, bufsize=1, env=dict(os.environ, SPOTLIGHT_VERIFY="1"))
events = queue.Queue()
def read_events():
    with (verify / 'backend-events.jsonl').open('w') as trace:
        for line in p.stdout:
            trace.write(line); trace.flush()
            events.put(json.loads(line))
threading.Thread(target=read_events, daemon=True).start()
pending_events = []
def send(value):
    p.stdin.write(json.dumps(value) + "\n"); p.stdin.flush()
def wait(predicate, timeout=45):
    for i, event in enumerate(pending_events):
        if predicate(event): return pending_events.pop(i), []
    deadline = time.monotonic() + timeout
    seen = []
    while time.monotonic() < deadline:
        try: event = events.get(timeout=max(.01, deadline-time.monotonic()))
        except queue.Empty: break
        seen.append(event)
        if event.get("event") == "diagnostic":
            raise AssertionError(event)
        if predicate(event): return event, seen
        pending_events.append(event)
    raise AssertionError(f"Timed out: {seen}")
report = {}
try:
    wait(lambda e: e.get("event") == "ready")
    send(dict(op="query", generation=1, text="saf"))
    first, _ = wait(lambda e: e.get("event") == "results" and e.get("phase") == "fast")
    assert first["hits"] and first["hits"][0]["title"] == "Safari", first
    report["fsearch_safari_ms"] = first["elapsed_ms"]
    wait(lambda e: e.get("event") == "results" and e.get("phase") == "semantic")
    send(dict(op="query", generation=2, text="agreement about returning an apartment security deposit"))
    result, _ = wait(lambda e: e.get("event") == "results" and e.get("generation") == 2 and e.get("phase") == "semantic")
    assert result["hits"][0]["path"] == str(fixtures / "blue-note.txt"), result
    assert result["hits"][0]["source"] == "semantic", result
    report["semantic_match"] = result["hits"][0]["title"]
    report["semantic_cosine"] = result["hits"][0]["cosine"]
    report["semantic_ms"] = result["elapsed_ms"]
    send(dict(op="query", generation=3, text="sa"))
    result, _ = wait(lambda e: e.get("event") == "results" and e.get("generation") == 3 and e.get("phase") == "fast")
    assert len(result["hits"]) > 1
    send(dict(op="cycle", generation=3, delta=1))
    selection, _ = wait(lambda e: e.get("phase") == "selected")
    pinned = selection["selected"]
    # Searches answer in any order; the last one ("complete") must keep the row the user chose.
    combined = selection if selection["complete"] else wait(lambda e: e.get("generation") == 3 and e.get("complete"))[0]
    assert combined["selected"] == pinned, (selection, combined)
    send(dict(op="open", generation=3))
    opened, _ = wait(lambda e: e.get("event") == "open")
    assert opened["path"] == pinned
    report["selection_survived_semantic_update"] = True
    send(dict(op="query", generation=4, text="vacation in Japan"))
    time.sleep(.16)
    send(dict(op="query", generation=5, text="baking a dessert with cocoa"))
    final, seen = wait(lambda e: e.get("generation") == 5 and e.get("phase") == "semantic")
    newest_pending = next(i for i,e in enumerate(seen) if e.get("generation") == 5 and e.get("phase") == "pending")
    assert all(e.get("generation",5) >= 5 for e in seen[newest_pending:]), seen
    assert final["hits"][0]["path"] == str(fixtures / "red-note.txt"), final
    report["stale_query_suppressed"] = True
    report["hidden_and_credential_files_excluded"] = True
    report["rust_backend_real_model_and_fsearch"] = True
    send(dict(op="quit")); p.wait(timeout=10)
    assert p.returncode == 0
finally:
    if p.poll() is None:
        os.killpg(p.pid, 15)
        p.wait(timeout=10)
(verify / "backend-verification.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
