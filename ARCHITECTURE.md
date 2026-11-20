# Architecture

Swiftlight pairs a native macOS AppKit launcher with a long-lived Rust search coordinator and an isolated native Swift Core AI indexing helper.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  AppKit / SwiftUI Frontend (frontend/)                                  │
│  - Floating search pill + results surface (100% public AppKit/SwiftUI)  │
│  - Carbon Command-Space hotkey + CGEvent opening keystroke buffer       │
│  - Inline completion overlay, Quick Look preview, LaunchServices open   │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ newline-delimited JSON over stdin/stdout
┌───────────────────────────────▼─────────────────────────────────────────┐
│  Rust Hybrid Search Coordinator (backend/)                              │
│  - Latest-query mailboxes & stale-generation cancellation               │
│  - Fast path: FSearch Unix-socket filename client                       │
│  - Keyword path: SQLite FTS5 + abort-on-keystroke progress hook         │
│  - Semantic path: In-memory int8 vector cache + ARM64 NEON sdot         │
│  - Modality Z-score gating, word/tag confirmation, deduplication        │
│  - FSEvents watcher + indexing supervisor + thermal/memory pressure     │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ JSON-lines RPC + shared SQLite WAL
┌───────────────────────────────▼─────────────────────────────────────────┐
│  Isolated Native Helper (vendor/DigUp/, MIT base + Core AI extensions)  │
│  - Apple Core AI / Neural Engine runtime for EmbeddingGemma 2           │
│  - Document, PDFKit, Vision OCR, and libjpeg-turbo readers              │
│  - Incremental SQLite writer + lossless Zstd/BF16 host-table codec      │
└─────────────────────────────────────────────────────────────────────────┘
```

## Process Boundaries and Protocol

The AppKit search field sends `{op:"query", generation:1, text:"..."}` over stdin to the long-lived Rust coordinator (`Swiftlight Search`). Rust publishes a `results` event as each of its three search workers finishes (`phase`: `fast` for names, `keyword` for indexed words, `semantic` for meaning, in whichever order completes first), containing the merged ranked list so far; `complete` becomes `true` once all three phases answer.

Arrow keys highlight rows in the results surface and send `select` with the highlighted path (or `select` with `null` when pressing Up from the first row to return focus to the field). Pressing Return or clicking a row opens the displayed selection immediately via LaunchServices without waiting on a backend round-trip, then sends `opened` so Rust revalidates scope and records the open for ranking. Return pressed before a query's first results arrives is held briefly by `PendingOpen` until that generation's results land.

## Rust Coordinator Ownership (`backend/`)

Rust owns:
- Latest-query mailboxes and stale-generation cancellation (`main.rs`)
- FSearch Unix-socket client and filename ranking (`fast.rs`)
- SQLite FTS5 keyword retrieval, vector cache management, 8-bit NEON dot-product scoring, modality Z-score calibration, and hybrid ranking (`semantic.rs`)
- Path scope validation, hidden/credential/foreign-repo exclusion rules (`scope.rs`)
- Native macOS `FSEvents` home-directory watching (`watch.rs`)
- Indexing helper supervision, pause/resume signaling, and system load/thermal/memory-pressure gating (`indexing.rs`, `load.rs`)
- Explicit resumable SQLite index compaction (`src/bin/compact-index.rs`)

The main coordinator thread is the sole writer of selection state and stdout. Each search worker owns its own connection and cache so semantic inference never blocks filename or keyword updates.

## Frontend Ownership (`frontend/`)

AppKit owns the borderless non-activating `NSPanel`, search field editor, inline completion overlay (`NativeUIAdapter.m`), vertically scrolling results list, folder-access onboarding card (`FolderAccessView.swift`), Quick Look preview integration, menu-bar status item, Carbon global hotkey, `CGEvent` opening keystroke buffer (`OpeningKeyBuffer.swift`), and instant LaunchServices file/app opening (`AppOpening.swift`).

Surface materials (`NativeMaterial.swift`) use public SwiftUI `.glassEffect(.regular, in: ...)` on macOS 26+ with a public `NSVisualEffectView` fallback on earlier macOS releases. Window transitions (`NativePresentation.m`, `Results.swift`) use public Core Animation springs and `NSAnimationContext` opacity curves, respecting `accessibilityDisplayShouldReduceMotion`.

## Native Indexing Helper (`vendor/DigUp/`)

The isolated native helper (`Swiftlight Indexer`) builds on DigUp's MIT-licensed file readers and incremental SQLite writer, extended with an Apple Core AI / Neural Engine runtime (`DigUpCoreAIRuntime`) for `EmbeddingGemma 2` and a lossless host-table codec (`HostTableCodec` + `CZstd`). Rust reads directly from the shared SQLite WAL database instead of calling a serialized search service, giving Rust full control over query cancellation, memory lifetime, and NEON SIMD scoring.

## Ranking and Hybrid Retrieval

1. **In-memory 8-bit vector cache:** Rust loads only vectors added or updated since the last query (tracked by `files.indexed_at` and path), quantizes each 768-dim embedding to signed `int8` with a per-row scale (4× smaller than FP32), and scores queries with ARM64 NEON `sdot` instructions.
2. **Modality-calibrated Z-score gating:** Semantic scores are normalized per modality (cosine minus modality mean, divided by the query's score standard deviation), gated at `4.5` standard deviations so queries with no genuine match return minimal noise. Small indexes (<500 vectors) fall back to a `0.72` cosine threshold.
3. **Word confirmation (SQLite FTS5):** FTS5 drops stop words, applies prefix matching for words of 3+ characters, and registers a SQLite progress hook that aborts in-flight queries as soon as a newer keystroke arrives. Words act as confirmation rather than overriding semantics: items matched by both meaning and words rank by meaning boosted by query-term coverage; pure word matches sit below strong meaning matches (except screenshots, where OCR text is primary evidence).
4. **Visual tag confirmation:** Indexed images store dominant color and Apple Vision classifier tags. An image scoring between `2.5` and `4.5` standard deviations is promoted when its tags match the descriptive terms of the query.
5. **Scope and deduplication:** Fast search covers system/user Applications plus `Documents`, `Desktop`, and `Downloads`. Semantic indexing covers visible documents, PDFs, screenshots, and images under the home directory while excluding hidden trees, `Library`, app/media bundles, credentials, dependency/build directories, symlink escapes, cloud placeholders, source code, structured data, audio/video, and third-party git clones. Extracted copies of a document fold into the original file.

## Hotkey & Zero-Drop Opening

The Carbon `Command-Space` handler toggles synchronously on the main thread. The non-activating panel is pre-created and laid out while hidden so opening makes it key and focuses the field editor before activating the app. When listen-event permission is already granted, `OpeningKeyBuffer` captures keystrokes fired during the millisecond window between `Command-Space` and field focus, replays them in order into the panel, and steps out of the way for normal AppKit typing.
