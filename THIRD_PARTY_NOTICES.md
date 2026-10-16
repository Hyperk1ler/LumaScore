# Third-party components

LumaScore 自有源码、文档和原创设计资源采用根目录 `LICENSE` 中的 MIT License，Copyright (c) 2026 Hyperk1ler。

This MIT license applies to LumaScore's own source code, documentation and original design assets. It does not replace or modify the licenses of the third-party components listed below. Their copyright and license notices remain applicable.

## WebM runtime

`native/Resources/WebMRuntime/` contains a separately invoked FFmpeg executable and ABI-matching dynamic libraries. Its architecture is arm64 and its minimum macOS version is 27. This runtime is not required for native MP4 encoding.

Complete bundled license texts, copyright notices and Homebrew recipes are retained under `native/Resources/WebMRuntime/Licenses/`. Exact binary hashes, source package versions, source URLs and source checksums are recorded in `provenance.json`. The bundled FFmpeg build is GPL-3.0-or-later and includes x264/x265. Its dependencies retain their individual GPL, LGPL, BSD, Apache and other licenses. The MIT license does not apply to these files.

The codec runtime's corresponding source is distributed separately at no charge alongside the application in GitHub Releases:

[LumaScore v2.7.0 WebMRuntime source ZIP](https://github.com/Hyperk1ler/LumaScore/releases/download/v2.7.0/LumaScore-v2.7.0-WebMRuntime-source.zip)

The archive contains all 13 pinned upstream source archives, covering the 20 shipped binaries and two SDL build dependencies, plus original recipes, recorded patches, build configuration, reconstruction/relocation scripts and SHA-256 checksums. Exact versions, source hashes and binary ownership are recorded in `native/Resources/WebMRuntime/source-lock.json`. See [source and rebuild instructions](docs/webm-corresponding-source.md). Keep this source download available while distributing the matching runtime; update the source delivery when changing its binaries.

`native/Tools/package-webm-runtime.py` records the local relocation process. The runtime uses loader-relative paths and is invoked as a separate process. Native frameworks remain supplied by macOS and Xcode.

## Homebrew recipes

The retained Homebrew build recipes use the BSD 2-Clause license. Their notice is included in `native/Resources/WebMRuntime/BuildRecipes/HOMEBREW_LICENSE.txt` and in the corresponding-source archive.
