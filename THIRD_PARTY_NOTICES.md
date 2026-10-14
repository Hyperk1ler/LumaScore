# Third-party components

项目自身暂未指定统一开源许可证。以下组件的声明分别适用。

## WebM runtime

`native/Resources/WebMRuntime/` contains a separately invoked FFmpeg executable and ABI-matching dynamic libraries. Its architecture is arm64 and its minimum macOS version is 27. This runtime is not required for native MP4 encoding.

Complete bundled license texts, copyright notices and Homebrew recipes are retained under `native/Resources/WebMRuntime/Licenses/`. Exact binary hashes, source package versions, source URLs and source checksums are recorded in `provenance.json`. The FFmpeg build includes GPL components, including x264/x265; it is not an LGPL-only runtime. Do not apply a project-wide license to these files.

`native/Tools/package-webm-runtime.py` records the local relocation process. The runtime uses loader-relative paths and is invoked as a separate process. Native frameworks remain supplied by macOS and Xcode.
