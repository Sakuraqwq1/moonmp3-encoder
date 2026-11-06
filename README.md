# moonmp3-encoder

[![CI](https://github.com/Sakuraqwq1/moonmp3-encoder/actions/workflows/ci.yml/badge.svg)](https://github.com/Sakuraqwq1/moonmp3-encoder/actions/workflows/ci.yml)

纯 MoonBit 实现的 **MP3 编码器**：把 PCM 采样写成 MPEG-1 Layer III 流。

> 状态：**阶段 2 收口**。帧头、边信息、CBR 帧尺寸控制、多相分析滤波器组、长/短块 MDCT 与窗切换、big_values + count1 Huffman、`global_gain` 搜索、21 个长块 scalefactor band、瞬态短块切换与近满幅 headroom 都已就绪。分析层是**已验证解码器链的逆**（无量化闭环白噪声 84.44 dB），全频段端到端 SNR **27.6–32.7 dB**（440 Hz 29.3 dB），同码率对比 LAME 128 kbps 在正弦/多音/扫频/白噪声四个探针上优于 LAME，满幅探针因保留约 1 dB 防削顶余量低于 LAME（17.9 vs 26.0 dB，归一到同一电平后 28.92 dB 高于 LAME）；详见 `docs/stage2-progress.md`。

## 为什么需要它

MoonBit 生态里已有纯 MoonBit 的 MP3 **解码器**（`enanandesu/mp3`），生态里的播放库（`moon_rodio` 等）也能播 MP3，但没有任何一个库能**写出**一个字节的 MP3。想在浏览器里导出压缩音频、想在 CI 里生成 MP3 测试数据，只能退回 C 工具链。

本项目补上"写出"这一半：纯 MoonBit、零 FFI、可在 wasm-gc 与 native 上跑，输出是标准 MP3 流，任何解码器（libsndfile、ffmpeg、浏览器）都能读。

## 目标范围（v1）

- MPEG-1 Layer III，44100 Hz，单声道 / 立体声
- 固定比特率 128 kbps
- 长块 + 瞬态短块/窗切换（`block_type` 0/1/2/3）；联合立体声、VBR 留给后续版本
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

> 当前是阶段 2 的收口状态：稳态音调主频偏差 ≤0.12 Hz、整段 SNR 27.6–32.7 dB；正弦/多音/扫频/白噪声四个探针优于同码率 LAME；满幅探针因保留约 1 dB 防削顶余量低于 LAME（17.9 vs 26.0 dB），归一到同一电平后 28.92 dB 高于 LAME；已接入 scalefactor band、位保留区和瞬态短块切换，输入峰值 50–100 % 时解码峰值全部严格保持在 ≤1.00 以内（代价是满幅输出电平低约 1.2 dB）。白噪声这类平坦信号约 13 dB，属 128 kbps 单声道下量化格点的固有边界，不是结构缺陷。

### 同码率对比（PyAV libmp3lame 128 kbps mono CBR，0.18 s 片段，libsndfile 解码，延迟对齐）

| 探针 | 本编码器 | LAME 128k | 差异 | 说明 |
| --- | ---: | ---: | ---: | --- |
| 440 Hz 正弦 | 28.30 dB | 26.03 dB | +2.27 dB | 优于 LAME |
| multitone | 27.77 dB | 26.01 dB | +1.76 dB | 优于 LAME |
| 扫频 | 28.34 dB | 26.00 dB | +2.34 dB | 优于 LAME |
| 白噪声 | 13.51 dB | 8.49 dB | +5.02 dB | 优于 LAME |
| 满幅 99 % 正弦 | 17.92 dB | 26.02 dB | -8.10 dB | 防削顶余量（归一化后 28.92 dB 高于 LAME） |

> 复现工具：`python tools/lame_ref.py`（支持 `--json`）。

## 验证方式

编码器的正确性不靠"能跑"判断：

- `tools/verify.py structure` 用 libsndfile（其 MP3 解码由 mpg123 提供，完全独立于 MoonBit 生态）解码输出，检查帧网格、长度和静音正确性。
- `tools/lame_ref.py` 对比 PyAV `libmp3lame` 128k mono CBR 在五个探针上的表现（支持 `--json` 输出）。
- `tools/mp3dump.py` 逐帧解析 MP3 流，可输出人类可读报告或 JSON，并用 `--strict` 检查结构警告。
- `tools/gen_fixtures.py` 生成确定性的正弦、多音、扫频、噪声和瞬态素材，manifest 记录 SHA-256。
- `tools/probe_lines.py` 逐条激励频线并测量解码后的频率，产出 `docs/line-frequencies.md` 那张映射表。
- `tools/analysis_ref.py` 用 numpy 独立重算分析滤波器组与 MDCT，和 MoonBit 输出逐线比对（残差 2e-16）。
- `tools/huffman_tables.py` 校验 15 张 big_values 表（Kraft 和、码字冲突、表尺寸）。
- `tools/decoder_ref.py` 复现参考解码器（与 libsndfile 吻合 127.5 dB），再用无量化闭环给分析层打分。
- `tools/cross_spec.py` 把交付的分析子带输出接进已验证解码器，判断它是不是解码器的逆，并证明 `(−1)^n` 是承重的。
- `tools/crossdecode.py` 用 mpg123 与 ffmpeg 两个独立解码器解同一条流并比对（当前相关度 1.000000）。
- `tools/sweep_snr.py` 扫全频段 SNR，专治"抽查几个整数频率都正常"的错觉。
- `tools/snr.py` 测量逐声道和整体 SNR，可按已知延迟（本编码器 1057）对齐。
- `moon run cmd/main -- alloc 440 50 5` 打印某个 granule 每个候选增益的精确 Huffman 代价与重建误差，用来判断分配器为什么选了这个增益。
- `tools/spectrum.py` 报告主频和强峰，确认 440/660 Hz 没有丢失或串声道。
- `tools/selftest.py` 验证上述工具本身没有回归。
- `tools/doctor.py` 检查 MoonBit、libsndfile、MP3 解码后端和素材是否就绪。
- `tools/check_release.py` 核对版本三处同步、必需文件和 CI 覆盖。

本地一次跑完：

```bash
python tools/gen_fixtures.py --quiet
python tools/selftest.py
python tools/verify.py structure
```

## 开发资料

- [阶段 1 交接](docs/stage1-handoff.md)：完成判据、数据流边界、调试顺序。
- [频线到频率的映射](docs/line-frequencies.md)：实测的"尺子"，以及单线探针为什么分不清奇数 bin。
- [测试素材](docs/fixtures.md)：每个 fixture 的内容和预期现象。
- [工具链说明](docs/tooling.md)：素材、帧解析、频谱、SNR 和自测命令。
- [验收自查](docs/acceptance.md)：验收 9 条现状与初审门槛。
- [来源与许可证](docs/provenance.md)：规范、数据表和 oracle 的边界。
- [贡献约定](CONTRIBUTING.md)：门禁、提交和发布规则。

## 许可证与参考

Apache-2.0，原创实现。

- 规范：ISO/IEC 11172-3（MPEG-1 Audio）
- 不读取、不移植 shine 或 LAME（均为 LGPL）；分析窗与 big_values Huffman 数值表取自 `hajimehoshi/go-mp3`（Apache-2.0）的固定版本，blob 与 SHA-256 来源记录见 `docs/provenance.md`
