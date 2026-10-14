# LumaScore WebM 编码组件源码 / Corresponding source

此包提供 LumaScore 内置 FFmpeg 9.0.2 编码器及其依赖的对应源码、补丁、原始构建配方和重建工具。源码均保留各自许可证，LumaScore 的 MIT 许可证不覆盖第三方组件。

## 获取 / Download

公开下载地址：

https://github.com/Hyperk1ler/LumaScore/releases/download/v2.6.0/LumaScore-v2.6.0-WebMRuntime-source.zip

无需购买或申请访问。该源码包也作为 GitHub Release 的独立资产列出，与应用下载入口并列。发布后应持续保留其可用性；发布改变编码组件的新版应用时，应重新核对和提供对应版本源码。

## 包含内容 / Contents

- `archives/`：13 个锁定版本的原始源码归档，覆盖全部 20 个随应用分发的编码器与动态库。SDL3 和 SDL2 compatibility 是原始 FFmpeg 构建选项所需的额外构建输入，其二进制不随当前 App 分发。
- `source-manifest.json`：源地址、SHA-256、版本、x264 精确提交、组件与二进制对应关系、配方校验值。
- `Licenses/`：完整许可证、版权声明与原始 Homebrew 配方。
- `Patches/`：libvpx 的 Darwin 27 平台补丁与 LAME 导出符号修正。
- `BuildInfo/`：原始 FFmpeg 配置输出及 x264 版本配置头。
- `BuildRecipes/`：SDL 构建配方和 Homebrew 的许可证。
- `tools/`：源码准备、重建与动态库重定位/签名工具。此目录中由 LumaScore 编写的工具使用单独的 MIT 许可证；其他源码保留原许可。
- `SHA256SUMS.txt`：包内所有内容的完整性校验值。

| 组件 | 版本 |
| --- | --- |
| FFmpeg | 9.0.2 |
| dav1d | 1.5.3 |
| LAME | 3.100 |
| libvmaf | 3.2.1 |
| libvpx | 1.17.0 |
| OpenSSL | 3.6.5 |
| Opus | 1.6.1 |
| SVT-AV1 | 4.1.0 |
| x264 | r3222 / b35605ace3ddf7c1a5d67a2eb553f034aef41d55 |
| x265 | 4.3 |
| XZ | 5.8.4 |
| SDL2 compatibility（构建输入） | 2.32.74 |
| SDL3（构建输入） | 3.4.18 |

## 核验与重建 / Verify and rebuild

先解压本源码 ZIP，在 `LumaScore-WebMRuntime-source/` 内执行：

```sh
shasum -a 256 -c SHA256SUMS.txt
bash tools/rebuild-webm-runtime.sh --prepare-only
```

准备步骤离线校验源码，安全解压，应用已记录的 libvpx/LAME 补丁，并从原配置头恢复 x264 的 r3222 版本标识。x264 上游源码归档的全部 270 个文件已与锁定 Git 提交的 blob 标识逐一核对。

完整重建针对 Apple Silicon/macOS 27+，需要 Xcode 命令行工具、Python 3.12+（或包含安全 tarfile.data_filter 的修补版本）、CMake、Meson、Ninja、pkg-config、Make 和 Perl。它们是未修改的通用构建工具或系统组件，不包含在本源码包中。可先自行准备这些工具，再执行：

```sh
bash tools/rebuild-webm-runtime.sh --build
```

脚本仅写入本源码包的 `build/`，不会安装或替换系统 Homebrew 软件。工作目录路径须不含空格，也可通过第二个参数指定工作目录。库按独立前缀构建，最后生成 `build/WebMRuntime/`，包含 FFmpeg、ffprobe 和 ABI 对应动态库。源码归档保留原始文件；构建目录中的补丁、版本标识及 SDL pkg-config 路径替换由脚本明确记录。

原始二进制来自 Homebrew arm64 Golden Gate bottle，FFmpeg 编译器为 Apple clang 21.0.0（clang-2100.3.34.2）。原始配置包含 GPL/version3、x264/x265、VP9/Opus、VideoToolbox 与 AudioToolbox。`BuildInfo/ffmpeg-buildconf.txt` 和各配方保留原始构建细节；重建脚本使用隔离前缀替代原 `/opt/homebrew` 路径，并明确传入这些前缀的 include/library 搜索参数，替代 Homebrew 构建环境的依赖路径设置。

源码、配方与补丁匹配核验不等于字节一致的 bottle 重建。编译器、SDK、构建路径及签名差异会影响二进制哈希；不要将重新签名的二进制预期为原 Homebrew 哈希。

验证环境为 Apple M5/macOS 27、Apple clang 21.0.0，通用工具使用 CMake 3.31.10、Meson 1.9.1、Ninja 1.13.0、pkgconf 3.0.8 和 Python 3.14.6。13 个来源归档的 SHA-256、全部 20 个原始运行二进制的来源映射、离线解压和补丁应用已核验。已完成隔离源码重建及动态库重定位，重建后的 FFmpeg 成功生成 320×180 / 12 fps / 1 秒 VP9+Opus WebM；ffprobe 核验 12 个视频帧和 48 kHz 音频。

重定位工具只解析确切 ABI 名称；同名多版本或不匹配名称会被拒绝。未将重建产物替换为当前发布的编码器，发布仍使用清单记录的原始二进制。

## 重新生成源码包 / Maintainers

在 LumaScore 仓库根目录执行：

```sh
python3 native/Tools/package-webm-source.py --download --verify-only
python3 native/Tools/package-webm-source.py --output outputs/LumaScore-v2.6.0-WebMRuntime-source.zip
```

下载需要 curl；GitHub Release 源码资产通过 `gh api` 获取，需已配置的 GitHub CLI。离线生成仅使用已验证的缓存，不下载或替换任何版本。组件源码不会被加入 Git 仓库，而是作为独立 Release 下载提供。
