#!/usr/bin/env python3
"""Prove native image indexing and direct Rust multimodal retrieval."""
from pathlib import Path
import json, os, shutil, subprocess

r = Path(__file__).resolve().parent.parent
v = r / "verification"
folder = v / "image-fixture"
index = v / "image-index"
folder.mkdir(exist_ok=True)
index.mkdir(exist_ok=True)
shutil.copyfile(v / "pill-safari.png", folder / "browser.png")
helper = r / "build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Indexer"
backend = r / "build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Search"
models = Path.home() / "Library/Application Support/Swiftlight/Models"
env = dict(os.environ, DIGUP_MODELS=str(models))
subprocess.run([str(helper), "index", str(folder), "--index", str(index)], env=env, check=True, timeout=120, stdout=(v / "image-index.log").open("w"), stderr=(v / "image-runtime.log").open("w"))
config = dict(home=str(Path.home()), helper=str(helper), index=str(index), models=str(models), auto_index=False, excluded=[])
path = v / "image-config.json"
path.write_text(json.dumps(config))
p = subprocess.Popen([str(backend), "--config", str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(v / "image-backend.log").open("w"), text=True)
p.stdin.write(json.dumps(dict(op="query", generation=1, text="Safari browser search field")) + "\n")
p.stdin.flush()
try:
    for line in p.stdout:
        e = json.loads(line)
        if e.get("event") == "diagnostic":
            raise AssertionError(e)
        if e.get("event") == "results" and e.get("phase") == "semantic":
            assert e["hits"] and e["hits"][0]["title"] == "browser.png", e
            report = dict(image_embedding_and_rust_retrieval=True, cosine=e["hits"][0]["cosine"], elapsed_ms=e["elapsed_ms"])
            (v / "image-verification.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, indent=2))
            break
    else:
        raise AssertionError("Backend exited without semantic image results")
    p.stdin.write('{"op":"quit"}\n')
    p.stdin.flush()
    p.wait(timeout=10)
finally:
    if p.poll() is None:
        os.killpg(p.pid, 15)
        p.wait(timeout=10)
