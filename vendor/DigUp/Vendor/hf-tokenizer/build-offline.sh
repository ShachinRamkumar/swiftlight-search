#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
cargo build --release --offline --locked \
  --config 'source.crates-io.replace-with="vendored-sources"' \
  --config "source.vendored-sources.directory=\"$DIR/crates\"" \
  -j 2
