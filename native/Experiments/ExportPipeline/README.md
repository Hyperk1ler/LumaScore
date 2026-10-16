# 导出流水线实验

三个独立源码快照分别改变调度、像素格式和写入接口。补丁保留在此目录，实验代码不进入应用的 Xcode 构建。

- `scheduling.patch`：GPU 渲染不受 writer readiness 门控，使用完成回调释放的真实槽位；待编码帧有界，按帧编号顺序提交。3／6 帧和缓冲池阈值分别比较。
- `nv12.patch`：同一 GPU 命令缓冲内执行 BGRA → BT.709 视频范围 NV12 转换。使用 2×2 平均滤波与居中色度标记，与现有 AVFoundation 的 left 色度位置不同，暂不能替代默认画面。
- `receiver.patch`：macOS 26+ 使用 PixelBufferReceiver，比较同步接口替换与单个异步 FIFO 提交任务；保留旧接口回退。异步实验有 Swift 5 Sendable 警告，尚未完成正式状态隔离。
- `scheduling-reviewed.patch`：另存的三帧候选，移除调度诊断与可调缓存，串行处理 reader／writer 取消，覆盖最终化与 WebM 子进程退出。未参加下文 70 次计时，不能把带诊断版本的性能数字直接当成它的结果；默认复现不包含此候选。可用 `--variants baseline,prefetch3-reviewed` 单独比较。

`source-lock.json` 锁定基线源码和补丁的 SHA-256。脚本只在新输出目录复制和修改源码，先完成所有编译，再串行交替测试，避免同时运行 GPU 或编译器影响测量。当前补丁针对 2.7.0 的导出实现；源码变化后必须显式重建基线及重写补丁。

```sh
python3 native/Tools/benchmark-export-pipeline.py --output native/build/export-reproduce
# 4K 短片波动的针对性复测：
python3 native/Tools/benchmark-export-pipeline.py --output native/build/export-long \
  --variants baseline,prefetch3 --cases hybrid4k --fixture-seconds 30 --trials 3
```

每份视频检查全部帧数、呈现时间网格、尺寸／帧率及固定音频的首个有声样本。AVAssetReader 的零帧起止标记不计入画面；前导空编辑可能解码为真实静音 PCM，不能把首个音频包时间当成声音开始时间。首轮另解码第 3 秒为 PNG。默认仅保留 JSON、日志和 PNG；`--keep-video` 保留完整视频便于逐帧比较。

两种候选交替先后运行；三个及以上候选按轮次轮换并反转。早期记录中的双候选长片测试每轮均先运行基线，是既有数据的局限，公开复现脚本已修正这一顺序问题。源码和固定媒体均校验 SHA-256。

`ExportCancellationRegression.swift` 和 `WebMExportCancellationRegression.swift` 仅针对 reviewed 候选。前者默认验证预启动取消和已有目的文件保护，`--active` 另验证 automatic／legacy 的真实 4K 导出取消及晚回调；后者需要将测试 binary 放入带有应用 Resources 的隔离 `.app`，在 FFmpeg 实际创建临时文件后取消。两者均已运行通过；不是默认测试套件的一部分，也不证明尚未测试的设备兼容性。

`ColorConversionRegression.swift` 检查实际 GPU 转换器的颜色／灰阶及色条回读。色条参考添加了 BT.709 输入附件，因此验证转换公式和范围，不能证明与生产 BGRA 无附件路径及细线采样完全一致。`CompareImages.swift` 在 sRGB 下比较解码 PNG，输出平均误差、99 分位、最大误差和 PSNR。

实验结果与采用决定见 [导出实验记录](../../../docs/performance/export-pipeline.md)。
