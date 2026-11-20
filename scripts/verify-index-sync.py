#!/usr/bin/env python3
"""Drive the real indexing helper on a scratch tree: partial syncs, skipped kinds, long files first.

Checks that "sync <folder>" crawls only that folder and agrees with a full sync (code projects, hidden folders),
that audio and video stay out, that --wait-for-sync starts without a crawl, and that the watchdog does not count
time the helper spends stopped (SIGSTOP) as reading time.
"""
from pathlib import Path
import json, os, shutil, signal, sqlite3, subprocess, tempfile, time

root = Path(__file__).resolve().parent.parent
helper = root / "build.noindex/Swiftlight.app/Contents/Helpers/Swiftlight Indexer"
models = Path.home() / "Library/Application Support/Swiftlight/Models"
scratch = Path(tempfile.mkdtemp(prefix="index-sync-")).resolve()
tree, index = scratch / "tree", scratch / "index"
words = "Tidal turbines turn the rise and fall of the sea into electricity. " * 20
def write(path, text=words):
    path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)
write(tree / "notes/tides.md")
write(tree / "proj/package.json", "{}")
write(tree / "proj/docs/readme.md")
(tree / "proj/assets").mkdir(parents=True)
shutil.copy("/System/Library/Desktop Pictures/.thumbnails/Sequoia.heic" if Path("/System/Library/Desktop Pictures/.thumbnails/Sequoia.heic").exists() else next(Path("/System/Library/Desktop Pictures").rglob("*.heic")), tree / "proj/assets/picture.heic")
shutil.copy(next(Path("/System/Library/Sounds").glob("*.aiff")), tree / "notes/sound.aiff")
write(tree / ".hidden/secret-notes.md")
# Other people's projects stay out; your own repositories stay in.
write(tree / "others/clone/.git/config", '[remote "origin"]\n\turl = https://github.com/someone-else/project.git\n')
write(tree / "others/clone/README.md")
write(tree / "mine/.git/config", '[remote "origin"]\n\turl = git@github.com:JaneDoe/notes.git\n')
write(tree / "mine/README.md")
write(tree / "research/sources/owner__repo/README.md")
write(tree / "apk-decompiled/res/notes.md")

def start(*extra):
    return subprocess.Popen([str(helper), "index-service", str(tree), "--index", str(index), "--backfill", "--linger", "3",
                             "--skip-kind", "audio,video", "--memory-limit", "1536", "--own-git-owner", "janedoe", *extra],
                            env=dict(os.environ, DIGUP_MODELS=str(models)), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=(scratch / "helper.log").open("a"), text=True)
def finish(process, *commands, seconds=120):
    for command in commands: process.stdin.write(command + "\n"); process.stdin.flush()
    events = []
    deadline = time.monotonic() + seconds
    for line in process.stdout:
        events.append(json.loads(line))
        if events[-1]["event"] == "exit" or time.monotonic() > deadline: break
    process.stdin.close(); process.wait(timeout=30)
    return events
def files():
    db = sqlite3.connect(index / "index.sqlite")
    return {Path(p).relative_to(tree).as_posix(): (k, s) for p, k, s in db.execute("SELECT path, kind, state FROM files")}
report = {}
try:
    events = finish(start("--wait-for-sync"), "sync")
    indexed = files()
    assert set(indexed) == {"notes/tides.md", "proj/docs/readme.md", "mine/README.md"}, indexed
    assert all(state == "done" for _, state in indexed.values()), indexed
    report["full_sync_skips_audio_hidden_project_media_and_foreign_projects"] = True

    events = finish(start("--wait-for-sync"))
    assert not [e for e in events if e["event"] == "sync"], "a helper told to wait crawled on its own"
    report["wait_for_sync_starts_without_a_crawl"] = True

    write(tree / "proj/docs/more.md")
    write(tree / "notes/new.md")
    (tree / "notes/tides.md").unlink()
    events = finish(start("--wait-for-sync"), f"sync {tree / 'proj/docs'}")
    sync = [e for e in events if e["event"] == "sync"]
    assert len(sync) == 1 and sync[0]["paths"] == 1 and sync[0]["added"] == 1 and sync[0]["removed"] == 0, sync
    assert set(files()) == {"notes/tides.md", "proj/docs/readme.md", "proj/docs/more.md", "mine/README.md"}, files()
    report["partial_sync_reads_only_its_folder"] = True

    # Paths as the watcher reports them: a new file, a deleted one, a picture in a code project (its folder decides),
    # a hidden folder, and a deleted folder.
    write(tree / "notes/sub/inner.md")
    finish(start("--wait-for-sync"), f"sync {tree / 'notes/sub'}")
    assert "notes/sub/inner.md" in files(), files()
    shutil.rmtree(tree / "notes/sub")
    shutil.copy(tree / "proj/assets/picture.heic", tree / "proj/docs/diagram.heic")
    events = finish(start("--wait-for-sync"), *[f"sync {tree / p}" for p in
                    ["notes/new.md", "notes/tides.md", "proj/docs/diagram.heic", ".hidden/secret-notes.md", "notes/sub",
                     "others/clone/README.md", "research/sources/owner__repo"]])
    assert "proj/docs/diagram.heic" not in files(), "a partial sync indexed media inside a code project"
    assert "notes/new.md" in files() and "notes/tides.md" not in files(), files()
    assert not any(p.startswith((".hidden", "notes/sub", "others", "research")) for p in files()), files()
    report["partial_sync_matches_full_sync_rules"] = True

    (tree / "notes/new.md").rename(tree / "notes/renamed.md")
    events = finish(start("--wait-for-sync"), f"sync {tree / 'notes/new.md'}", f"sync {tree / 'notes/renamed.md'}")
    sync = [e for e in events if e["event"] == "sync"][0]
    assert sync["moved"] == 1 and sync["added"] == 0 and not [e for e in events if e["event"] == "file"], sync
    report["renamed_file_keeps_its_vectors"] = True

    full = finish(start("--wait-for-sync"), "sync")
    sync = [e for e in full if e["event"] == "sync"][0]
    assert sync["added"] == sync["removed"] == sync["changed"] == 0, sync
    report["full_sync_after_partial_finds_nothing_to_fix"] = True

    # A scanned book: each 30-page step is rendered and OCR'd, about 100 s here, and the next step is read while one
    # embeds. 200 s stopped in the middle of a read must not count against a 180 s limit.
    book = next(p for p in [*Path.home().glob("Downloads/**/*.pdf")] if p.exists() and p.stat().st_size > 5e6)
    shutil.copy(book, tree / "notes/book.pdf")
    process = start("--wait-for-sync", "--time-limit", "180")
    process.stdin.write(f"sync {tree / 'notes'}\n"); process.stdin.flush()
    events, resumed, rest = [], False, 0
    for line in process.stdout:
        events.append(json.loads(line))
        if events[-1]["event"] == "file" and events[-1]["path"].endswith("book.pdf") and not resumed:
            time.sleep(.5); process.send_signal(signal.SIGSTOP); time.sleep(200); process.send_signal(signal.SIGCONT); resumed = True
        if events[-1]["event"] == "rest": rest += 1
        if rest == 1: process.stdin.write("stop\n"); process.stdin.flush()
        if events[-1]["event"] == "exit" or "watchdog" in events[-1].get("message", ""): break
    process.stdin.close(); process.wait(timeout=60)
    assert resumed and rest >= 1, (resumed, rest, events[-3:])
    assert not [e for e in events if "watchdog" in e.get("message", "")], [e for e in events if e["event"] == "error"]
    assert process.returncode == 0, process.returncode
    report["paused_time_is_not_reading_time"] = True
finally:
    print(json.dumps(report, indent=2))
    shutil.rmtree(scratch, ignore_errors=True)
