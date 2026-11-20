#!/usr/bin/env python3
"""Local-only index experiments. Never opens the live index with SQLite.

All generated databases, query text, and scratch files stay below --scratch.
JSON output contains aggregate counts/timings only. Requires Python 3.14 + numpy.
"""

import argparse
from compression import zstd
import hashlib
import json
from pathlib import Path
import re
import resource
import shutil
import sqlite3
import statistics
import struct
import time
import zlib

ROOT = Path(__file__).resolve().parent
TOKENIZER = "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'"


def guard(path):
    path = Path(path).expanduser().resolve()
    allowed = (Path.home() / ".swiftlight-research/index-design").resolve()
    if path != allowed and allowed not in path.parents:
        raise ValueError("Experiments must stay in the designated scratch directory")
    if shutil.disk_usage(allowed.parent).free < 13 * 1024**3:
        raise RuntimeError("Stopped before reaching the 12 GiB disk floor")
    return path


def connect(path):
    c = sqlite3.connect(guard(path))
    c.execute("PRAGMA cache_size=-4096")
    c.execute("PRAGMA temp_store=FILE")
    c.create_function("unpack", 1, unpack, deterministic=True)
    c.create_function("recover", 4, recover, deterministic=True)
    return c


def pack(text):
    if text is None:
        return None
    raw = text.encode("utf-8")
    compressed = zstd.compress(raw, level=3)
    return b"z" + compressed if len(compressed) < len(raw) else b"r" + raw


def unpack(blob):
    if blob is None:
        return None
    return (zstd.decompress(blob[1:]) if blob[:1] == b"z" else blob[1:]).decode("utf-8")


def reference_pack(text, candidates):
    """Use an exact byte slice of retained keyword text when smaller than a codec frame."""
    best = pack(text)
    if text is None:
        return None
    raw=text.encode("utf-8")
    for i,candidate in enumerate(candidates):
        if candidate is None:
            continue
        body=candidate.encode("utf-8")
        at=body.find(raw)
        if at>=0:
            option=b's'+bytes([i])+struct.pack('<II',at,len(raw))
            if len(option)<len(best):best=option
        # Excerpts commonly append an ellipsis to an exact source prefix.
        for suffix in (b'\xe2\x80\xa6',b'...'):
            if len(raw)>len(suffix) and raw.endswith(suffix):
                stem=raw[:-len(suffix)]
                at=body.find(stem)
                if at>=0:
                    option=b't'+bytes([i])+struct.pack('<II',at,len(stem))+suffix
                    if len(option)<len(best):best=option
        split=raw.find(b' | text: ')
        if split>=0:
            prefix=raw[:split+9];tail=raw[split+9:]
            at=body.find(tail)
            if at>=0:
                option=b'a'+bytes([i])+struct.pack('<II',at,len(tail))+prefix
                if len(option)<len(best):best=option
    assert recover(best,*(pack(v) for v in candidates))==text
    return best


def recover(blob,name,body,original):
    if blob is None:
        return None
    if blob[:1] not in (b's',b'a',b't'):
        return unpack(blob)
    candidate=(name,body,original)[blob[1]]
    raw=unpack(candidate).encode('utf-8')
    offset,length=struct.unpack('<II',blob[2:10])
    value=raw[offset:offset+length]
    return ((blob[10:] if blob[:1]==b'a' else b'')+value+(blob[10:] if blob[:1]==b't' else b'')).decode('utf-8')


def timer(f, n=1):
    values = []
    for _ in range(n):
        start = time.perf_counter()
        f()
        values.append((time.perf_counter() - start) * 1000)
    return {"median_ms": statistics.median(values), "p95_ms": sorted(values)[min(len(values)-1, int(len(values)*.95))]}


def audit(c):
    out = {"sqlite": sqlite3.sqlite_version}
    out["pragmas"] = {n: c.execute("PRAGMA " + n).fetchone()[0] for n in
                      ("page_size", "page_count", "freelist_count", "auto_vacuum", "journal_mode")}
    out["objects"] = [dict(zip(("name", "pages", "bytes", "payload", "unused", "overflow_pages"), r)) for r in c.execute(
        "SELECT name,count(*),sum(pgsize),sum(payload),sum(unused),sum(pagetype='overflow') FROM dbstat GROUP BY name ORDER BY sum(pgsize) DESC")]
    out["tables"] = {}
    tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name!='fts'")]
    for table in tables:
        cols = c.execute(f'PRAGMA table_info("{table}")').fetchall()
        data = {"rows": c.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0], "columns": {}}
        for _, name, ty, *_ in cols:
            row = c.execute(f'''SELECT count("{name}"),
                coalesce(sum(CASE WHEN typeof("{name}") IN ('text','blob') THEN length(cast("{name}" AS blob)) ELSE 0 END),0),
                sum(typeof("{name}")='integer'), sum(typeof("{name}")='real') FROM "{table}"''').fetchone()
            data["columns"][name] = dict(zip(("nonnull", "text_blob_bytes", "integers", "reals"), row))
        out["tables"][table] = data
    out["segments"] = c.execute("SELECT kind,modality,count(*),sum(length(vec)) FROM segments GROUP BY kind,modality").fetchall()
    out["vectors"] = c.execute("SELECT model,count(*),sum(length(vec)) FROM vectors GROUP BY model").fetchall()
    out["fts_segments"] = c.execute("SELECT count(DISTINCT segid) FROM fts_idx").fetchone()[0]
    out["legacy_identical_to_active"] = c.execute("SELECT sum(s.vec=v.vec),sum(s.vec IS NOT NULL) FROM vectors v JOIN segments s ON s.id=v.segment").fetchone()
    out["input_exact_body_matches"] = c.execute("SELECT sum(i.input=f.c1),count(*) FROM embedding_inputs i JOIN fts_content f ON f.id=i.segment").fetchone()
    return out


def clone(source, dest):
    guard(dest)
    if dest.exists():
        dest.unlink()
    shutil.copyfile(source, dest)
    return connect(dest)


def compact(c, pagesize=None):
    c.commit()
    c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    c.execute("PRAGMA journal_mode=DELETE")
    if pagesize:
        c.execute(f"PRAGMA page_size={pagesize}")
    c.execute("VACUUM")


def size(c):
    return c.execute("PRAGMA page_count").fetchone()[0] * c.execute("PRAGMA page_size").fetchone()[0]


def queries(c, extra):
    # Derive title, sentence, prefix and common-term queries without saving text.
    rng = __import__("random").Random(6721)
    rows = c.execute("SELECT c0,c1 FROM fts_content ORDER BY id").fetchall()
    rng.shuffle(rows)
    raw = []
    for name, body in rows:
        text = name or body or ""
        words = re.findall(r"[^\W_]+", text.lower())
        if not words:
            continue
        start = rng.randrange(max(1, len(words)-7))
        raw.append(" ".join(words[start:start+rng.choice((1,2,3,5,8))]))
        if len(raw) >= 800:
            break
    for name, _ in rows:
        if name:
            raw.append(name)
        if len(raw) >= 1000:
            break
    if extra.exists():
        raw.extend(q["query"] for q in json.loads(extra.read_text()))
    stop_match = re.search(r"const STOP_WORDS:.*?=\s*&\[(.*?)\];", (ROOT.parents[1]/"backend/src/semantic.rs").read_text(), re.S)
    stop = set(re.findall(r'"([^"]+)"', stop_match.group(1))) if stop_match else set()
    result = []
    for text in raw:
        words = list(dict.fromkeys(re.findall(r"[^\W_]+", text.lower())))
        words = ([w for w in words if w not in stop] or words)[:8]
        if words:
            result.append([f'"{w}"' + ("*" if len(w)>=3 else "") for w in words])
    return result


def keyword(c, terms):
    relaxed = len(terms) >= 3
    counts = "+".join(f"(h.id IN (SELECT rowid FROM fts WHERE fts MATCH ?{i+2}))" for i in range(len(terms)))
    if relaxed:
        sql = f'''WITH h AS (SELECT rowid AS id,bm25(fts,4.0,1.0) AS score FROM fts WHERE fts MATCH ?1 ORDER BY score LIMIT 400)
            SELECT h.id,s.file,h.score,{counts} FROM h JOIN segments s ON s.id=h.id ORDER BY h.score'''
        params = [" OR ".join(terms)] + terms
    else:
        sql = f'''SELECT fts.rowid,s.file,bm25(fts,4.0,1.0),{len(terms)} FROM fts JOIN segments s ON s.id=fts.rowid
            WHERE fts MATCH ?1 ORDER BY bm25(fts,4.0,1.0) LIMIT 64'''
        params = [" AND ".join(terms)]
    return c.execute(sql, params).fetchall()


def keyword_bench(c, qs, expected=None):
    times, wrong, score_error, ties = [], 0, 0., 0
    results = []
    for i, q in enumerate(qs):
        t = time.perf_counter()
        result = keyword(c, q)
        times.append((time.perf_counter()-t)*1000)
        if expected is not None and result != expected[i]:
            wrong += 1
            # ORDER BY bm25 has no tie breaker in production. Track equal-score reorderings separately.
            if sorted(result) == sorted(expected[i]):
                ties += 1
            old = {r[0]: r[2] for r in expected[i]}
            score_error = max(score_error, max((abs(r[2]-old[r[0]]) for r in result if r[0] in old), default=0.))
        results.append(result)
    return {"queries": len(qs), "median_ms": statistics.median(times),
            "p95_ms": sorted(times)[int(.95*len(times))], "different_queries": wrong,
            "tie_order_only": ties, "max_common_bm25_error": score_error}, results


def rebuild_fts(c, source, options="", compressed=False, tokenizer=TOKENIZER, external_plain=False):
    c.execute("DROP TABLE fts")
    if compressed:
        c.execute("CREATE TABLE keyword_payload(id INTEGER PRIMARY KEY,name BLOB,body BLOB,original BLOB)")
        for row in source.execute("SELECT id,c0,c1,c2 FROM fts_content ORDER BY id"):
            c.execute("INSERT INTO keyword_payload VALUES(?,?,?,?)", (row[0], *(pack(v) for v in row[1:])))
        c.execute("CREATE VIEW keyword_content AS SELECT id,unpack(name) AS name,unpack(body) AS body,unpack(original) AS original FROM keyword_payload")
        options += ",content='keyword_content',content_rowid='id'"
    elif external_plain:
        c.execute("CREATE TABLE keyword_content(id INTEGER PRIMARY KEY,name TEXT,body TEXT,original TEXT)")
        c.executemany("INSERT INTO keyword_content VALUES(?,?,?,?)", source.execute("SELECT id,c0,c1,c2 FROM fts_content ORDER BY id"))
        options += ",content='keyword_content',content_rowid='id'"
    c.execute(f'''CREATE VIRTUAL TABLE fts USING fts5(name,body,original UNINDEXED,tokenize="{tokenizer}"{options})''')
    for row in source.execute("SELECT id,c0,c1,c2 FROM fts_content ORDER BY id"):
        c.execute("INSERT INTO fts(rowid,name,body,original) VALUES(?,?,?,?)", row)
    c.execute("INSERT INTO fts(fts) VALUES('optimize')")
    c.commit()


def compress_columns(c, references=False):
    # Prototype read-compatible views. Production also needs write adapters and invalidation hooks.
    for table, key, column in (("segments", "id", "excerpt"), ("embedding_inputs", "segment", "input")):
        schema = c.execute(f'PRAGMA table_info({table})').fetchall()
        c.execute(f'ALTER TABLE {table} RENAME TO packed_{table}')
        # Updating the packed table must not fire source-change invalidation during this physical rewrite.
        triggers = c.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger'").fetchall()
        for name, _ in triggers:
            c.execute(f'DROP TRIGGER "{name}"')
        for ident, text in c.execute(f'SELECT {key},{column} FROM packed_{table}').fetchall():
            candidates=c.execute('SELECT unpack(name),unpack(body),unpack(original) FROM keyword_payload WHERE id=?',(ident,)).fetchone() or (None,None,None)
            encoded=reference_pack(text,candidates) if references else pack(text)
            c.execute(f'UPDATE packed_{table} SET {column}=? WHERE {key}=?', (encoded, ident))
        value=(f'recover(t.{column},k.name,k.body,k.original)' if references else f'unpack(t.{column})')
        names = [f'{value} AS {column}' if r[1] == column else 't.'+r[1] for r in schema]
        join=f' LEFT JOIN keyword_payload k ON k.id=t.{key}' if references else ''
        c.execute(f'CREATE VIEW {table} AS SELECT {",".join(names)} FROM packed_{table} t{join}')
        for _, sql in triggers:
            c.execute(sql)
    c.commit()


def logical_digest(c, table, order):
    h = hashlib.sha256()
    columns='rowid,*' if table=='fts' else '*'
    for row in c.execute(f'SELECT {columns} FROM {table} ORDER BY {order}'):
        for x in row:
            raw = x if isinstance(x, bytes) else repr(x).encode("utf-8")
            h.update(struct.pack("<Q", len(raw)))
            h.update(raw)
    return h.digest()


def update_bench(c, compressed=False, iterations=50):
    """A file rename changes name FTS rows but does not embed. Rollback each run."""
    ids = [r[0] for r in c.execute("SELECT id FROM segments WHERE kind='name' ORDER BY id LIMIT ?", (iterations,))]
    times, wal = [], 0
    c.commit()
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA synchronous=NORMAL")
    c.execute("PRAGMA wal_autocheckpoint=0")
    path = Path(c.execute("PRAGMA database_list").fetchone()[2])
    for ident in ids:
        old = c.execute("SELECT name,body,original FROM fts WHERE rowid=?", (ident,)).fetchone()
        t = time.perf_counter()
        c.execute("BEGIN")
        if compressed:
            c.execute("INSERT INTO fts(fts,rowid,name,body,original) VALUES('delete',?,?,?,?)", (ident,*old))
            c.execute("UPDATE keyword_payload SET name=? WHERE id=?", (pack("synthetic rename verification"), ident))
            c.execute("INSERT INTO fts(rowid,name,body,original) VALUES(?,?,?,?)", (ident,"synthetic rename verification",*old[1:]))
        else:
            c.execute("UPDATE fts SET name=? WHERE rowid=?", ("synthetic rename verification", ident))
        c.commit()
        times.append((time.perf_counter()-t)*1000)
        # Restore the exact old terms, including content needed by external-content delete.
        if compressed:
            c.execute("INSERT INTO fts(fts,rowid,name,body,original) VALUES('delete',?,?,?,?)", (ident,"synthetic rename verification",*old[1:]))
            c.execute("UPDATE keyword_payload SET name=? WHERE id=?", (pack(old[0]), ident))
            c.execute("INSERT INTO fts(rowid,name,body,original) VALUES(?,?,?,?)", (ident,*old))
        else:
            c.execute("UPDATE fts SET name=? WHERE rowid=?", (old[0],ident))
        c.commit()
    if Path(str(path)+"-wal").exists():
        wal = Path(str(path)+"-wal").stat().st_size
    checkpoint = timer(lambda: c.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall())
    return {"committed_renames": len(ids), "median_ms": statistics.median(times),
            "p95_ms": sorted(times)[int(.95*len(times))], "wal_bytes_including_restores": wal, "checkpoint": checkpoint}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scratch", type=Path, default=Path.home()/".swiftlight-research/index-design")
    ap.add_argument("--phase", choices=("audit", "storage", "resume", "extra"), required=True)
    args = ap.parse_args()
    scratch = guard(args.scratch)
    source = scratch/"baseline.sqlite"
    c = connect(source)
    out = audit(c)
    (scratch/"audit.json").write_text(json.dumps(out, indent=2))
    print("audit complete", flush=True)
    if args.phase == "audit":
        return
    qs = queries(c, scratch/"queries.json")
    baseline, expected = keyword_bench(c, qs)
    if args.phase == "extra":
        results = {}
        for name in ("external-plain", "unicode61"):
            p=scratch/f"fts-{name}.sqlite"
            db=clone(source,p)
            start=time.perf_counter()
            rebuild_fts(db,c,tokenizer=TOKENIZER.removeprefix("porter ") if name=="unicode61" else TOKENIZER,
                        external_plain=name=="external-plain")
            compact(db,16384)
            results[name]={"bytes":size(db),"rewrite_ms":(time.perf_counter()-start)*1000,
                           "keyword":keyword_bench(db,qs,expected)[0]}
            db.close();p.unlink()
            print("extra",name,"complete",flush=True)
        p=scratch/"incremental.sqlite"
        db=clone(source,p)
        start=time.perf_counter()
        db.execute("INSERT INTO fts(fts) VALUES('optimize')")
        db.commit()
        optimized_bytes=size(db)
        free_before=db.execute("PRAGMA freelist_count").fetchone()[0]
        db.execute("PRAGMA incremental_vacuum").fetchall()
        db.commit()
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
        results["incremental"]={"bytes":size(db),"rewrite_ms":(time.perf_counter()-start)*1000,
                                "bytes_after_optimize_before_vacuum":optimized_bytes,"free_before":free_before,
                                "free_after":db.execute("PRAGMA freelist_count").fetchone()[0],
                                "keyword":keyword_bench(db,qs,expected)[0]}
        results["incremental"]["parity"]={t:logical_digest(db,t,o)==logical_digest(c,t,o) for t,o in
                                          (("segments","id"),("embedding_inputs","segment"),("vectors","model,segment"),("files","id"),("fts","rowid"))}
        db.close()
        (scratch/"extra.json").write_text(json.dumps(results,indent=2))
        return
    results = (json.loads((scratch/"storage.json").read_text()) if args.phase=="resume" else
               {"baseline": {"bytes": size(c), "keyword": baseline}, "layouts": {}, "fts": {}})
    for page in (() if args.phase=="resume" else (4096,8192,16384,32768)):
        p = scratch/f"page-{page}.sqlite"
        db = clone(source,p)
        start = time.perf_counter()
        db.execute("INSERT INTO fts(fts) VALUES('optimize')")
        compact(db,page)
        res = {"bytes": size(db), "rewrite_ms": (time.perf_counter()-start)*1000,
               "keyword": keyword_bench(db,qs,expected)[0]}
        res["vector_scan"] = timer(lambda: sum(len(r[0]) for r in db.execute("SELECT vec FROM vectors ORDER BY model,segment")), 8)
        res["update"] = update_bench(db)
        results["layouts"][str(page)] = res
        db.close()
        p.unlink()
        (scratch/"storage.json").write_text(json.dumps(results,indent=2))
        print("layout",page,"complete",flush=True)
    variants = {"rebuilt-full":"", "column":" ,detail=column", "none":",detail=none",
                "prefix3":",prefix='3'", "prefix34":",prefix='3 4'", "columnsize0":",columnsize=0",
                "contentless":",content='',contentless_delete=1", "external-plain":"", "unicode61":"", "compressed-external":""}
    for name, options in variants.items():
        if name in results["fts"] or name in ("external-plain","unicode61"):
            continue
        p = scratch/f"fts-{name}.sqlite"
        db = clone(source,p)
        start = time.perf_counter()
        rebuild_fts(db,c,options,name=="compressed-external",
                    TOKENIZER.removeprefix("porter ") if name=="unicode61" else TOKENIZER,
                    name=="external-plain")
        if name=="compressed-external":
            compress_columns(db)
        compact(db,16384)
        count=64 if name in ("column","none","columnsize0") else len(qs)
        res = {"bytes": size(db), "rewrite_ms": (time.perf_counter()-start)*1000,
               "keyword":keyword_bench(db,qs[:count],expected[:count])[0]}
        res["objects"] = [dict(zip(("name","bytes"),r)) for r in db.execute("SELECT name,sum(pgsize) FROM dbstat GROUP BY name")]
        if name=="compressed-external":
            res["logical_parity"] = {t:logical_digest(db,t,o)==logical_digest(c,t,o) for t,o in
                                     (("segments","id"),("embedding_inputs","segment"),("vectors","model,segment"),("files","id"),("fts","rowid"))}
            res["integrity"] = db.execute("PRAGMA integrity_check").fetchone()[0]
            res["foreign_key_violations"] = len(db.execute("PRAGMA foreign_key_check").fetchall())
            db.execute("INSERT INTO fts(fts,rank) VALUES('integrity-check',1)")
            res["update"] = update_bench(db,True)
        results["fts"][name] = res
        db.close()
        if name != "compressed-external":
            p.unlink()
        (scratch/"storage.json").write_text(json.dumps(results,indent=2))
        print("fts",name,"complete",flush=True)
    results["peak_rss_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    (scratch/"storage.json").write_text(json.dumps(results,indent=2))


if __name__ == "__main__":
    main()
