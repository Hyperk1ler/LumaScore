# LumaScore

macOS 上的 MIDI 与音频视觉工作室。用音符、频谱、波形、和弦与 GPU 特效制作可导出的视频。界面保留中文／English。

A native macOS visual studio for MIDI and audio, built with SwiftUI, Metal and AVFoundation. Preview and video export share the same renderer; media stays on your device.

[下载最新版 / Download](https://github.com/Hyperk1ler/LumaScore/releases/latest) · [使用说明](docs/user-guide.zh-CN.md) · [更新记录](docs/history/v2.7.0.md)

当前版本：**2.7.0（build 11）**。应用安装包、自有源码包、WebM 组件对应源码包与 SHA-256 校验文件通过同一 Release 提供。

## 功能

- MIDI、Audio、Hybrid 三种场景；可只导入音频或只导入 MIDI。
- 真实 PCM 频谱与波形、曲目信息、封面和 RMS 仪表。
- 多轨 MIDI、文件／轨道名称、自动读取速度、和弦分析。
- MIDI 分批追加、删除轨道、逐轨流速／位置／时间偏移与整体重置。
- CRT 干扰、鱼眼、GPU 光晕、粒子、调色、镜头反应、标题动画与本地字体。
- 媒体留白仅延后音频和 MIDI；画面和标题从第 0 秒渲染。
- Metal 4 自适应提交、三帧命令内存复用、空光晕跳过与光晕纹理复用；兼容旧 Metal 路径。
- MP4 硬件编码、WebM 导出、项目保存和视觉预设。
- 独立 `.lumascore` 项目格式，六套原生内置预设与可保存的个人预设。

![音频场景的离屏渲染示例](docs/images/audio-scene.png)

## 构建 / Build

需要 macOS 和提供 macOS 26+ SDK 的 Xcode。应用主体目标 macOS 13+，构建 arm64/x86_64；Metal 4 路径在 macOS 26+ 且 GPU 支持时启用，光晕保留 MPS 路径。内置 WebM 编码组件仅支持 Apple Silicon／macOS 27+。当前运行验证覆盖 Apple M5／macOS 27。下载应用使用 ad-hoc 签名，未 Apple 公证。

```sh
git clone https://github.com/Hyperk1ler/LumaScore.git
cd LumaScore
./native/build.sh
```

构建输出为 `native/build/DerivedData/Build/Products/Release/LumaScore.app`。也可直接打开 `native/LumaScore.xcodeproj`，选择 LumaScore / My Mac。保留完整 `native/Resources/` 目录，其中包含 WebM 运行组件及许可证。

## 测试 / Tests

```sh
./scripts/test-native.sh
./scripts/test-native.sh --playback
bash scripts/test-workspace.sh
```

默认测试覆盖音频分析、音乐理论和弦案例与八度不变性、原生预设、MIDI／快捷键反馈、分批导入与删除持久化、项目格式校验、逐轨布局和时间偏移、三种音频模板、速度图节拍及 Metal 通道。支持的设备还检查 Metal 4 像素一致性、三帧并发和实时后端切换。`--playback` 追加静音真实 AVPlayer 播放、延迟交接、暂停、寻址和循环检查。工作区测试检查四种收起状态和测试 App 自己的原生标题栏。需要本机 Metal；测试程序与日志写入被忽略的 `native/build/tests/`。

持续 GUI 呈现帧率尚未实测；测试结果区分播放时钟与离屏渲染验证。

完整 MP4 导出在本机对照中没有显著加速，Metal 4 的离屏吞吐结果不代表预览帧率或导出速度。Metal 4 的实测结果、运行条件和复现方法见[性能记录](docs/performance/metal4.md)。命令行 `--benchmark --renderer legacy` 保留参考通道，默认 `--renderer automatic` 选择可用路径；导出 JSON 记录实际使用的后端。

调度、NV12 转换与新写入接口的三路对照见[导出流水线实验](docs/performance/export-pipeline.md)。实验补丁与独立复现脚本保留在仓库中，未替换应用默认导出路径。

## 目录

| 路径 | 内容 |
| --- | --- |
| `native/` | 当前应用源码、Xcode 工程、固定测试媒体与运行资源 |
| `native/Experiments/` | 独立导出实验、补丁及验证工具，不参与应用构建 |
| `docs/` | 使用指南、历史更新和验证摘要 |
| `scripts/` | 测试与发布打包脚本 |
| `outputs/` | 本机最新版交付文件，不进入 Git |
| `Design.pen`、`docs/design/` | 可编辑 UI 与音频场景设计参考 |

完整安装包通过 GitHub Releases 提供，避免将重复构建产物写入 Git 历史。内置编码器及依赖的[对应源码包](https://github.com/Hyperk1ler/LumaScore/releases/download/v2.7.0/LumaScore-v2.7.0-WebMRuntime-source.zip)也在同一 Release 免费提供；包含精确版本、补丁、构建配方及[重建说明](docs/webm-corresponding-source.md)。

## License / 许可证

LumaScore 自有源码、文档和原创设计资源采用 [MIT License](LICENSE)，Copyright (c) 2026 Hyperk1ler。允许使用、修改、商用和再发布，须保留版权及许可证声明。

第三方组件不被重新授权为 MIT，仍遵循各自许可证。内置 FFmpeg 编码器使用 GPL-3.0-or-later；其依赖另有 GPL、LGPL、BSD 和 Apache 等协议。组件的版权、许可证和来源记录见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
