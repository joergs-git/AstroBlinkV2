# Vendored Zstandard (zstd) 1.5.7

Source: https://github.com/facebook/zstd, release v1.5.7, directory `lib/`.
License: BSD 3-Clause (see `LICENSE`). zstd is dual-licensed BSD/GPLv2; we use it under BSD.

Included: `common/`, `compress/`, `decompress/`, `zstd.h`, `zstd_errors.h` — the
single-threaded core library that libxisf needs for the XISF `zstd` and `zstd+sh`
codecs (XISF 1.0 Revision 1, September 2026).

Excluded on purpose:
- `decompress/huf_decompress_amd64.S` — the x86-64 BMI2 assembly fast path. Dropped so
  the target stays plain C for SwiftPM; `ZSTD_DISABLE_ASM` is defined in `Package.swift`
  so the C fallback is compiled instead. Apple Silicon never used it anyway.
- `dictBuilder/`, `legacy/`, `deprecated/`, `dll/` — dictionary training, pre-0.8
  format support and Windows DLL glue. Not needed for XISF.

No source file is modified. To upgrade, replace the three directories and the two
headers with the same set from a newer release and bump the version here.
