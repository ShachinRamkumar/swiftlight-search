# Zstandard decompressor

Pinned upstream: facebook/zstd, tag v1.5.7. `zstddeclib.c` is the standalone
single-file decoder from `build/single_file_libs`. The public headers report
version 1.5.7. The app links no compressor. `LICENSE` contains the selected BSD
terms.

SHA-256 of the imported files:

```
5eb38abe0a7eea13674b312a006df72002d4192f0f0b4d09e6f03fb927a1f3d0  zstddeclib.c
9b4bc8245565c98ccfc61c07749928b57e7c0f6fddb0530c4f6aa1971893d88b  include/zstd.h
66a8c3f71d12ea6e797e4f622f31f3f8f81c41b36f48cad4f5de7d8bfb6aac0a  include/zstd_errors.h
```
