#!/usr/bin/env python3
"""Publish only aggregate measurements from local scratch into this checkout."""
import json
from pathlib import Path
from study import ROOT


def mb(n):return f'{n/1e6:,.2f}'
def ms(d):return f"{d['median_ms']:.2f} / {d['p95_ms']:.2f}"


def main():
    scratch=Path.home()/'.swiftlight-research/index-design'
    names=('audit','column-bytes','source-sizes','storage','extra','vectors','references','parity','rust-parity','profile','updates','loader','binary','validation','retired','wal')
    data={n:json.loads((scratch/(n+'.json')).read_text()) for n in names}
    (ROOT/'measurements.json').write_text(json.dumps(data,indent=2)+'\n')
    a=data['audit'];s=data['storage'];r=data['references'];v=data['vectors'];p=data['profile'];u=data['updates'];l=data['loader']
    baseline=s['baseline']['bytes'];target=r['bytes'];compact=s['layouts']['16384']['bytes']
    physical='\n'.join(f"| {x['name']} | {x['bytes']:,} | {x['payload']:,} | {x['unused']:,} | {x['overflow_pages']:,} |" for x in a['objects'])
    columns='\n'.join(f"| {t}.{name} | {value['value_bytes']:,} | {value['serial_type_bytes']:,} |" for t in ('files','segments','embedding_inputs','vectors','fts_content') for name,value in data['column-bytes'][t]['columns'].items())
    options='\n'.join(f"| {name} | {mb(x['bytes'])} | {ms(x['keyword'])} | {x['keyword']['different_queries']} / {x['keyword']['queries']} |" for name,x in s['fts'].items())
    pages='\n'.join(f"| {page} | {mb(x['bytes'])} | {ms(x['vector_scan'])} | {ms(x['keyword'])} | {mb(x['update']['wal_bytes_including_restores'])} |" for page,x in s['layouts'].items())
    profile='\n'.join(f"| {mode} | {x['startup_ms']:.1f} | {x['increase_bytes']/2**20:.1f} | {x['peak_rss_bytes']/2**20:.1f} |" for mode,x in p.items())
    updates='\n'.join(f"| {mode} | {ms(x['insert'])} | {ms(x['delete'])} |" for mode,x in u.items())
    wal='\n'.join(f"| {mode} | {ms(x)} | {mb(x['peak_wal_bytes'])} | {x['passive_before_reader_release'][2]} / {x['passive_before_reader_release'][1]} |" for mode,x in data['wal'].items())
    vector_rows='\n'.join(f"| {policy} | {x['rows']:,} | {ms(x['latency']['int8'])} | {ms(x['latency']['fp16-f32'])} | {ms(x['latency']['fp16'])} |" for policy,x in v['scoring'].items())
    text=f'''# Swiftlight index design

Measured locally on the 8 GB M1, 2026-11-03. MB means decimal megabytes; MiB means 1,048,576 bytes. Source code and aggregate measurements are committed. All databases, text, query strings, vector files, logs, generated Rust, and build output remain in `~/.swiftlight-research/index-design/`.

## Recommendation and implementation status

Keep SQLite, 16 KiB pages, full-detail Porter/unicode61 FTS, its token-count table, and the existing SIMD scorer. Store canonical text once when an exact byte reference is possible; otherwise retain it through a tagged lossless codec. Keep vectors in SQLite as fp16. The measured format is **{target:,} bytes, {mb(target)} MB**, {100*(1-target/baseline):.1f}% below the current database. It retains both model generations, every prompt byte, original text, all excerpts, catalog rows, and both image-selection policies.

The new text format is a **working research prototype, not a production schema migration**. It needs coordinated Swift and Rust storage adapters. Python views/functions prove the format and search parity, but the shipped Swift writer cannot use these views unchanged. The source-change invalidation hook currently watches `fts_content`, which external-content FTS removes. Publishing this schema without replacing that hook would break writes and stale-vector invalidation. The backend-only improvements below are implemented and tested; the text-format integration remains future work.

Implemented now:

- [Backend compaction command](../../backend/src/bin/compact-index.rs). Explicit path only; no app startup hook or implicit live-index path. Its versioned `storage_compaction_v1` marker commits with FTS optimization, resumes at vacuum after interruption, and makes subsequent runs no-ops. Same schema, page size, model identity and search values. The command produced **{compact:,} bytes, {mb(compact)} MB** on a separate copy, saving {mb(baseline-compact)} MB.
- [Vector loader](../../backend/src/semantic.rs). Removes the forced materialization of model vectors while preserving explicit segment ordering, all fields, model/modality selection and incremental file filters. The full SQL scan dropped from {l['baseline']['all']['materialized']['median_ms']:.1f} to {l['baseline']['all']['direct']['median_ms']:.1f} ms for the all-Core-AI policy, and {l['baseline']['text']['materialized']['median_ms']:.1f} to {l['baseline']['text']['direct']['median_ms']:.1f} ms for the mixed policy. Whole-row equality passed on both original and prototype databases. This reads stored vectors only and does not initialize a model.

The compaction command is deliberately explicit. It does not install or automatically run a maintenance job. It may briefly block writers during `VACUUM`; run it during an indexing pause. WAL readers can continue, but long readers can retain old WAL frames. Its final passive checkpoint reports this rather than forcing readers to finish.

## Snapshot and current storage

Files were copied through ordinary file reads before any SQLite connection was opened. The copied database/WAL passed full `integrity_check`, then SQLite backup made the baseline. No live SQLite connection, live write, app launch/termination, Core AI call, model embedding, Neural Engine job, or Core AI cache access was used. File copying a changing WAL is not an atomic live backup guarantee; integrity, foreign-key, and FTS checks validate the captured copy, rather than claiming a globally instantaneous source snapshot.

The copy contains 4,209 files, 36,713 segments, 26,599 active vectors and 21,874 legacy vectors. Counts grew since the task's initial inventory. Segment kind counts include both vector-bearing and keyword-only rows; actual per-kind/per-modality counts are in `measurements.json`.

| Component | Bytes | MB |
|---|---:|---:|
| Database | {baseline:,} | {mb(baseline)} |
| Captured WAL | {data['source-sizes']['index.sqlite-wal']:,} | {mb(data['source-sizes']['index.sqlite-wal'])} |
| Shared-memory file | {data['source-sizes']['index.sqlite-shm']:,} | {mb(data['source-sizes']['index.sqlite-shm'])} |
| Logs and cost metadata | 16,850,845 | 16.85 |
| Entire captured directory | {sum(data['source-sizes'].values()):,} | {mb(sum(data['source-sizes'].values()))} |

The WAL holds 891 16-KiB frames plus headers. It contains page versions, not additional unique vector payload. The main file has 17,247 pages, including 1,320 free pages, **21,626,880 bytes**. `dbstat` accounts for 260,849,664 bytes of b-trees; another 98,304 bytes are incremental-auto-vacuum pointer-map pages. These three figures reconcile to the database byte count exactly. `auto_vacuum=INCREMENTAL` is already enabled. The captured log sizes grow with activity, independently of the number of currently indexed files.

| Object | Allocated bytes | Record payload bytes | Unused bytes inside pages | Overflow pages |
|---|---:|---:|---:|---:|
{physical}

FTS has 18 posting segments. `optimize` and compaction reduce `fts_data` from 61,145,088 to 27,557,888 bytes. This is the largest immediate saving. `fts_content` holds 55,515,423 bytes of text plus record headers; FTS posting data and content are different things. Full-detail postings are needed to retain current scoring. There are currently no optional prefix indexes to remove.

Active fp16 payload is 40,856,064 bytes. Legacy fp16 payload adds 33,598,464 bytes. None of the 21,874 paired legacy vectors equals its active counterpart. Retired-model status does not make these bytes removable: `image_vectors` and `audio_vectors` default to legacy in the backend. The prototype preserves the fallback/rollback data. The one 16-bit `EmbeddingGemma2.aimodel` change does not justify changing `coreai-eg2-v1`, rewriting document vectors, or changing calibration.

A separately measured retirement variant removes only the legacy **text** vectors, while retaining legacy image vectors. It is {data['retired']['bytes']:,} bytes, {mb(data['retired']['bytes'])} MB. Selected vector rows and every selected field remain identical under both Core AI image policies because Core AI always selects its text from `vectors`. This variant deliberately gives up legacy-text rollback and non-Core-AI text search, so it is conditional on that product decision. It is not the conservative recommendation and is not implemented as a backend migration. Ordinary `UPDATE segments SET vec=NULL` would fire invalidation triggers and delete active vectors; even this physical retirement needs a coordinated schema migration. The experiment suspended/restored those triggers only on an expendable copy.

Paths use 481,659 value bytes in `files`, with another path-bearing unique b-tree occupying 655,360 bytes. This duplication is small and supports lookups, scope ranges and uniqueness. Keep it. Keep the revision hashes and their foreign-key index; they prevent stale vector publication. `fts.original` is non-NULL for 3,398 rows. Canonical Unicode equivalence is insufficient to recover exact prompt bytes, so never discard originals or reconstruct titles from today's filenames without a byte equality check.

Growth follows segments and token counts more closely than file count. The current physical `files` table averages 214 bytes/file, its path index 156 bytes/file, and the inode/state indexes together about 47 bytes/file. Each file also creates a name segment and FTS row. Content averages 8.72 segments and 6.32 active vectors per file on this snapshot, with large variation by document length. Each additional active segment adds 1,536 raw vector bytes, revision metadata, text/prompt storage and FTS postings proportional to its tokens; a retained legacy vector adds another 1,536 bytes. Free pages, merge debt and WAL are workload-dependent overhead. Logs grow with operations, and retained model generations grow with model coverage, rather than with names alone.

### Exact per-column values

[column_bytes.py](column_bytes.py) reads SQLite record headers and serial types, including records promoted into WITHOUT ROWID interior pages. It reconciles serialized value bytes and header bytes against `dbstat.payload` for all 22 objects. This avoids the incorrect practice of counting an integer's decimal string as its disk representation. Rowid-alias primary keys consume zero value bytes in the record; b-tree rowid varints remain structural overhead. Page allocation cannot be uniquely assigned to individual columns, so the following separates serialized column bytes from physical object allocation above. The JSON also includes exact secondary-index and FTS-internal column accounting.

| Column | Serialized value bytes | Serial-type header bytes |
|---|---:|---:|
{columns}

## Storage alternatives

All FTS variants use the same retained input bytes, weights `bm25(fts,4.0,1.0)`, production AND/OR branching, limits 64/400, and coverage-count subqueries. Queries comprise 800 sampled text fragments, 200 names, and 29 held-out local evaluation queries. No query text is persisted in the report. Times below are warm filesystem measurements, median / p95 in milliseconds, on a swapping, shared machine. Small differences between runs are not controlled performance claims.

| FTS/database variant | Total MB | Keyword median / p95 ms | Different queries / tested |
|---|---:|---:|---:|
| Current database | {mb(baseline)} | {ms(s['baseline']['keyword'])} | 0 / 1029 |
{options}
| External content, uncompressed | {mb(data['extra']['external-plain']['bytes'])} | {ms(data['extra']['external-plain']['keyword'])} | 0 / 1029 |
| Remove Porter stemming | {mb(data['extra']['unicode61']['bytes'])} | {ms(data['extra']['unicode61']['keyword'])} | 695 / 1029 |
| External content + exact references + codec fallback | {mb(target)} | {ms(r['keyword'])} | 0 / 1029 |

`detail=column` and `detail=none` changed ordered BM25 results and were much slower. Reject them. `columnsize=0` saved only 458,752 bytes and forced expensive token counting. Keep `fts_docsize`. Prefix 3 is lossless on the sample but adds 17.5 MB for a modest latency gain; prefix 3+4 adds another 15.6 MB. Keep no prefix index under the disk/memory objective. Changing tokenizer/stemming changes retrieval and is rejected.

Contentless-delete is 164.5 MB and keeps these MATCH/BM25 results, but removes all stored FTS text. That text is read for input reconstruction, original display, and source identity snapshots. Its smaller number is not a valid quality-preserving design. Plain external content just moves the same bytes and does not save space.

The lossless external-content prototype stores each name/body/original value with raw or Zstandard-level-3 encoding, whichever is smaller. Embedding inputs and excerpts use the same codec. Exact-reference encoding then eliminates duplicate text in 23,916 embedding inputs. Each stores the original prompt prefix and byte offset/length into retained keyword text. Exact source slices serve 110 excerpts; another 3,593 retain their literal ellipsis suffix separately. Every other value has a complete raw/compressed fallback. No Unicode normalization, prompt generation, extraction, model call or source-file access is needed to decode it. Logical hashes include FTS rowids.

The prototype's `packed_embedding_inputs` falls from 46.7 MB to 3.1 MB. `keyword_payload` is 28.3 MB, FTS postings 27.6 MB, packed segments about 41.4 MB including legacy vectors, active vector table 43.6 MB, and the rest is indexes/metadata. Reference decoding occurs when text is requested; the full-detail keyword path and vector path do not need to decode corpus text. Byte-exact dictionary deduplication could remove at most another 5.3 MB of uncompressed body duplication before accounting for dictionary indexes, references and existing compression. It was counted, not implemented or claimed as a measured net saving.

### Page layout and maintenance

Each page-size candidate uses FTS optimization and vacuum first. Vector-read times here are raw SQLite BLOB scans, not model inference or similarity scoring. The rename workload makes 50 committed name updates and 50 restoring updates with automatic checkpoint disabled, then truncates WAL.

| Page bytes | Total MB | Vector read median / p95 ms | Keyword median / p95 ms | Rename WAL MB |
|---|---:|---:|---:|---:|
{pages}

Keep 16 KiB. 4 KiB pages cause overflow for the WITHOUT ROWID vector records and increase total size above today's database. 32 KiB saves only 3.2 MB over 16 KiB and roughly doubles rename WAL traffic. On the current auto-vacuum layout, FTS optimization plus fully draining `incremental_vacuum` gives 226,983,936 bytes in 750 ms. Full vacuum gives 223,854,592 bytes in about 1.65 seconds on the layout experiment. The shipped helper's existing `compactIfSparse` requires 25% free and at least 32 MB; this snapshot's 7.65% / 21.6 MB does not trigger it, and much FTS waste is still inside live posting trees.

For ongoing maintenance, keep file-level transactions, incremental auto-vacuum and bounded FTS merges while idle. Return a bounded page budget between indexing batches, rather than vacuuming on every update. A separate sweep makes 200 committed name updates per policy on fresh compacted copies, with `synchronous=NORMAL` and an 8 MiB journal reset limit:

| Auto-checkpoint pages and reader state | Update median / p95 ms | Peak WAL MB | Frames checkpointed / present before reader release |
|---|---:|---:|---:|
{wal}

The 256-page threshold held short-reader WAL near 4.25 MB in this workload. With a pinned reader, every threshold reached 13.37 MB and checkpointed zero frames until that reader released its snapshot. This directly demonstrates why `journal_size_limit=8388608` is not a hard WAL cap. Start with `wal_autocheckpoint=256` at 16 KiB, and measure sustained fsync/battery behavior before making it the default. Use passive checkpoints during work; reserve truncate for idle periods without pinned readers. Rotate debug/indexing logs with a separate budget, since they can outgrow reclaimed database pages.

These WAL budgets and periodic maintenance settings are recommendations backed by the limited sweep, not deployed configuration changes or sustained-indexing/battery measurements. Only the explicit compaction migration and loader change ship in backend code here.

## Vector layout, scoring and exactness

| Selected vectors | Rows | Existing int8 SIMD median / p95 ms | fp16 to fp32 SIMD median / p95 ms | fp16 with f64 accumulation median / p95 ms |
|---|---:|---:|---:|---:|
{vector_rows}

The fp16 reference decodes the stored half values and accumulates products in f64, then rounds each cosine once to f32. It does not renormalize or replace stored vectors. It is a numerical reference, not today's backend scoring algorithm. The fp32 SIMD version changes accumulation order; even that small numerical change changed a top-20 ordering in one all-Core-AI query and a confirmed-gate decision in one mixed-policy query. Do not introduce it under a bit-identical quality contract.

The active vector table is 44,974,080 allocated bytes before compaction. A raw packed file is 40,856,064 bytes, but with a 64-byte identity/revision/offset manifest per row it is 42,558,400 bytes. The compacted SQLite vector table is 43,614,208 bytes. The roughly 1.1 MB saving against compacted SQLite does not justify a second transactional store, crash recovery, tombstones and an append-log compactor at this scale. Row compression saves little and complicates constraints/readers.

Measured lossless compression of 256-row vector blocks:

| Codec | Packed MB including offsets | Decode median / p95 ms |
|---|---:|---:|
| Raw fp16 | {mb(v['compression']['raw_bytes'])} | no decoding |
| zlib 6 | {mb(v['compression']['zlib']['bytes_including_8byte_block_offsets'])} | {ms(v['compression']['zlib']['decode'])} |
| Zstandard 3 | {mb(v['compression']['zstd']['bytes_including_8byte_block_offsets'])} | {ms(v['compression']['zstd']['decode'])} |
| Byte shuffle + Zstandard 3 | {mb(v['compression']['shuffled-zstd']['bytes_including_8byte_block_offsets'])} | {ms(v['compression']['shuffled-zstd']['decode'])} |

All block decoders reproduced every byte. zlib per-row uses 39,690,861 bytes; Zstandard per-row uses 39,404,974 bytes versus 40,856,064 raw, before row framing. Block shuffling saves more but costs startup work and turns one-row changes into block rewrites. Keep raw fp16 in SQLite for the recommended balance. The 1.6 ms packed mmap page-touch measurement is only a page touch, not a dot-product scan; it must not be compared to a full SQLite scan as if the work were equal.

The current backend already quantizes both documents and queries to signed int8 and directly uses those scores. On 512 stored-vector queries per image policy, current int8 versus the fp16 reference changed 416 / 420 file top-20 lists. Gate flips at 4.5, 2.5, 3.0 were [754,4732,2650] / [810,4564,2332]. Maximum z error was about 0.128 / 0.129. This is evidence against treating quantization as exact, not evidence of worse user relevance. True text-query embeddings and judged relevance were deliberately not evaluated.

Selecting 20 int8 candidates missed exact top-20 membership for 146 / 155 queries. Selecting 64 or 256 missed none in this sample, which is not a universal guarantee. Binary sign codes use 2,553,504 bytes and scan in {data['binary']['median_ms']:.3f} ms, but missed exact top-20 membership in 38/128 queries at 64 candidates, 4/128 at 256 and 1/128 even at 1024. Reject fixed-count binary or int8 prefilters as quality-preserving replacements.

An admissible quantized bound can use residual norms: with restored approximations v̂ and q̂, the dot error is at most ||q||₂||v−v̂||₂ + ||v̂||₂||q−q̂||₂, plus floating-point evaluation bounds. A safe algorithm must refine until every rejected upper bound falls below the selected kth lower bound, allowing for different group means. This still does not produce identical reported z-scores: the group means and global standard deviation depend on every calibration row, including rows outside the candidate set. Analytic first/second moments reproduce real-arithmetic statistics, not the existing per-row f32 rounding followed by ordered f64 reductions. Exact top-k rescore alone is insufficient. Returning identical z-scores requires the full scoring population, or an independently proven exact aggregate algorithm with conservative fallback. The existing 0.4–0.5 ms full int8 scan is already cheap. Keep it.

## Memory, startup and updates

The scoring arrays contain 20,534,428 bytes of int8 codes plus scales for 26,599 rows. An fp16 mmap scan needs 40,856,064 mapped bytes once all pages are touched. Building int8 codes from the mmap touches both matrices, about 61.4 MB. A packed file is not free memory. A persisted mmap of int8 codes could reduce reload cost, but adds approximately 20.5 MB of redundant disk cache plus generation/crash invalidation machinery; it was not implemented.

Fresh-process profiles use five processes per option, a 4 MiB SQLite cache, file-backed temp storage, and the same C quantizer/scorer. They include Python/NumPy overhead and are not whole-app RSS. The interpreter/import peak is about 34 MiB, so the increase is more useful than the total. Startup includes row fetch, half decoding and int8 conversion; it excludes model loading, walking files, frontend launch, and cold-boot disk-cache behavior. No system caches were purged during measurement. `*-direct` uses the implemented direct loader branch; the old modes force materialization. The full UNION/metadata SQL timing and row parity are separately captured in `loader.json` within the measurements bundle.

| Mode | Startup ms | RSS increase MiB | Total peak RSS MiB |
|---|---:|---:|---:|
{profile}

The recommended scorer's resident matrix stays the same 20.5 MB. Text compression does not add a decompressed corpus cache. Startup favors removing materialization over creating a vector sidecar. The Python import baseline is not part of the shipping Rust app, and these measurements do not establish any Core AI model-memory saving.

Each ingest/delete benchmark performs 50 committed cycles on a fresh disposable database. A cycle adds a synthetic file and one representative existing text segment, exact retained input, FTS data and fp16 vectors, then deletes the file through the appropriate adapter. It excludes extraction and model inference. New reference inputs/excerpts were decoded and compared after every insert. Both SQLite and FTS integrity checks and foreign-key checks passed after the cycles.

| Format | Ingest median / p95 ms | Delete median / p95 ms |
|---|---:|---:|
{updates}

These are representative single-segment transactions, not sustained indexing throughput or concurrent multi-writer stress tests. Reference format committed renames measured {ms(r['update'])} ms. Deleting a real multi-segment file, verifying cascaded vector removal, and replacing source text with atomic vector invalidation were also exercised and rolled back. Crash/retry and compaction-marker behavior have four backend unit tests. New codec tests cover raw/compressed values, NULL/empty strings, embedded NULs, Unicode normalization differences, byte offsets, original titles, ellipsis suffixes and 1,500 generated Unicode references.

## Parity evidence and limits

- Every decoded field and ordered FTS rowid matches the baseline for `files`, `segments`, `embedding_inputs`, `vectors`, and FTS. Catalog/model/failure/revision-identity values and all metadata except the intentional compaction marker also match in final validation. SQLite, FTS integrity and foreign-key checks pass.
- All 1,029 keyword queries have identical ordered candidate rows, coverage counts and f64 BM25 values in both lossless formats and the compacted database. No tolerance or tie-order exception was needed. Identical candidate fields imply identical downstream name, scope, coverage and merge behavior for the same query/configuration. Full frontend interaction was not run.
- For each migrated database, 512 stored document vectors per supported image policy, 1,024 per database, produce identical complete f32 score arrays. Exact row identities, scales, calibration masks and ordered scores imply identical `meaning()` values, every top-k for any k, and every gate decision, including confirmed-image gates for any unchanged confirmation set. The actual Rust `quantize`, NEON `dot_rows`, and `meaning` functions were extracted and compiled locally; 32 query replays, 851,168 row scores and z-scores, match the C/Python replicas bit-for-bit with zero z error.
- Name metadata, file IDs/paths, tags, mtime, clip ranges, scope data, model key, revisions and all vector blobs are retained. No re-embedding occurs. Document-vector stand-ins test numeric/storage parity; they do not estimate relevance for new natural-language queries.
- The external-content writer adapter is demonstrated in Python, including source-change invalidation and rollback, but is not integrated into Swift. Its old `fts_content` update hook cannot survive this schema unchanged. This is the remaining production-integration requirement, not an omitted quality mismatch.

## Migration plan

1. Ship the direct loader change and the explicit compaction command first. Both work with schema 12. The command has no implicit target and was executed only against `backend-compacted.sqlite`. The runtime model and index remain untouched by this work.
2. For the text format, add one shared, versioned codec to both readers. Keep the current model key and generation identity rules. A raw/compressed/reference tag must be understood before any writer changes; preserve exact UTF-8 byte offsets, prompt prefixes, originals and revision hashes.
3. Implement writable storage methods in DigUp and matching Rust decode/view support. Replace the `fts_content` update hook with explicit same-transaction invalidation on canonical text changes. External FTS updates must delete old postings while old text is still available, update canonical payloads/references, and insert new postings. Source changes must invalidate dependent prompt references and vectors before publication; a same-byte codec rewrite must not change the content revision or schedule embeddings.
4. Extend the real Swift migration and integration tests to cover incremental ingestion, rename, OCR updates, PDF replacement, file deletion, re-embedding activation/rollback, unavailable sources, and process interruption. Preserve FKs, source-generation triggers and the complete/active catalog rules. The Python views are a format proof, not the deployment implementation.
5. Build a candidate database beside the old database with a 4 MiB cache and file-backed temporary storage, using one consistent read snapshot or a captured change log. Stream rows. The prototype rewrite took {r['migration_ms']/1000:.2f} seconds. Verify all decoded fields, revision hashes, FTS postings and ordered query outputs before cutover. Recheck source generation under the writer lock so a migration cannot lose intervening updates.
6. Pause writers for atomic same-volume cutover. Close old SQLite connections before handling the database/WAL pair; never rename only a live main database while its WAL is active. Keep a rollback copy until new readers and writers validate, then remove it. At this snapshot scale, budget around 1 GB of temporary headroom plus the user's required 12 GiB free floor. Do not keep both formats permanently.
7. Apply bounded idle merges, incremental page return, and measured checkpoint/log rotation policy. Updates stay per-file transactional; no whole-index rebuild, ANN graph, model migration or lossy canonical storage is needed.

## Reproduction and sources

The scripts require Python 3.14 with `compression.zstd`, NumPy, clang/NEON and Rust. Long runs were launched with `nohup ... < /dev/null & disown` and logs in scratch; the persistent shell session kept detached children alive in the tool runner. The largest recorded Python experiment peak was {v['peak_rss_bytes']/1e6:.1f} MB. Final validation recorded {data['validation']['resources']['final_free_disk_bytes']/2**30:.1f} GiB free, exceeding the required 12 GiB floor. The live snapshot must first be copied without opening its SQLite connection, and only the copy opened/recovered. Experiments refuse paths outside the designated scratch directory and require at least 13 GiB free before creating/opening each database, leaving room for the largest experiment while maintaining the 12 GiB floor.

```sh
python3 research/index-design/study.py --phase storage
python3 research/index-design/study.py --phase extra
python3 research/index-design/column_bytes.py
python3 research/index-design/vectors.py
python3 research/index-design/references.py
python3 research/index-design/binary.py
python3 research/index-design/parity.py
python3 research/index-design/verify_rust.py
python3 research/index-design/loader.py
python3 research/index-design/profile.py
python3 research/index-design/updates.py
python3 research/index-design/retired.py
python3 research/index-design/wal.py
python3 research/index-design/validate.py
python3 -m unittest discover -s research/index-design -p test_study.py
```

The `backend-compacted.sqlite` copy must be prepared before parity/profile/update/validation scripts. Build/test output and temporary files can also be redirected to scratch:

```sh
export CARGO_TARGET_DIR="$HOME/.swiftlight-research/index-design/target"
export TMPDIR="$HOME/.swiftlight-research/index-design/tests/"
cargo test --manifest-path backend/Cargo.toml
# Only an explicit scratch copy was used for this task:
cargo run --manifest-path backend/Cargo.toml --bin compact-index -- \
  "$HOME/.swiftlight-research/index-design/backend-compacted.sqlite"
python3 research/index-design/report.py
```

Backend tests: 54 passed, comprising 50 launcher/backend tests and 4 compaction tests. Python codec tests: 5 passed. The committed compactor is a maintenance migration, not an automatic runtime change. No push was performed.

Primary sources: current [Rust search/scoring](../../backend/src/semantic.rs), [DigUp schema and compaction](../../vendor/DigUp/Sources/DigUpKit/IndexStore.swift), [source invalidation hook](../../vendor/DigUp/Sources/DigUpKit/Database.swift), [exact prompt retention](../../vendor/DigUp/Sources/DigUpKit/ShadowInputs.swift), [revision/FK contract](../../vendor/DigUp/Sources/DigUpKit/ShadowStore.swift). SQLite documents [FTS content/detail/token counts and tokenizer behavior](https://www.sqlite.org/fts5.html), [page size, auto-vacuum and journal limits](https://www.sqlite.org/pragma.html), [WAL readers and checkpoints](https://www.sqlite.org/wal.html), and [physical b-tree accounting](https://www.sqlite.org/dbstat.html). Reported sizes, latency, mismatches and recommendations come from the local experiments rather than SQLite's illustrative datasets.
'''
    (ROOT/'INDEX-DESIGN.md').write_text(text)
    bars=''.join(f'<div class="row"><span>{label}</span><div class="track"><div class="bar" style="width:{100*n/baseline:.2f}%;background:var(--chart-{i})"></div></div><strong>{mb(n)} MB</strong></div>' for i,(label,n) in enumerate((('Current',baseline),('Compatible compaction',compact),('Lossless text prototype',target)),1))
    html=f'''<!doctype html><html><head><meta charset="utf-8"><style>
    :root{{color-scheme:light dark}}body{{font-family:var(--font-sans);color:var(--foreground);margin:0}}.row{{display:grid;grid-template-columns:180px 1fr 105px;gap:12px;align-items:center;margin:18px 0;font-size:13px}}.track{{height:20px;background:var(--secondary);border-radius:4px;overflow:hidden}}.bar{{height:20px;border-radius:4px}}strong{{text-align:right;font-variant-numeric:tabular-nums}}p{{font-size:12px;color:var(--muted-foreground);line-height:1.5}}@media(max-width:500px){{.row{{grid-template-columns:110px 1fr 85px;gap:8px;font-size:11px}}}}
    </style></head><body>{bars}<p>Database bytes only; WAL and logs excluded. The 148.28 MB format is a validated research prototype. Compatible compaction and the faster vector loader are implemented in the backend.</p></body></html>'''
    (ROOT/'comparison.html').write_text(html)


if __name__=='__main__':main()
