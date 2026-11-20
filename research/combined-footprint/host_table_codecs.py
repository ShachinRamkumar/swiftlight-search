"""Read-only: lossless encodings of the BF16 host tables with per-row random access.
Codec: rows grouped into chunks; each chunk's BF16 values are split into a high-byte plane
(sign + 7 exponent bits) and a low-byte plane (1 exponent bit + 7 mantissa bits), and each plane
is compressed with zstd. A lookup decodes one chunk. Also reports order-0 entropy bounds."""
import json, sys, time
from pathlib import Path
from compression import zstd
import numpy as np

root = Path.home() / 'Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1'
tables = {'token-table.bf16': (262144, 512), 'vision-host/position-table.bf16': (2 * 10240, 768)}

def entropy(counts):
    p = counts[counts > 0] / counts.sum()
    return float(-(p * np.log2(p)).sum())

results = {}
for name, (rows, cols) in tables.items():
    raw = np.memmap(root / name, dtype=np.uint16, mode='r', shape=(rows, cols))
    hi_counts = np.zeros(256, np.int64); lo_counts = np.zeros(256, np.int64)
    for s in range(0, rows, 8192):
        blk = np.asarray(raw[s:s + 8192])
        hi_counts += np.bincount((blk >> 8).ravel().astype(np.uint8), minlength=256)
        lo_counts += np.bincount((blk & 0xFF).ravel().astype(np.uint8), minlength=256)
    n = rows * cols
    res = dict(rows=rows, cols=cols, raw_bytes=n * 2,
               hi_entropy_bits=entropy(hi_counts), lo_entropy_bits=entropy(lo_counts))
    res['order0_bound_bytes'] = int(n * (res['hi_entropy_bits'] + res['lo_entropy_bits']) / 8)
    for chunk_rows, level in ((16, 9), (64, 9), (64, 19)):
        total = 0; t0 = time.perf_counter(); decode_s = 0.0; samples = 0
        rng = np.random.default_rng(0)
        for s in range(0, rows, chunk_rows):
            blk = np.ascontiguousarray(raw[s:s + chunk_rows])
            hi = (blk >> 8).astype(np.uint8).tobytes(); lo = (blk & 0xFF).astype(np.uint8).tobytes()
            ch, cl = zstd.compress(hi, level), zstd.compress(lo, level)
            total += len(ch) + len(cl) + 8  # 8-byte offset entry per chunk
            if rng.random() < 0.01:
                d0 = time.perf_counter()
                h2 = np.frombuffer(zstd.decompress(ch), np.uint8).astype(np.uint16)
                l2 = np.frombuffer(zstd.decompress(cl), np.uint8).astype(np.uint16)
                back = ((h2 << 8) | l2).reshape(blk.shape)
                decode_s += time.perf_counter() - d0; samples += 1
                assert np.array_equal(back, blk), 'lossless round trip failed'
        res[f'zstd{level}_planes_chunk{chunk_rows}'] = dict(bytes=total, ratio=total / (n * 2),
            encode_s=round(time.perf_counter() - t0, 2), verified_chunks=samples,
            mean_chunk_decode_us=round(1e6 * decode_s / max(1, samples), 1))
    results[name] = res
    print(name, json.dumps(res, indent=1), flush=True)

tok = root / 'tokenizer.json'
data = tok.read_bytes()
results['tokenizer.json'] = {f'zstd{l}': len(zstd.compress(data, l)) for l in (9, 19)} | {'raw_bytes': len(data)}
print(results['tokenizer.json'])
Path('host-table-codecs.json').write_text(json.dumps(results, indent=1))
