# Core AI Model Assets (`EmbeddingGemma 2`)

Swiftlight's semantic indexing runtime uses [Google EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) (Apache 2.0, revision `914f7f89142e33e77833254d9c9b90c3cef7303b`, checkpoint SHA-256 `197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79`) compiled into Apple Core AI `.aimodel` packages for Apple Silicon.

Binary model weights (~3 GB total across text, vision, and audio `.aimodel` packages and BF16 host tables) are **not** stored in this Git repository.

## Files committed here

- [`manifest.json`](manifest.json) — Pinned SHA-256 integrity manifest for the Core AI runtime (`coreai-eg2-v1`), checkpoint revision, tokenizer checksum, and per-modality asset identities.
- [`option-a.json`](option-a.json) — Pin manifest for the deduplicated text + vision layout (`swiftlight-option-a-1`). Optional audio download URLs remain configuration placeholders (`PLACEHOLDER_AUDIO_DOWNLOAD_URL`).
- [`tokenizer_config.json`](tokenizer_config.json) — Tokenizer configuration and special-token definitions from `google/embeddinggemma-2` (Apache 2.0; full license text in [`LICENSE-Apache-2.0.txt`](LICENSE-Apache-2.0.txt)).

## Runtime availability and local installation

- **No weights required to build/test the codebase:** Filename search, keyword search, the Rust coordinator, the public-API macOS frontend, and all automated tests run without model binaries.
- **Semantic search requires separately supplied Core AI artifacts:** The `.aimodel` graphs and host tables verified by `manifest.json` are produced using Apple's external Core AI authoring toolchain (`coreai_torch`) from the upstream Apache 2.0 checkpoint; this repository does not bundle an automated end-to-end Core AI `.aimodel` export pipeline or hosted model download mirror.
- Once the matching Core AI assets and host tables are placed in `models/CoreAI/`, verify every SHA-256 checksum against `manifest.json` and install them to `~/Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1/`:

```sh
bash scripts/install-runtime.sh
```

On first launch after installation, Swiftlight specializes the Core AI models for the local Apple Neural Engine. App and filename search continues working immediately while semantic indexing prepares in the background.
