# Getting Swiftlight's Core AI models to DigUp's size

2026-10-27. Read-only analysis of the locally installed Core AI runtime and deduplicated storage budgets. No installed model, cache, index or app was changed. Bytes are logical unless stated. Aggregate measurements are retained in the committed JSON files in this directory (`budget.json`, `host-table-codecs.json`, `rope-regenerate.json`, `token-lookup-bench.json`, `cross-modal-sharing.json`, `audio-zero-gap.json`, `audio-zero-structure.json`).

## Where the 4.46 GB goes

Unique weights are 1.19 GB (text 273.5 MB, vision 304.1 MB, audio 611.2 MB). Today's install holds 4.46 GB: 3.01 GB of sources plus a 1.46 GB compiled cache, without audio compiled. The same text weights are stored seven times (four source packages, three compiled entries) and vision five times. DigUp's 864,676,480 bytes were one copy of each weight at Q8_0, about 8.5 bits per weight, read directly by llama.cpp.

The gap therefore comes from three multipliers: duplicate partitions, keeping the source next to its compiled copy, and FP16 instead of 8-bit weights.

## Combining

- Text: one `.aimodel` holding q32/q64/q128 and d256–d2048 was measured earlier: 283,495,256 compiled bytes, with all 44 tested output pairs bit-identical to the current models.
- Text + vision + audio in one file: no further saving. The three modalities share 0 of their 776 weight blobs (`cross-modal-sharing.json`). One file would also force audio to compile and repair together with text.

## New lossless findings

| Item | Now | Lossless | How | Evidence |
|---|---:|---:|---|---|
| Token table | 268,435,456 | 175,907,847 | BF16 split into exponent/mantissa byte planes, zstd per 64 rows, 63 µs per chunk | `host-table-codecs.json` |
| Vision position table | 31,457,280 | 2,580,480 | `VisionHostPrep.target` allows at most 2,520 patches with both sides multiples of 3, so coordinates stop at 839 of 10,240 | `VisionHostPrep.swift:23-33,128` |
| Vision cos/sin | 1,310,848 | 107,648 | Same 840-row bound | same |
| RoPE tables | 12,487,173 | 6,291,456 | All 24 tables are exact prefixes of the four 2048 tables (channel-major layout) | `rope-regenerate.json` |
| tokenizer.json | 32,170,510 | 3,923,175 | zstd 19 (already APFS-compressed to ~7.5 MB on disk) | `host-table-codecs.json` |

Host and support files go from 346,411,818 to 189,363,722 bytes with identical contents.

Audio weights are 36% exact zeros. Smallest non-zero magnitudes sit at ~0.018 with nothing between 0 and that value, which indicates magnitude pruning rather than padding or FP16 underflow (`audio-zero-gap.json`). A bitmask-plus-values encoding would be ~0.70× losslessly, but no test has shown that Core AI keeps sparse weights compact on the Neural Engine.

## Lossless ceiling

With audio installed, no bit-exact `.aimodel` setup can reach DigUp's size. Unique FP16 weights alone are 1.19 GB. Even a perfect sparse audio encoding leaves ~1.01 GB before any table. Getting under 865 MB means either leaving audio off disk or using 8-bit weights. Earlier runs measured 8-bit per-channel as the only compression that both stays compact after compilation and runs at full speed on this M1's Neural Engine. INT4, LUT4 and LUT6 failed: too slow, too inaccurate, or no Neural Engine output.

## Options (steady state, sources deleted after persistent specialization)

| Option | Bytes | × DigUp | Quality |
|---|---:|---:|---|
| Today (measured) | 4,464,094,435 | 5.16 | — |
| Earlier best: merged text, raw hosts, audio resident (measured) | 1,565,079,618 | 1.81 | exact |
| **A: merged text + vision exact, lossless hosts, audio downloaded on enable** | **792,318,858** | **0.92** | **bit-identical** |
| A after enabling audio at FP16 | 1,408,031,522 | 1.63 | exact |
| A after enabling audio at INT8 (estimate) | 1,103,640,081 | 1.28 | audio new, text/vision exact |
| B: everything 8-bit, all modalities resident (estimate) | 774,827,460 | 0.90 | q32 min cosine 0.99969; needs reindex |
| C: A, with audio through macOS Speech + SoundAnalysis | 792,318,858 | 0.92 | text/vision exact; audio becomes transcript + sound tags |

INT8 estimates scale each measured FP16 compiled size by the saving measured on q32 (0.498 bytes per weight byte; the q32 prediction is within 0.4%). Not counted: OS-managed Neural Engine artifacts (unreadable), the indexer's 107 MB Metal shader cache (OS-purgeable), the index, the app, download/compile peaks, and macOS speech assets for C. `budget.json` holds every term.

## Costs of option A

- Repair after an OS update or cache purge needs a download and about 4.5 minutes of preparation for the merged text model. Name and keyword search keep working during that time.
- q32 can no longer be repaired on its own.
- Fresh-process first calls were slower in the earlier merge test (q64 53 ms vs 32 ms). Warm calls matched.
- Token lookups decode compressed chunks: up to ~2 ms per 32-token query with zstd chunks, or microseconds with a row-addressable entropy coder (bound 178 MB).

## Speed

Merged-text timings below summarize earlier isolated ANE benchmark measurements (24 warm calls, 6 fresh-process first calls per function). The token-table timings are recorded in `token-lookup-bench.json` (real tokenizer output for this repository's Markdown and the eight query fixtures, Python calling libzstd).

| What | Today | Option A | Effect in the app |
|---|---:|---:|---|
| Warm inference, all 7 text functions | q64 6.41 ms … d2048 379.5 ms | within −0.1% to +2.1% | None measurable |
| First call in a new process, q32 | 20.7 ms | 47.6 ms | Hidden: the embedder already runs two warm-up queries at load (`CoreAIEmbedder.swift:426-429`) |
| First call, q64 / q128 | 31.8 / 36.2 ms | 53.4 / 56.9 ms | ~21 ms on the first long query after the query model starts; warming q64/q128 too would hide it |
| First call, d256–d2048 | — | +4.7 to +7.8 ms | Indexer only |
| Token lookup per query | 0.003 ms | 0.17–0.56 ms | Negligible next to the 60 ms pause |
| Token lookup per document chunk (median 1,326 tokens) | 0.14 ms | 29–40 ms uncached; 3.3 ms with a 64 MB chunk cache | Up to ~10% slower indexing without a cache, under 1% with it |
| Preparation after an OS update | q32 alone ~69 s | merged text 249 s | Semantic search returns later, plus download time |

## Reproduce (requires local Core AI runtime assets)

The scripts below read the locally prepared Core AI runtime assets (excluded from Git) and require Python 3.14 (`compression.zstd`) and NumPy. The resulting aggregate JSON files are already committed in this directory.

```sh
python3 -I research/combined-footprint/cross_modal_sharing.py
python3 -I research/combined-footprint/audio_zero_structure.py
python3 -I research/combined-footprint/audio_zero_gap.py
python3 -I research/combined-footprint/host_table_codecs.py
python3 -I research/combined-footprint/rope_regenerate.py
python3 -I research/combined-footprint/budget.py
```
