#!/usr/bin/env python3
"""Drive the real indexing helper on scratch pictures: tags (colours, what Vision sees) are stored with a new picture,
and pictures indexed before tags existed get theirs without being read by the model again.

The launcher shows a picture that only half stands out by meaning when its tags hold the query's descriptive words
("red and blue screenshot"); see backend/src/semantic.rs.
"""
from pathlib import Path
import json, os, sqlite3, subprocess, tempfile, time

root = Path(__file__).resolve().parent.parent
helper = root / "build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Indexer"
models = Path.home() / "Library/Application Support/Swiftlight/Models"
scratch = Path(tempfile.mkdtemp(prefix="image-tags-")).resolve()
tree, index = scratch / "tree", scratch / "index"
tree.mkdir()

def picture(name, left, right):
    """A 400×300 PNG: its left half one colour, its right half another (macOS draws it, no Python imaging needed)."""
    swift = f"""
    import AppKit
    let image = NSImage(size: NSSize(width: 400, height: 300))
    image.lockFocus()
    NSColor(srgbRed: {left[0]}, green: {left[1]}, blue: {left[2]}, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 200, height: 300).fill()
    NSColor(srgbRed: {right[0]}, green: {right[1]}, blue: {right[2]}, alpha: 1).setFill(); NSRect(x: 200, y: 0, width: 200, height: 300).fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    """
    (scratch / "draw.swift").write_text(swift)
    subprocess.run(["swift", str(scratch / "draw.swift"), str(tree / name)], check=True, capture_output=True)

picture("field.png", (0.85, 0.15, 0.12), (0.1, 0.2, 0.9))
picture("lawn.png", (0.15, 0.7, 0.2), (0.2, 0.6, 0.15))

def run():
    process = subprocess.Popen([str(helper), "index-service", str(tree), "--index", str(index), "--backfill",
                                "--linger", "0", "--skip-kind", "audio,video", "--memory-limit", "1536"],
                               env=dict(os.environ, DIGUP_MODELS=str(models)), stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=(scratch / "helper.log").open("a"), text=True)
    events, deadline = [], time.monotonic() + 180
    for line in process.stdout:
        events.append(json.loads(line))
        if events[-1]["event"] == "exit" or time.monotonic() > deadline: break
    process.stdin.close(); process.wait(timeout=30)
    return events

def tags():
    db = sqlite3.connect(index / "index.sqlite")
    rows = db.execute("SELECT f.path, s.excerpt FROM segments s JOIN files f ON f.id = s.file WHERE s.kind = 'tags'")
    return {Path(p).name: set(filter(None, (excerpt or "").split(", "))) for p, excerpt in rows}

def vectors():
    db = sqlite3.connect(index / "index.sqlite")
    return dict(db.execute("SELECT f.path, s.id FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL"))

report = {}
run()
found = tags()
assert {"red", "blue"} <= found.get("field.png", set()), found
assert "green" in found.get("lawn.png", set()) and not {"red", "blue"} & found["lawn.png"], found
report["new_pictures_get_their_colours"] = True

# An index from before tags: the pictures are done, with vectors, and no tags.
before = vectors()
db = sqlite3.connect(index / "index.sqlite")
db.execute("DELETE FROM segments WHERE kind = 'tags'"); db.commit(); db.close()
events = run()
assert any(e["event"] == "tagged" and e["files"] == 2 for e in events), events
assert tags() == found, (tags(), found)
assert vectors() == before, "tagging read the pictures with the model again"
report["older_pictures_are_tagged_without_reembedding"] = True

events = run()
assert not any(e["event"] == "tagged" for e in events), "tagged pictures were tagged again"
report["tagging_happens_once"] = True
print(json.dumps(report, indent=2))
