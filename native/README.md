# LumaScore Native

当前版本 2.6.0。SwiftUI + Metal + AVFoundation，中英双语。

在此目录运行 `./build.sh`，或打开 `LumaScore.xcodeproj`。输出为 `build/DerivedData/Build/Products/Release/LumaScore.app`。

测试入口为上级目录的 `scripts/test-native.sh`；Fixtures 是程序生成的测试 MIDI 和音频，不是私人媒体。WebM 编码器随 Resources 打包，适用限制和第三方许可证见根目录 README 和 THIRD_PARTY_NOTICES.md。

项目使用 `.lumascore` 扩展名与独立文档标识，设置和个人预设使用 LumaScore 存储键。内置预设直接用 Swift 原生设置定义，不依赖网页资源。使用指南与验证摘要位于 `../docs/`。
