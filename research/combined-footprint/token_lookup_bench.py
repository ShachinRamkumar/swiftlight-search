"""Read-only: cost of looking up token rows in a compressed table vs today's mapped BF16 table.
Uses real tokenizer output for the repository's own Markdown documents (document prompt, 2048-token chunks)
and the eight real query fixtures. Python timings include ~1 µs of call overhead per zstd call; the
production path would be Swift calling libzstd directly."""
import json, sys, time
from collections import OrderedDict
from pathlib import Path
from compression import zstd
import numpy as np
sys.path.insert(0, sys.argv[1])  # folder holding the tokenizers wheel
from tokenizers import Tokenizer

repo = Path(__file__).resolve().parents[2]
root = Path.home() / 'Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1'
table = np.memmap(root / 'token-table.bf16', dtype=np.uint16, mode='r', shape=(262144, 512))
tok = Tokenizer.from_file(str(root / 'tokenizer.json'))

docs = []
for p in sorted(list(repo.glob('*.md')) + list((repo / 'research').glob('*/REPORT.md'))):
    ids = tok.encode('title: none | text: ' + p.read_text(), add_special_tokens=False).ids
    for s in range(0, len(ids), 2046):
        part = [2] + ids[s:s + 2046] + [1]
        if len(part) >= 512: docs.append(part)
queries = [q['ids'] for q in json.loads((repo / 'research/neural-engine-storage/runtime/fixtures/manifest.json').read_text())['queries']]

def gather_raw(ids):
    return np.asarray(table[np.asarray(ids)])

def make_chunked(rows, level):
    cache = {}
    def encoded(c):
        if c not in cache:
            blk = np.ascontiguousarray(table[c * rows:(c + 1) * rows])
            cache[c] = (zstd.compress((blk >> 8).astype(np.uint8).tobytes(), level),
                        zstd.compress((blk & 0xFF).astype(np.uint8).tobytes(), level))
        return cache[c]
    def decode(c):
        h, l = encoded(c)
        hi = np.frombuffer(zstd.decompress(h), np.uint8).astype(np.uint16)
        lo = np.frombuffer(zstd.decompress(l), np.uint8).astype(np.uint16)
        return ((hi << 8) | lo).reshape(rows, 512)
    return encoded, decode

def run_chunked(rows, level, seqs, lru_chunks):
    encoded, decode = make_chunked(rows, level)
    for ids in seqs:
        for c in set(i // rows for i in ids): encoded(c)  # encode outside the timer
    lru, times = OrderedDict(), []
    for ids in seqs:
        t0 = time.perf_counter()
        out = np.empty((len(ids), 512), np.uint16)
        for n, i in enumerate(ids):
            c = i // rows
            blk = lru.get(c)
            if blk is None:
                blk = decode(c)
                if lru_chunks:
                    lru[c] = blk
                    if len(lru) > lru_chunks: lru.popitem(last=False)
            elif lru_chunks: lru.move_to_end(c)
            out[n] = blk[i - c * rows]
        times.append(time.perf_counter() - t0)
        assert np.array_equal(out, gather_raw(ids))
    return times

def ms(ts): return dict(median_ms=round(1e3 * float(np.median(ts)), 3), max_ms=round(1e3 * max(ts), 3))

for ids in docs + queries: gather_raw(ids)  # warm the page cache for the baseline
res = dict(documents=len(docs), doc_tokens_median=int(np.median([len(d) for d in docs])),
           doc_unique_tokens_median=int(np.median([len(set(d)) for d in docs])), queries=len(queries))
raw_doc = []; raw_q = []
for ids in docs:
    t0 = time.perf_counter(); gather_raw(ids); raw_doc.append(time.perf_counter() - t0)
for ids in queries:
    t0 = time.perf_counter(); gather_raw(ids); raw_q.append(time.perf_counter() - t0)
res['today_mapped_bf16'] = dict(document=ms(raw_doc), query=ms(raw_q))
for rows, level, lru in ((64, 19, 0), (16, 9, 0), (16, 9, 4096)):
    res[f'zstd_chunk{rows}_lru{lru}'] = dict(document=ms(run_chunked(rows, level, docs, lru)),
                                             query=ms(run_chunked(rows, level, queries, lru)),
                                             lru_memory_bytes=lru * rows * 1024)
print(json.dumps(res, indent=1))
(Path(__file__).resolve().parent / 'token-lookup-bench.json').write_text(json.dumps(res, indent=1))
