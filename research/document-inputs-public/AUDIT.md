# Reference and production audit

This audit precedes the retrieval evaluation. The earlier `eg2ref.py` and `subsets.py` were inspected before reuse. Their model and dataset revisions were checked against Hugging Face. The checkpoint and tokenizer SHA-256 values match the downloaded files. The model revision is pinned even though Hugging Face's current repository head has advanced without changing those weights.

## What was retained

The original reference's fixed-point bicubic coefficients, two-pass resize, row-major 16-pixel patch layout, x/y positions, padding, and image token construction match `VisionHostPrep.swift`. Its image feature method returns only valid pooled rows. The 512-to-768 projection lives inside the HF text model, so mean pooling its `last_hidden_state` is appropriate. The input embedding module already applies the square-root-of-512 scale. Neither scale nor output projection should be applied a second time.

These are source-review conclusions. `parity.json` records the separate numerical checks against the installed HF processor and the model's full forward method. They establish consistency inside PyTorch, not agreement with the app's Core AI runtime. The latter remains for the owner's separate replay.

## What was changed

The inherited reference had no completed parity or retrieval results. Its cache default pointed outside this study's cache directory, and it did not verify downloaded weights. This run uses guarded persistent storage, offline model loading, pinned packages, file hashes, and atomic per-page checkpoints. The October temp-based attempt was lost during a reboot. The November restart uses `~/.swiftlight-research/public-bench/` and commits every completed subset.

Python's code-point slicing was changed to extended grapheme clusters for Swift's `String.prefix(4000)` behavior. Oversized mixed prefixes now fail rather than accepting a negative remaining text budget. Synthetic titles are never derived from answers, question-generation prompts, or document summaries.

The inherited dataset definitions were a source plan, not a working loader. The new loader checks asset revision IDs, joins paired OCR by exact image filename, groups repeated questions into multi-positive relevance judgments, deduplicates pages, and handles the different v2 corpus/query/qrel structure. ArXiv figure identifiers supply paper clusters. Infographic URLs supply image clusters and filename fallback titles. A parent directory such as `images` or `s1600` is not a title.

## Production facts and limits

`Model.swift` supplies `task: search result | query: ...` and `title: ... | text: ...`. The title comes from PDF metadata, with filename fallback in `Indexer.pdf`. `VisionHostPrep.compose` supplies `[2,255999] + [258880]*n + [258882,1]`. Budget 280 is a ceiling. The resize can yield fewer than 280 valid soft tokens. For example, the parity pages yield 266.

The requested P baseline is implemented as the stated 200-character rule. The source has additional behavior. `SearchText.hasWords` suppresses vectors for text made mostly of digits. `PageTextProblem` can trigger OCR or both a garbled-text vector and an image vector. Public raster datasets do not expose the original PDF text layer and its errors, so those branches cannot be reconstructed. The report labels P as an OCR-based proxy and does not equate it with an app replay.

The public raster images substitute for PDFKit's page render. They fit within 1400 pixels without upscaling before the exact host resize. The pixels then enter the reference vision model in FP32. Core AI rounds its prepared tensors and intermediate results to FP16. PyTorch FP16 is inappropriate here because the model's activation range can overflow. The HF model card recommends BF16 or FP32. No Core AI or Neural Engine execution is used in this study.

Mixed inputs have no production implementation. Their exact IDs are defined by `mixed_ids` and exported for replay. All hard and soft tokens share one noncausal forward pass and one mean-pooled, normalized output. V2+P assigns mixed vectors their own centering group, a research convention requiring an explicit production storage decision.

## Sources

- [EmbeddingGemma 2 model card](https://huggingface.co/google/embeddinggemma-2/blob/914f7f89142e33e77833254d9c9b90c3cef7303b/README.md)
- [HF EmbeddingGemma 2 implementation](https://github.com/huggingface/transformers/blob/144ecf007b8b4f2910da104c84a79801db6985a6/src/transformers/models/embedding_gemma2/modeling_embedding_gemma2.py)
- [ViDoRe energy dataset](https://huggingface.co/datasets/vidore/syntheticDocQA_energy_test)
- [ViDoRe lecture dataset](https://huggingface.co/datasets/vidore/biomedical_lectures_eng_v2)
- Repository source at the recorded base commit: `vendor/DigUp/Sources/DigUpKit/Model.swift`, `Indexer.swift`, `SearchText.swift`, `vendor/DigUp/Sources/DigUpCoreAIRuntime/VisionHostPrep.swift`, and `backend/src/semantic.rs`.
