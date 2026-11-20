# Third-Party Components and Attribution

Swiftlight builds on several open-source projects and preserves their licenses in full.

## DigUp (MIT License)

- **Upstream repository:** https://github.com/ARahim3/DigUp
- **Pinned commit:** `f9b8106ffb8308b4f48b76149d270f7c2e6b4918`
- **License:** MIT, retained in [`vendor/DigUp/LICENSE`](vendor/DigUp/LICENSE) and bundled into `Swiftlight.app/Contents/Resources/DigUp-LICENSE.txt`.

Swiftlight reuses DigUp's MIT-licensed file readers, crawler primitives, and SQLite incremental indexer as an isolated native helper (`Swiftlight Indexer`). Sparkle, the DigUp macOS frontend, `LlamaRuntime`, `CLlama`, GGUF downloaders, and legacy search-service commands are excluded from the local package manifest.

Local extensions to the vendored helper include:
- Apple Core AI / Neural Engine runtime integration (`DigUpCoreAIRuntime`) and lossless BF16/Zstandard host-table codecs (`HostTableCodec`)
- Project-document eligibility with exclusions for build output, credentials, media-library interiors, foreign git checkouts, and non-prose chunks
- Background scheduling priorities (documents before PDFs/images, alternating batches of two per kind, 1,536 MB RSS watchdog, warning-level memory-pressure continuation, and Vision fast OCR for screenshots)
- On-demand image encoder loading and sparse-index compaction (`IndexStore.compactIfSparse`)

## Google EmbeddingGemma 2 (Apache 2.0)

- **Upstream model:** https://huggingface.co/google/embeddinggemma-2 (revision `914f7f89142e33e77833254d9c9b90c3cef7303b`)
- **License:** Apache 2.0, full text retained in [`models/CoreAI/LICENSE-Apache-2.0.txt`](models/CoreAI/LICENSE-Apache-2.0.txt) alongside the redistributed `models/CoreAI/tokenizer_config.json`.
- **Integrity manifest:** Pinned SHA-256 checksums for separately prepared Core AI assets and host tables live in [`models/CoreAI/manifest.json`](models/CoreAI/manifest.json) (vector identity `coreai-eg2-v1`). Binary weights are not committed to this repository.

## FSearch (MIT License)

- **Upstream repository:** https://github.com/noahdunnagan/fsearch
- Used as an external local filename-search daemon over its JSON-lines Unix socket; Swiftlight filters results in its Rust coordinator without modifying or bundling FSearch.

## Rust Crates

- **Backend coordinator:** Dependencies are pinned in [`backend/Cargo.lock`](backend/Cargo.lock), including `rusqlite` (bundled SQLite with FTS5 and progress hooks), `serde`, `serde_json`, `half`, `base64`, and `libc`, with all compiled crate license texts preserved in `backend/licenses/` and copied into `Swiftlight.app/Contents/Resources/backend-licenses/`.
- **Tokenizer bridge:** [`vendor/DigUp/Vendor/hf-tokenizer/`](vendor/DigUp/Vendor/hf-tokenizer/) pins Hugging Face `tokenizers` `0.23.2` (Apache 2.0, retained in `vendor/DigUp/Vendor/hf-tokenizer/LICENSE` and copied into `Swiftlight.app/Contents/Resources/hf-tokenizer-LICENSE.txt`) and its 77 locked transitive crates in `Cargo.lock` and `vendored-crates.json`, with all dependency license texts preserved in `vendor/DigUp/Vendor/hf-tokenizer/licenses/` and copied into `Swiftlight.app/Contents/Resources/hf-tokenizer-licenses/`.

## libjpeg-turbo 3.2.0

- **Location:** [`vendor/DigUp/Vendor/libjpeg-turbo/`](vendor/DigUp/Vendor/libjpeg-turbo/)
- Statically linked arm64 `libjpeg.a` with matching headers for Pillow-compatible JPEG decoding.
- **Licenses:** IJG, modified BSD, and zlib terms retained in `share/doc/libjpeg-turbo/LICENSE.md` and `README.ijg`, and copied into `Swiftlight.app/Contents/Resources/`.

## Zstandard 1.5.7

- **Upstream repository:** https://github.com/facebook/zstd (v1.5.7)
- **Location:** [`vendor/DigUp/Sources/CZstd/`](vendor/DigUp/Sources/CZstd/)
- Single-file C decompressor compiled as a SwiftPM target for lossless compressed host tables.
- **License:** BSD license retained in `vendor/DigUp/Sources/CZstd/LICENSE` and copied into `Swiftlight.app/Contents/Resources/zstd-LICENSE.txt`.

## Public Benchmark Datasets (Referenced Only, Not Redistributed)

The evaluation scripts in [`research/document-inputs-public/`](research/document-inputs-public/) reference public ViDoRe datasets hosted on Hugging Face (`vidore/syntheticDocQA_energy_test` and `vidore/biomedical_lectures_eng_v2`) to compute aggregate retrieval metrics. No third-party page images, PDFs, or dataset OCR texts are committed to this repository; only our evaluation code and aggregate numerical metrics are retained.
