# Third-party components

LumaScore 自有源码、文档和原创设计资源采用根目录 `LICENSE` 中的 MIT License，Copyright (c) 2026 Hyperk1ler。

This MIT license applies to LumaScore's own source code, documentation and original design assets. It does not replace or modify the licenses of the third-party components listed below. Their copyright and license notices remain applicable.

## WebM runtime

`native/Resources/WebMRuntime/` contains a separately invoked FFmpeg executable and ABI-matching dynamic libraries. Its architecture is arm64 and its minimum macOS version is 27. This runtime is not required for native MP4 encoding.

Complete bundled license texts, copyright notices and Homebrew recipes are retained under `native/Resources/WebMRuntime/Licenses/`. Exact binary hashes, source package versions, source URLs and source checksums are recorded in `provenance.json`. The bundled FFmpeg build is GPL-3.0-or-later and includes x264/x265. Its dependencies retain their individual GPL, LGPL, BSD, Apache and other licenses. The MIT license does not apply to these files.

The application's source ZIP does not include a complete corresponding-source bundle for the codec runtime. License texts, recipes and provenance alone do not establish that all corresponding-source distribution requirements have been fulfilled; that delivery remains to be completed separately.

`native/Tools/package-webm-runtime.py` records the local relocation process. The runtime uses loader-relative paths and is invoked as a separate process. Native frameworks remain supplied by macOS and Xcode.
