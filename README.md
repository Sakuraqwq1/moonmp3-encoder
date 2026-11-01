# moonmp3-encoder

纯 MoonBit 实现的 **MP3 编码器**：把 PCM 采样写成 MPEG-1 Layer III 流。

> 状态：**早期开发中（结构里程碑）**。帧头、边信息与 CBR 帧尺寸控制已就绪，输出是处处可解析、可解码的合法 MP3 流；主数据目前仍为静音，MDCT、量化与 Huffman 编码在接下来的版本落地。

## 为什么需要它

MoonBit 生态里已有纯 MoonBit 的 MP3 **解码器**（`enanandesu/mp3`），生态里的播放库（`moon_rodio` 等）也能播 MP3，但没有任何一个库能**写出**一个字节的 MP3。想在浏览器里导出压缩音频、想在 CI 里生成 MP3 测试数据，只能退回 C 工具链。

本项目补上"写出"这一半：纯 MoonBit、零 FFI、可在 wasm-gc 与 native 上跑，输出是标准 MP3 流，任何解码器（libsndfile、ffmpeg、浏览器）都能读。

## 目标范围（v1）

- MPEG-1 Layer III，44100 Hz，单声道 / 立体声
- 固定比特率 128 kbps
- 长块（`block_type = 0`）；短块、联合立体声、VBR 留给后续版本
- 明确不做：解码（生态已有）、播放与设备 IO

## 用法

```
moon add Sakuraqwq1/moonmp3-encoder
```

```
// 交织的有符号 16-bit PCM
let samples : Array[Int32] = [0, 0, 100, -100]
let mp3 : Bytes = @moonmp3_encoder.encode(samples, 44100, 2)
```

> 当前版本是结构里程碑：输入采样值尚未参与编码，输出固定为静音。请勿把 0.1.x 用于真实音频导出；MDCT、量化与 Huffman 编码落地后会更新这里的能力说明。

## 验证方式

编码器的正确性不靠"能跑"判断：`tools/verify.py` 用 libsndfile（其 MP3 解码由 mpg123 提供，完全独立于 MoonBit 生态）解码本编码器的输出，检查流长度、帧结构与静音正确性；`tools/mp3dump.py` 逐帧解析 MP3 流，是对照参考实现的检查器。

## 许可证与参考

Apache-2.0，原创实现。

- 规范：ISO/IEC 11172-3（MPEG-1 Audio）
- 不读取、不移植 shine 或 LAME（均为 LGPL）；Huffman 表计划采用 CC0-1.0 的 minimp3 表作为数据，来源会在落地时在仓库中注明
