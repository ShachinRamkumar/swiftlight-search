# Swiftlight index design

Measured locally on the 8 GB M1, 2026-11-03. MB means decimal megabytes; MiB means 1,048,576 bytes. Source code and aggregate measurements are committed. All databases, text, query strings, vector files, logs, generated Rust, and build output remain in `~/.swiftlight-research/index-design/`.

## Recommendation and implementation status

Keep SQLite, 16 KiB pages, full-detail Porter/unicode61 FTS, its token-count table, and the existing SIMD scorer. Store canonical text once when an exact byte reference is possible; otherwise retain it through a tagged lossless codec. Keep vectors in SQLite as fp16. The measured format is **148,275,200 bytes, 148.28 MB**, 47.5% below the current database. It retains both model generations, every prompt byte, original text, all excerpts, catalog rows, and both image-selection policies.

The new text format is a **working research prototype, not a production schema migration**. It needs coordinated Swift and Rust storage adapters. Python views/functions prove the format and search parity, but the shipped Swift writer cannot use these views unchanged. The source-change invalidation hook currently watches `fts_content`, which external-content FTS removes. Publishing this schema without replacing that hook would break writes and stale-vector invalidation. The backend-only improvements below are implemented and tested; the text-format integration remains future work.

Implemented now:

- [Backend compaction command](../../backend/src/bin/compact-index.rs). Explicit path only; no app startup hook or implicit live-index path. Its versioned `storage_compaction_v1` marker commits with FTS optimization, resumes at vacuum after interruption, and makes subsequent runs no-ops. Same schema, page size, model identity and search values. The command produced **223,854,592 bytes, 223.85 MB** on a separate copy, saving 58.72 MB.
- [Vector loader](../../backend/src/semantic.rs). Removes the forced materialization of model vectors while preserving explicit segment ordering, all fields, model/modality selection and incremental file filters. The full SQL scan dropped from 212.3 to 49.7 ms for the all-Core-AI policy, and 262.7 to 63.4 ms for the mixed policy. Whole-row equality passed on both original and prototype databases. This reads stored vectors only and does not initialize a model.

The compaction command is deliberately explicit. It does not install or automatically run a maintenance job. It may briefly block writers during `VACUUM`; run it during an indexing pause. WAL readers can continue, but long readers can retain old WAL frames. Its final passive checkpoint reports this rather than forcing readers to finish.

## Snapshot and current storage

Files were copied through ordinary file reads before any SQLite connection was opened. The copied database/WAL passed full `integrity_check`, then SQLite backup made the baseline. No live SQLite connection, live write, app launch/termination, Core AI call, model embedding, Neural Engine job, or Core AI cache access was used. File copying a changing WAL is not an atomic live backup guarantee; integrity, foreign-key, and FTS checks validate the captured copy, rather than claiming a globally instantaneous source snapshot.

The copy contains 4,209 files, 36,713 segments, 26,599 active vectors and 21,874 legacy vectors. Counts grew since the task's initial inventory. Segment kind counts include both vector-bearing and keyword-only rows; actual per-kind/per-modality counts are in `measurements.json`.

| Component | Bytes | MB |
|---|---:|---:|
| Database | 282,574,848 | 282.57 |
| Captured WAL | 14,619,560 | 14.62 |
| Shared-memory file | 32,768 | 0.03 |
| Logs and cost metadata | 16,850,845 | 16.85 |
| Entire captured directory | 314,078,021 | 314.08 |

The WAL holds 891 16-KiB frames plus headers. It contains page versions, not additional unique vector payload. The main file has 17,247 pages, including 1,320 free pages, **21,626,880 bytes**. `dbstat` accounts for 260,849,664 bytes of b-trees; another 98,304 bytes are incremental-auto-vacuum pointer-map pages. These three figures reconcile to the database byte count exactly. `auto_vacuum=INCREMENTAL` is already enabled. The captured log sizes grow with activity, independently of the number of currently indexed files.

| Object | Allocated bytes | Record payload bytes | Unused bytes inside pages | Overflow pages |
|---|---:|---:|---:|---:|
| fts_data | 61,145,088 | 60,264,163 | 653,069 | 0 |
| fts_content | 59,965,440 | 55,724,838 | 3,948,653 | 30 |
| embedding_inputs | 46,661,632 | 42,807,992 | 3,623,899 | 0 |
| vectors | 44,974,080 | 42,103,827 | 2,730,921 | 0 |
| segments | 43,253,760 | 41,773,159 | 1,192,747 | 0 |
| sqlite_autoindex_embedding_inputs_1 | 1,261,568 | 1,107,482 | 73,369 | 0 |
| files | 901,120 | 808,769 | 65,139 | 0 |
| sqlite_autoindex_files_1 | 655,360 | 507,907 | 132,809 | 0 |
| fts_idx | 475,136 | 299,850 | 118,083 | 0 |
| fts_docsize | 475,136 | 233,366 | 41,331 | 0 |
| segments_file | 458,752 | 295,404 | 52,877 | 0 |
| vectors_segment | 294,912 | 181,355 | 33,548 | 0 |
| files_state | 98,304 | 60,009 | 25,600 | 0 |
| files_inode | 98,304 | 60,086 | 25,523 | 0 |
| sqlite_schema | 16,384 | 8,875 | 7,205 | 0 |
| sqlite_autoindex_meta_1 | 16,384 | 182 | 16,167 | 0 |
| sqlite_autoindex_embedding_models_1 | 16,384 | 34 | 16,336 | 0 |
| meta | 16,384 | 400 | 15,939 | 0 |
| fts_config | 16,384 | 11 | 16,362 | 0 |
| embedding_models | 16,384 | 571 | 15,795 | 0 |
| embedding_modality_identities | 16,384 | 150 | 16,220 | 0 |
| embedding_failures | 16,384 | 0 | 16,376 | 0 |

FTS has 18 posting segments. `optimize` and compaction reduce `fts_data` from 61,145,088 to 27,557,888 bytes. This is the largest immediate saving. `fts_content` holds 55,515,423 bytes of text plus record headers; FTS posting data and content are different things. Full-detail postings are needed to retain current scoring. There are currently no optional prefix indexes to remove.

Active fp16 payload is 40,856,064 bytes. Legacy fp16 payload adds 33,598,464 bytes. None of the 21,874 paired legacy vectors equals its active counterpart. Retired-model status does not make these bytes removable: `image_vectors` and `audio_vectors` default to legacy in the backend. The prototype preserves the fallback/rollback data. The one 16-bit `EmbeddingGemma2.aimodel` change does not justify changing `coreai-eg2-v1`, rewriting document vectors, or changing calibration.

A separately measured retirement variant removes only the legacy **text** vectors, while retaining legacy image vectors. It is 116,539,392 bytes, 116.54 MB. Selected vector rows and every selected field remain identical under both Core AI image policies because Core AI always selects its text from `vectors`. This variant deliberately gives up legacy-text rollback and non-Core-AI text search, so it is conditional on that product decision. It is not the conservative recommendation and is not implemented as a backend migration. Ordinary `UPDATE segments SET vec=NULL` would fire invalidation triggers and delete active vectors; even this physical retirement needs a coordinated schema migration. The experiment suspended/restored those triggers only on an expendable copy.

Paths use 481,659 value bytes in `files`, with another path-bearing unique b-tree occupying 655,360 bytes. This duplication is small and supports lookups, scope ranges and uniqueness. Keep it. Keep the revision hashes and their foreign-key index; they prevent stale vector publication. `fts.original` is non-NULL for 3,398 rows. Canonical Unicode equivalence is insufficient to recover exact prompt bytes, so never discard originals or reconstruct titles from today's filenames without a byte equality check.

Growth follows segments and token counts more closely than file count. The current physical `files` table averages 214 bytes/file, its path index 156 bytes/file, and the inode/state indexes together about 47 bytes/file. Each file also creates a name segment and FTS row. Content averages 8.72 segments and 6.32 active vectors per file on this snapshot, with large variation by document length. Each additional active segment adds 1,536 raw vector bytes, revision metadata, text/prompt storage and FTS postings proportional to its tokens; a retained legacy vector adds another 1,536 bytes. Free pages, merge debt and WAL are workload-dependent overhead. Logs grow with operations, and retained model generations grow with model coverage, rather than with names alone.

### Exact per-column values

[column_bytes.py](column_bytes.py) reads SQLite record headers and serial types, including records promoted into WITHOUT ROWID interior pages. It reconciles serialized value bytes and header bytes against `dbstat.payload` for all 22 objects. This avoids the incorrect practice of counting an integer's decimal string as its disk representation. Rowid-alias primary keys consume zero value bytes in the record; b-tree rowid varints remain structural overhead. Page allocation cannot be uniquely assigned to individual columns, so the following separates serialized column bytes from physical object allocation above. The JSON also includes exact secondary-index and FTS-internal column accounting.

| Column | Serialized value bytes | Serial-type header bytes |
|---|---:|---:|
| files.id | 0 | 4,209 |
| files.path | 481,659 | 8,252 |
| files.kind | 15,727 | 4,209 |
| files.size | 10,095 | 4,209 |
| files.mtime | 33,136 | 4,209 |
| files.inode | 16,836 | 4,209 |
| files.device | 16,836 | 4,209 |
| files.state | 17,868 | 4,209 |
| files.detail | 5,966 | 4,209 |
| files.info | 122,332 | 4,300 |
| files.indexed_at | 33,672 | 4,209 |
| segments.id | 0 | 36,713 |
| segments.file | 83,822 | 36,713 |
| segments.kind | 177,711 | 36,713 |
| segments.modality | 149,300 | 36,713 |
| segments.loc | 33,235 | 36,713 |
| segments.loc_end | 0 | 36,713 |
| segments.excerpt | 7,348,099 | 66,950 |
| segments.vec | 33,598,464 | 58,587 |
| embedding_inputs.segment | 0 | 26,599 |
| embedding_inputs.input | 41,823,844 | 53,183 |
| embedding_inputs.content_rev | 851,168 | 26,599 |
| vectors.model | 26,599 | 26,599 |
| vectors.segment | 74,959 | 26,599 |
| vectors.content_rev | 851,168 | 26,599 |
| vectors.modality | 108,844 | 26,599 |
| vectors.vec | 40,856,064 | 53,198 |
| fts_content.id | 0 | 34,687 |
| fts_content.c0 | 111,320 | 34,967 |
| fts_content.c1 | 49,747,119 | 66,975 |
| fts_content.c2 | 5,656,984 | 38,099 |

## Storage alternatives

All FTS variants use the same retained input bytes, weights `bm25(fts,4.0,1.0)`, production AND/OR branching, limits 64/400, and coverage-count subqueries. Queries comprise 800 sampled text fragments, 200 names, and 29 held-out local evaluation queries. No query text is persisted in the report. Times below are warm filesystem measurements, median / p95 in milliseconds, on a swapping, shared machine. Small differences between runs are not controlled performance claims.

| FTS/database variant | Total MB | Keyword median / p95 ms | Different queries / tested |
|---|---:|---:|---:|
| Current database | 282.57 | 7.12 / 27.05 | 0 / 1029 |
| rebuilt-full | 223.85 | 6.41 / 25.03 | 0 / 1029 |
| column | 210.29 | 83.72 / 344.20 | 868 / 1029 |
| none | 202.75 | 31.36 / 327.41 | 50 / 64 |
| prefix3 | 241.32 | 5.85 / 21.86 | 0 / 1029 |
| prefix34 | 256.93 | 5.90 / 26.15 | 0 / 1029 |
| columnsize0 | 223.40 | 31.81 / 279.17 | 0 / 64 |
| contentless | 164.51 | 6.41 / 26.49 | 0 / 1029 |
| compressed-external | 168.87 | 5.90 / 22.57 | 0 / 1029 |
| External content, uncompressed | 223.85 | 6.03 / 24.91 | 0 / 1029 |
| Remove Porter stemming | 224.97 | 4.95 / 21.15 | 695 / 1029 |
| External content + exact references + codec fallback | 148.28 | 5.60 / 23.07 | 0 / 1029 |

`detail=column` and `detail=none` changed ordered BM25 results and were much slower. Reject them. `columnsize=0` saved only 458,752 bytes and forced expensive token counting. Keep `fts_docsize`. Prefix 3 is lossless on the sample but adds 17.5 MB for a modest latency gain; prefix 3+4 adds another 15.6 MB. Keep no prefix index under the disk/memory objective. Changing tokenizer/stemming changes retrieval and is rejected.

Contentless-delete is 164.5 MB and keeps these MATCH/BM25 results, but removes all stored FTS text. That text is read for input reconstruction, original display, and source identity snapshots. Its smaller number is not a valid quality-preserving design. Plain external content just moves the same bytes and does not save space.

The lossless external-content prototype stores each name/body/original value with raw or Zstandard-level-3 encoding, whichever is smaller. Embedding inputs and excerpts use the same codec. Exact-reference encoding then eliminates duplicate text in 23,916 embedding inputs. Each stores the original prompt prefix and byte offset/length into retained keyword text. Exact source slices serve 110 excerpts; another 3,593 retain their literal ellipsis suffix separately. Every other value has a complete raw/compressed fallback. No Unicode normalization, prompt generation, extraction, model call or source-file access is needed to decode it. Logical hashes include FTS rowids.

The prototype's `packed_embedding_inputs` falls from 46.7 MB to 3.1 MB. `keyword_payload` is 28.3 MB, FTS postings 27.6 MB, packed segments about 41.4 MB including legacy vectors, active vector table 43.6 MB, and the rest is indexes/metadata. Reference decoding occurs when text is requested; the full-detail keyword path and vector path do not need to decode corpus text. Byte-exact dictionary deduplication could remove at most another 5.3 MB of uncompressed body duplication before accounting for dictionary indexes, references and existing compression. It was counted, not implemented or claimed as a measured net saving.

### Page layout and maintenance

Each page-size candidate uses FTS optimization and vacuum first. Vector-read times here are raw SQLite BLOB scans, not model inference or similarity scoring. The rename workload makes 50 committed name updates and 50 restoring updates with automatic checkpoint disabled, then truncates WAL.

| Page bytes | Total MB | Vector read median / p95 ms | Keyword median / p95 ms | Rename WAL MB |
|---|---:|---:|---:|---:|
| 4096 | 321.35 | 31.00 / 31.40 | 5.94 / 24.54 | 2.32 |
| 8192 | 235.81 | 20.36 / 76.60 | 6.44 / 26.03 | 3.63 |
| 16384 | 223.85 | 24.40 / 110.45 | 6.43 / 27.00 | 6.96 |
| 32768 | 220.69 | 17.42 / 18.58 | 6.55 / 24.66 | 13.61 |

Keep 16 KiB. 4 KiB pages cause overflow for the WITHOUT ROWID vector records and increase total size above today's database. 32 KiB saves only 3.2 MB over 16 KiB and roughly doubles rename WAL traffic. On the current auto-vacuum layout, FTS optimization plus fully draining `incremental_vacuum` gives 226,983,936 bytes in 750 ms. Full vacuum gives 223,854,592 bytes in about 1.65 seconds on the layout experiment. The shipped helper's existing `compactIfSparse` requires 25% free and at least 32 MB; this snapshot's 7.65% / 21.6 MB does not trigger it, and much FTS waste is still inside live posting trees.

For ongoing maintenance, keep file-level transactions, incremental auto-vacuum and bounded FTS merges while idle. Return a bounded page budget between indexing batches, rather than vacuuming on every update. A separate sweep makes 200 committed name updates per policy on fresh compacted copies, with `synchronous=NORMAL` and an 8 MiB journal reset limit:

| Auto-checkpoint pages and reader state | Update median / p95 ms | Peak WAL MB | Frames checkpointed / present before reader release |
|---|---:|---:|---:|
| 64-short-readers | 0.05 / 0.46 | 1.10 | 44 / 44 |
| 64-pinned | 0.07 / 0.25 | 13.37 | 0 / 815 |
| 256-short-readers | 0.05 / 0.09 | 4.25 | 44 / 44 |
| 256-pinned | 0.07 / 0.19 | 13.37 | 0 / 815 |
| 1000-short-readers | 0.06 / 0.26 | 13.37 | 815 / 815 |
| 1000-pinned | 0.06 / 0.17 | 13.37 | 0 / 815 |

The 256-page threshold held short-reader WAL near 4.25 MB in this workload. With a pinned reader, every threshold reached 13.37 MB and checkpointed zero frames until that reader released its snapshot. This directly demonstrates why `journal_size_limit=8388608` is not a hard WAL cap. Start with `wal_autocheckpoint=256` at 16 KiB, and measure sustained fsync/battery behavior before making it the default. Use passive checkpoints during work; reserve truncate for idle periods without pinned readers. Rotate debug/indexing logs with a separate budget, since they can outgrow reclaimed database pages.

These WAL budgets and periodic maintenance settings are recommendations backed by the limited sweep, not deployed configuration changes or sustained-indexing/battery measurements. Only the explicit compaction migration and loader change ship in backend code here.

## Vector layout, scoring and exactness

| Selected vectors | Rows | Existing int8 SIMD median / p95 ms | fp16 to fp32 SIMD median / p95 ms | fp16 with f64 accumulation median / p95 ms |
|---|---:|---:|---:|---:|
| coreai-all | 26,599 | 0.42 / 0.79 | 2.00 / 2.27 | 4.53 / 4.88 |
| coreai-text-legacy-image | 26,409 | 0.46 / 0.89 | 2.00 / 2.37 | 4.53 / 5.29 |

The fp16 reference decodes the stored half values and accumulates products in f64, then rounds each cosine once to f32. It does not renormalize or replace stored vectors. It is a numerical reference, not today's backend scoring algorithm. The fp32 SIMD version changes accumulation order; even that small numerical change changed a top-20 ordering in one all-Core-AI query and a confirmed-gate decision in one mixed-policy query. Do not introduce it under a bit-identical quality contract.

The active vector table is 44,974,080 allocated bytes before compaction. A raw packed file is 40,856,064 bytes, but with a 64-byte identity/revision/offset manifest per row it is 42,558,400 bytes. The compacted SQLite vector table is 43,614,208 bytes. The roughly 1.1 MB saving against compacted SQLite does not justify a second transactional store, crash recovery, tombstones and an append-log compactor at this scale. Row compression saves little and complicates constraints/readers.

Measured lossless compression of 256-row vector blocks:

| Codec | Packed MB including offsets | Decode median / p95 ms |
|---|---:|---:|
| Raw fp16 | 40.86 | no decoding |
| zlib 6 | 36.29 | 93.96 / 120.53 |
| Zstandard 3 | 35.28 | 39.42 / 45.67 |
| Byte shuffle + Zstandard 3 | 33.72 | 81.19 / 117.77 |

All block decoders reproduced every byte. zlib per-row uses 39,690,861 bytes; Zstandard per-row uses 39,404,974 bytes versus 40,856,064 raw, before row framing. Block shuffling saves more but costs startup work and turns one-row changes into block rewrites. Keep raw fp16 in SQLite for the recommended balance. The 1.6 ms packed mmap page-touch measurement is only a page touch, not a dot-product scan; it must not be compared to a full SQLite scan as if the work were equal.

The current backend already quantizes both documents and queries to signed int8 and directly uses those scores. On 512 stored-vector queries per image policy, current int8 versus the fp16 reference changed 416 / 420 file top-20 lists. Gate flips at 4.5, 2.5, 3.0 were [754,4732,2650] / [810,4564,2332]. Maximum z error was about 0.128 / 0.129. This is evidence against treating quantization as exact, not evidence of worse user relevance. True text-query embeddings and judged relevance were deliberately not evaluated.

Selecting 20 int8 candidates missed exact top-20 membership for 146 / 155 queries. Selecting 64 or 256 missed none in this sample, which is not a universal guarantee. Binary sign codes use 2,553,504 bytes and scan in 0.085 ms, but missed exact top-20 membership in 38/128 queries at 64 candidates, 4/128 at 256 and 1/128 even at 1024. Reject fixed-count binary or int8 prefilters as quality-preserving replacements.

An admissible quantized bound can use residual norms: with restored approximations v̂ and q̂, the dot error is at most ||q||₂||v−v̂||₂ + ||v̂||₂||q−q̂||₂, plus floating-point evaluation bounds. A safe algorithm must refine until every rejected upper bound falls below the selected kth lower bound, allowing for different group means. This still does not produce identical reported z-scores: the group means and global standard deviation depend on every calibration row, including rows outside the candidate set. Analytic first/second moments reproduce real-arithmetic statistics, not the existing per-row f32 rounding followed by ordered f64 reductions. Exact top-k rescore alone is insufficient. Returning identical z-scores requires the full scoring population, or an independently proven exact aggregate algorithm with conservative fallback. The existing 0.4–0.5 ms full int8 scan is already cheap. Keep it.

## Memory, startup and updates

The scoring arrays contain 20,534,428 bytes of int8 codes plus scales for 26,599 rows. An fp16 mmap scan needs 40,856,064 mapped bytes once all pages are touched. Building int8 codes from the mmap touches both matrices, about 61.4 MB. A packed file is not free memory. A persisted mmap of int8 codes could reduce reload cost, but adds approximately 20.5 MB of redundant disk cache plus generation/crash invalidation machinery; it was not implemented.

Fresh-process profiles use five processes per option, a 4 MiB SQLite cache, file-backed temp storage, and the same C quantizer/scorer. They include Python/NumPy overhead and are not whole-app RSS. The interpreter/import peak is about 34 MiB, so the increase is more useful than the total. Startup includes row fetch, half decoding and int8 conversion; it excludes model loading, walking files, frontend launch, and cold-boot disk-cache behavior. No system caches were purged during measurement. `*-direct` uses the implemented direct loader branch; the old modes force materialization. The full UNION/metadata SQL timing and row parity are separately captured in `loader.json` within the measurements bundle.

| Mode | Startup ms | RSS increase MiB | Total peak RSS MiB |
|---|---:|---:|---:|
| sqlite | 345.2 | 35.0 | 68.8 |
| compact | 271.2 | 34.9 | 68.8 |
| compressed | 301.8 | 35.1 | 68.9 |
| reference | 301.8 | 35.0 | 68.8 |
| sqlite-direct | 138.1 | 25.2 | 59.0 |
| compact-direct | 144.4 | 25.2 | 59.1 |
| reference-direct | 159.5 | 25.2 | 59.1 |
| mmap-int8 | 25.0 | 58.1 | 92.0 |
| mmap-fp16 | 5.2 | 38.6 | 72.5 |

The recommended scorer's resident matrix stays the same 20.5 MB. Text compression does not add a decompressed corpus cache. Startup favors removing materialization over creating a vector sidecar. The Python import baseline is not part of the shipping Rust app, and these measurements do not establish any Core AI model-memory saving.

Each ingest/delete benchmark performs 50 committed cycles on a fresh disposable database. A cycle adds a synthetic file and one representative existing text segment, exact retained input, FTS data and fp16 vectors, then deletes the file through the appropriate adapter. It excludes extraction and model inference. New reference inputs/excerpts were decoded and compared after every insert. Both SQLite and FTS integrity checks and foreign-key checks passed after the cycles.

| Format | Ingest median / p95 ms | Delete median / p95 ms |
|---|---:|---:|
| baseline | 0.77 / 7.16 | 0.81 / 4.01 |
| compact | 0.65 / 3.28 | 0.66 / 1.01 |
| reference | 0.79 / 4.41 | 0.81 / 4.48 |

These are representative single-segment transactions, not sustained indexing throughput or concurrent multi-writer stress tests. Reference format committed renames measured 0.07 / 0.16 ms. Deleting a real multi-segment file, verifying cascaded vector removal, and replacing source text with atomic vector invalidation were also exercised and rolled back. Crash/retry and compaction-marker behavior have four backend unit tests. New codec tests cover raw/compressed values, NULL/empty strings, embedded NULs, Unicode normalization differences, byte offsets, original titles, ellipsis suffixes and 1,500 generated Unicode references.

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
5. Build a candidate database beside the old database with a 4 MiB cache and file-backed temporary storage, using one consistent read snapshot or a captured change log. Stream rows. The prototype rewrite took 5.65 seconds. Verify all decoded fields, revision hashes, FTS postings and ordered query outputs before cutover. Recheck source generation under the writer lock so a migration cannot lose intervening updates.
6. Pause writers for atomic same-volume cutover. Close old SQLite connections before handling the database/WAL pair; never rename only a live main database while its WAL is active. Keep a rollback copy until new readers and writers validate, then remove it. At this snapshot scale, budget around 1 GB of temporary headroom plus the user's required 12 GiB free floor. Do not keep both formats permanently.
7. Apply bounded idle merges, incremental page return, and measured checkpoint/log rotation policy. Updates stay per-file transactional; no whole-index rebuild, ANN graph, model migration or lossy canonical storage is needed.

## Reproduction and sources

The scripts require Python 3.14 with `compression.zstd`, NumPy, clang/NEON and Rust. Long runs were launched with `nohup ... < /dev/null & disown` and logs in scratch; the persistent shell session kept detached children alive in the tool runner. The largest recorded Python experiment peak was 364.7 MB. Final validation recorded 21.4 GiB free, exceeding the required 12 GiB floor. The live snapshot must first be copied without opening its SQLite connection, and only the copy opened/recovered. Experiments refuse paths outside the designated scratch directory and require at least 13 GiB free before creating/opening each database, leaving room for the largest experiment while maintaining the 12 GiB floor.

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
cargo run --manifest-path backend/Cargo.toml --bin compact-index --   "$HOME/.swiftlight-research/index-design/backend-compacted.sqlite"
python3 research/index-design/report.py
```

Backend tests: 54 passed, comprising 50 launcher/backend tests and 4 compaction tests. Python codec tests: 5 passed. The committed compactor is a maintenance migration, not an automatic runtime change. No push was performed.

Primary sources: current [Rust search/scoring](../../backend/src/semantic.rs), [DigUp schema and compaction](../../vendor/DigUp/Sources/DigUpKit/IndexStore.swift), [source invalidation hook](../../vendor/DigUp/Sources/DigUpKit/Database.swift), [exact prompt retention](../../vendor/DigUp/Sources/DigUpKit/ShadowInputs.swift), [revision/FK contract](../../vendor/DigUp/Sources/DigUpKit/ShadowStore.swift). SQLite documents [FTS content/detail/token counts and tokenizer behavior](https://www.sqlite.org/fts5.html), [page size, auto-vacuum and journal limits](https://www.sqlite.org/pragma.html), [WAL readers and checkpoints](https://www.sqlite.org/wal.html), and [physical b-tree accounting](https://www.sqlite.org/dbstat.html). Reported sizes, latency, mismatches and recommendations come from the local experiments rather than SQLite's illustrative datasets.
