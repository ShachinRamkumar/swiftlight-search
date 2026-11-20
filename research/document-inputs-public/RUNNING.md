# Run and resume the public benchmark

The cache and scratch live in `~/.swiftlight-research/public-bench/`. They survive a reboot. The guarded downloader uses a cumulative 4,000,000,000-byte cap for this reacquired run, including a conservative 500 MB reserve for package installation and source inspection. It stops before a download would leave less than 14 GiB free. The October attempt's temp directory and embeddings were lost during the reboot and are not reused.

The pinned environment and model are acquired once:

```sh
TASK_ROOT="$HOME/.swiftlight-research/public-bench"
mkdir -p "$TASK_ROOT/tmp"
python3.13 -m venv "$TASK_ROOT/venv"
TMPDIR="$TASK_ROOT/tmp" PIP_CACHE_DIR="$TASK_ROOT/pip-cache" HF_HOME="$TASK_ROOT/hf" "$TASK_ROOT/venv/bin/pip" install --no-cache-dir -r research/document-inputs-public/requirements-lock.txt
PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" research/document-inputs-public/acquire.py
PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" research/document-inputs-public/checks.py
PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" research/document-inputs-public/restart_checks.py
```

Run the benchmark, or resume with the same command:

```sh
PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" -u research/document-inputs-public/run.py
```

Each query and each page is an atomic, fsynced checkpoint. A page record contains all five embeddings and its input statistics in one file. An unfinished `.part` file is ignored on restart. A fingerprint covers the reference implementation, model revision, page identities, titles, OCR text, queries, and relevance judgments. A changed fingerprint stops the run instead of mixing incompatible embeddings.

Completed subsets have a compact embedding file and a completion marker. The runner skips their inference and evaluation. It records each completed subset's summary, per-query metrics, input statistics, aggregate progress, and `STATUS.md` locally. The parity check runs again after acquisition or when the reference changes. Use `--recheck-parity` to force it.

Optional metadata and raster prefetch reduce signed-URL expiry during a long run:

```sh
SWIFTLIGHT_DOWNLOAD_LEDGER=prefetch-downloads.json PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" research/document-inputs-public/data.py energy shift arxivqa infovqa ai biomedical_lectures
PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" research/document-inputs-public/prefetch.py energy shift arxivqa infovqa ai biomedical_lectures
```

Run one writer per download ledger. The model runner and prefetcher use separate ledgers, with a shared reservation lock enforcing the combined cap. Consumption is persisted after every network chunk. Model `.part` files support HTTP range resume and must pass the complete file's size and SHA-256 checks.

After all subsets finish, generate and verify the retained artifacts:

```sh
PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" research/document-inputs-public/pool.py
PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" research/document-inputs-public/diagnostics.py
PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" research/document-inputs-public/report.py
PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" research/document-inputs-public/chart.py
PYTHONDONTWRITEBYTECODE=1 "$TASK_ROOT/venv/bin/python" research/document-inputs-public/verify.py
```

Delete the owned downloads, raw metadata, rasters, environment, and embedding caches only after the results and verification are saved. Third-party dataset rasters are not committed to Git. This runner uses PyTorch MPS and CPU Tesseract only.
