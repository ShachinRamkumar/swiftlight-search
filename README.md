# Swiftlight

A fast, fully on-device hybrid semantic file search launcher for macOS (Apple Silicon) combining instant filename lookup, SQLite FTS5 keyword retrieval, and Apple Core AI / Neural Engine multimodal embeddings (`EmbeddingGemma 2`) inside a native AppKit interface.

---

## What I Built vs. Open-Source Foundations

Swiftlight clearly separates its open-source building blocks from original systems engineering:

### Original Engineering in Swiftlight
- **Rust Hybrid Search Coordinator (`backend/`):**
  - Multi-phase concurrent search architecture (`fast` names, `keyword` SQLite FTS5, `semantic` vector search) publishing progressively as each worker finishes, with latest-query mailboxes, adaptive semantic debounce (`25 ms` default, up to `32 ms` during fast typing, `0 ms` at whitespace boundaries), and generation-based stale-result cancellation.
  - **In-memory 8-bit NEON SIMD vector cache:** Quantizes 768-dim embeddings to signed `int8` with per-row scales (`20.5 MB` for `26,599` int8 scoring arrays — ~4× smaller than FP32) and scores queries using ARM64 NEON `vdotq_s32` in **0.42 ms median / 0.79 ms p95**.
  - **Abandon-on-keystroke SQLite FTS5 + hybrid ranking:** Custom SQLite progress hook aborts in-flight FTS queries on new keystrokes; combines modality-calibrated Z-score semantic gating, word-coverage confirmation, Apple Vision color/scene tag confirmation for images, and duplicate-document folding.
  - **Direct SQLite vector loader & resumable index compaction (`backend/src/bin/compact-index.rs`):** Eliminated forced SQLite materialization to drop full SQL vector scans from **212.3 ms → 49.7 ms** (all-Core-AI) and Python/NumPy loader harness startup from **345.2 ms → 138.1 ms**, plus explicit resumable FTS/VACUUM compaction (**282.57 MB → 223.85 MB**, **0 / 1,029** keyword query differences).
  - **Native macOS FSEvents supervisor & pressure gating (`watch.rs`, `indexing.rs`, `load.rs`):** Single low-overhead FSEvents stream with path-level exclusions, public GCD memory-pressure + thermal/load-average backpressure, and strict scope rules (excluding credentials, hidden trees, build outputs, and foreign git clones).
- **Apple Core AI / Neural Engine Runtime & Host-Table Codecs (`vendor/DigUp/Sources/DigUpCoreAIRuntime/`, `HostTableCodec/`):**
  - Native Swift Core AI integration for Google's Apache 2.0 `EmbeddingGemma 2` across text, vision, and audio buckets, completely decoupling the runtime from `llama.cpp` / GGUF.
  - **Lossless BF16 plane-split + Zstandard host-table compression:** Packs token embeddings, bounded vision position rows, and prefix-shared RoPE tables from **346.41 MB → 189.36 MB** (`scripts/host_tables.py`, `HostTableCodec`, verified lossless in Python and Swift codec tests).
  - **Panel-priority ANE scheduling & runtime integrity verification:** Coordinates active panel queries against background indexing (`InferencePriority`) and enforces SHA-256 manifest validation (`models/CoreAI/manifest.json`).
- **Native macOS AppKit / SwiftUI Launcher (`frontend/`):**
  - 100% documented public macOS AppKit, SwiftUI, Core Animation, Carbon, and Quick Look APIs (public SwiftUI `.glassEffect(.regular, ...)` on macOS 26+ with public `NSVisualEffectView` fallback).
  - Pre-laid-out non-activating `NSPanel`, `CGEvent` opening keystroke buffer (`OpeningKeyBuffer.swift`), inline completion overlay, Quick Look preview synchronization, and immediate LaunchServices result opening (`AppOpening.swift`).
- **Research & Benchmarks (`research/`):**
  - Public ViDoRe multimodal retrieval benchmark and PyTorch reference parity results (`research/document-inputs-public/`).
  - SQLite index storage, WAL checkpointing, and lossless external-content codec study (`research/index-design/`).
  - Core AI host-table compression and calculated Option A storage budget analysis (`research/combined-footprint/`).

### Upstream Open-Source Foundations
- **[DigUp](https://github.com/ARahim3/DigUp) (MIT License):** Swiftlight reuses DigUp's MIT-licensed document/PDF/image extraction readers and incremental SQLite index writer inside an isolated helper (`vendor/DigUp/`), omitting DigUp's UI, Sparkle updater, and `llama.cpp` targets.
- **[FSearch](https://github.com/noahdunnagan/fsearch) (MIT License):** External local filename daemon queried over its JSON-lines Unix socket without modifying its global index.
- **[EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) (Apache 2.0):** Google's multimodal embedding model, whose compiled Core AI assets are prepared separately and excluded from Git (Apache 2.0 license included in [`models/CoreAI/LICENSE-Apache-2.0.txt`](models/CoreAI/LICENSE-Apache-2.0.txt) for redistributed `tokenizer_config.json`).
- **Vendored C/Rust libraries:** `rusqlite` (bundled SQLite + FTS5), Hugging Face `tokenizers` (`0.23.2`, Apache 2.0), `libjpeg-turbo` (`3.2.0`), and `zstd` (`1.5.7` decompressor, BSD). See [`THIRD_PARTY.md`](THIRD_PARTY.md) for complete attribution and licenses.

---

## Verified Benchmark Results

Every figure below is backed by JSON artifacts committed in this repository (measured on Apple M1, 8 GB RAM):

### Index & Vector Scoring (`research/index-design/INDEX-DESIGN.md`, `measurements.json`)

| Benchmark | Measured Result | Artifact / Parity |
| --- | --- | --- |
| ARM64 NEON `int8` scan (`26,599` × 768-dim rows) | **0.42 ms median** / **0.79 ms p95** (`20.5 MB` scoring arrays) | vs. `2.00 ms` fp16→fp32 SIMD, `4.53 ms` fp16→f64 (`measurements.json`) |
| Direct SQLite vector loader (full SQL scan) | **212.3 ms → 49.7 ms** (all-Core-AI); **262.7 → 63.4 ms** (mixed) | Exact row equality (`measurements.json` `loader.*.all_selected_fields_and_order_equal`) |
| Direct SQLite vector loader (Python/NumPy harness startup) | **345.2 ms → 138.1 ms** | Fresh-process Python/NumPy harness (`INDEX-DESIGN.md`, `measurements.json`) |
| Explicit SQLite compaction (`compact-index`) | **282.57 MB → 223.85 MB** (−58.72 MB) | **0 / 1,029** keyword query diffs (`backend/src/bin/compact-index.rs`) |
| Lossless external-content prototype | **282.57 MB → 148.28 MB** (−47.5%) | **0 / 1,029** keyword query diffs (`INDEX-DESIGN.md`) |

### Host-Table Compression & Calculated Storage Budget (`research/combined-footprint/REPORT.md`, `budget.json`)

| Study Item | Baseline | Target / Compressed | Scope & Verification |
| --- | ---: | ---: | --- |
| Core AI host & support tables (`host_tables.py`) | 346.41 MB | **189.36 MB** | Lossless BF16 plane-split + Zstd-19 token table, bounded vision position rows, prefix-shared RoPE tables (`host-table-codecs.json`, `rope-regenerate.json`) |
| Option A steady-state model storage (**calculated budget**) | 4.46 GB | **792.32 MB** (`0.92×` Q8 GGUF) | Calculated from measured merged-text + vision compiled sizes & lossless host tables with audio downloaded on demand (`budget.json`; not an end-to-end deployed install) |

### Public Multimodal Benchmark (`research/document-inputs-public/`)

Evaluated on ViDoRe [`syntheticDocQA_energy_test`](https://huggingface.co/datasets/vidore/syntheticDocQA_energy_test) (500 pages, 49 queries, 5,000-rep clustered bootstrap; verified in CI via `verify.py --results-only` against [`results.json`](research/document-inputs-public/results.json), [`metrics-energy.json`](research/document-inputs-public/metrics-energy.json), and [`parity.json`](research/document-inputs-public/parity.json)):

| Variant | nDCG@5 | Recall@1 | Recall@5 | MRR@10 |
| --- | ---: | ---: | ---: | ---: |
| `P` (OCR text proxy, image fallback on 17/500 pages with <200 OCR chars) | 0.9098 | 0.8571 | 0.9592 | 0.8935 |
| `V1` (text + page-image multi-vector) | **0.9264** | **0.8776** | **0.9592** | **0.9179** |
| `V2` (joint multimodal) | 0.9148 | 0.8571 | 0.9592 | 0.9051 |

- **PyTorch Reference Parity (`parity.json`):** Across 11 checks (5 query, 3 document, 2 image, 1 mixed), manual PyTorch preprocessing/embedding assembly matched Hugging Face Transformers' native PyTorch forward pass with **cosine ≥ 0.99999994** (7 of 11 exact `1.0`). These checks validate PyTorch path parity only (not Core AI on-device execution).

---

## Repository Layout

- `backend/` — Rust hybrid search coordinator, NEON SIMD scorer, FSEvents watcher, and `compact-index` CLI
- `frontend/` — Native macOS AppKit / SwiftUI launcher (`100%` documented public macOS APIs)
- `vendor/DigUp/` — MIT-licensed DigUp indexer helper extended with `DigUpCoreAIRuntime` and `HostTableCodec`
- `models/CoreAI/` — Pinned SHA-256 runtime manifests (`manifest.json`, `option-a.json`, `tokenizer_config.json`, `LICENSE-Apache-2.0.txt`); no binary weights
- `research/` — Public multimodal benchmark (`document-inputs-public/`), SQLite index design (`index-design/`), and model storage budget (`combined-footprint/`)
- `scripts/` — Host-table codecs, runtime verification installers, evaluation scripts, and offline unit tests
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — Ownership, JSON protocol, ranking rules, and hotkey design
- [`FIRST-RUN.md`](FIRST-RUN.md) — First-run model preparation and readiness behavior
- [`THIRD_PARTY.md`](THIRD_PARTY.md) — Open-source licenses, dataset attributions, and upstream modifications

---

## Building & Testing

### Supported Toolchains & SDKs
- **Rust backend (`backend/`) & Public-API frontend (`frontend/`):** Apple Silicon macOS with Xcode Command Line Tools (`macOS 26+` SDK; tested on GitHub Actions `macos-latest` with macOS 26.5 SDK), Rust toolchain (`cargo`, `clippy`), and Python `3.14` (standard-library `compression.zstd` for codec tests).
- **Full app bundle including Core AI indexer (`bash build.sh`):** Requires Apple Silicon **macOS 27 SDK** (for `CoreAI.framework`) and network access on first build to fetch locked `hf-tokenizer` Cargo crates (or pre-vendored crates via `(cd vendor/DigUp/Vendor/hf-tokenizer && CARGO_NET_OFFLINE=false cargo vendor --locked crates)`).

### Run Automated Tests (No Model Weights Required)

```sh
# Rust hybrid backend unit tests & strict Clippy
cargo test --manifest-path backend/Cargo.toml --locked
cargo clippy --manifest-path backend/Cargo.toml --locked --all-targets -- -D warnings

# Compile-check the public-API macOS frontend
bash build.sh --frontend-only

# Standalone Swift frontend unit tests
swiftc -parse-as-library frontend/FolderAccess.swift scripts/test-access-flow.swift -o build.noindex/test-access-flow && ./build.noindex/test-access-flow
swiftc -parse-as-library frontend/PanelOpenPreparation.swift scripts/test-panel-open.swift -o build.noindex/test-panel-open && ./build.noindex/test-panel-open
swiftc -parse-as-library frontend/PendingOpen.swift scripts/test-pending-open.swift -o build.noindex/test-pending-open && ./build.noindex/test-pending-open

# Python host-table codec, storage layout, index-codec, and benchmark verification tests
python3 -m unittest discover -s scripts/tests -p "test_*.py" -v
python3 -m unittest discover -s research/index-design -p "test_study.py" -v
python3 research/document-inputs-public/verify.py --results-only
```

### Full Local App Build & Semantic Runtime Setup

Binary model weights (~3 GB) are excluded from Git. Filename search, searching existing SQLite FTS5 indexes, the Rust coordinator, the public-API frontend, and all CI tests work without model weights. Creating a fresh keyword+semantic index through `Swiftlight Indexer` requires the Core AI runtime assets.

To build and enable local Core AI indexing on Apple Silicon (macOS 27 SDK):

1. Build the complete `build.noindex/Swiftlight.app` bundle (uses ad-hoc signing by default; set `CODESIGN_IDENTITY` for a stable local certificate):
   ```sh
   bash build.sh
   ```
2. Place separately prepared Core AI `.aimodel` packages and host tables (exported from Apache 2.0 [`google/embeddinggemma-2`](https://huggingface.co/google/embeddinggemma-2) revision `914f7f89142e33e77833254d9c9b90c3cef7303b`) into `models/CoreAI/` matching the SHA-256 hashes in [`models/CoreAI/manifest.json`](models/CoreAI/manifest.json) (see [`models/CoreAI/README.md`](models/CoreAI/README.md)).
3. Verify checksums and install the runtime into `~/Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1/`:
   ```sh
   bash scripts/install-runtime.sh
   ```
4. Optionally install the built app bundle to `~/Applications/Swiftlight.app`:
   ```sh
   bash scripts/install.sh
   ```

---

## Usage

- Summon with **Command-Space** (disable macOS Spotlight's own Command-Space binding in *System Settings → Keyboard → Keyboard Shortcuts → Spotlight*) or click the menu-bar magnifying glass.
- Type normally: the top match completes inline and **Return** opens it immediately.
- Press **Down / Up** to browse the results list; press **Space** while browsing to toggle native **Quick Look**; press **Escape** to dismiss Quick Look first, then the launcher.
- When the Mac is under thermal pressure, critical memory pressure, or high CPU load, Swiftlight prevents cold-loading the embedding model (an already-loaded model continues serving) and answers from filenames and existing indexed FTS5 words while holding back new indexing passes (`SWIFTLIGHT_FORCE_BUSY=1` tests this mode).

---

## License

Original code in this repository is licensed under the [MIT License](LICENSE). Vendored components retain their respective licenses; see [`THIRD_PARTY.md`](THIRD_PARTY.md).
