# moonmp3-encoder

[![CI](https://github.com/Sakuraqwq1/moonmp3-encoder/actions/workflows/ci.yml/badge.svg)](https://github.com/Sakuraqwq1/moonmp3-encoder/actions/workflows/ci.yml)

纯 MoonBit 实现的**通用 MP3 编码器**：把 PCM 采样写成 MPEG-1 Layer III 流，覆盖 MPEG-1 全部 3 档采样率、14 档标准 CBR 码率与单/双声道，共 **84 组标准编码配置**。

> 状态：**通用多采样率 / 多码率编码可用**。帧头、边信息、CBR 帧尺寸控制、多相分析滤波器组、长/短块 MDCT 与窗切换、big_values + count1（Table A 提前终止）Huffman、`global_gain` 搜索、32/44.1/48 kHz 三套 21 带 scalefactor band、瞬态短块切换与近满幅 headroom 都已就绪并经外部验证；3 × 14 × 2 = **84 组配置 100% 编码与独立解码通过**。分析层是**已验证解码器链的逆**（无量化闭环白噪声 84.44 dB），440 Hz–12 kHz 的 23 个正弦探针端到端 SNR **27.57–32.61 dB**（440 Hz 29.31 dB），同码率对比 LAME 128 kbps 在正弦/多音/扫频/白噪声四个探针上优于 LAME，满幅探针因保留约 1 dB 防削顶余量低于 LAME（17.9 vs 26.0 dB，归一到同一电平后 28.92 dB 高于 LAME）。具体版本与变更见 [CHANGELOG](CHANGELOG.md)。

## 为什么需要它

MoonBit 生态里已有纯 MoonBit 的 MP3 **解码器**（`enanandesu/mp3`），生态里的播放库（`moon_rodio` 等）也能播 MP3，但没有任何一个库能**写出**一个字节的 MP3。想在浏览器里导出压缩音频、想在 CI 里生成 MP3 测试数据，只能退回 C 工具链。

本项目补上"写出"这一半：纯 MoonBit、零 FFI、可在 wasm-gc 与 native 上跑，输出是标准 MP3 流，互操作测试覆盖 libsndfile（mpg123）和 FFmpeg。

## 核心功能与参数范围

- MPEG-1 Layer III（ISO/IEC 11172-3），纯 MoonBit 实现、零 FFI，同一份代码编译到 `wasm-gc` 与 `native`
- **采样率：3 档 MPEG-1 标准值**，`32000` / `44100` / `48000` Hz
- **码率：14 档 MPEG-1 标准 CBR**，`32 / 40 / 48 / 56 / 64 / 80 / 96 / 112 / 128 / 160 / 192 / 224 / 256 / 320` kbps（默认 128 kbps）
- **声道：单声道 / 双声道立体声**
- 合计 **3 档采样率 × 14 档码率 × 单/双声道 = 84 组标准编码配置**，逐组实测编码并由独立解码器解码校验通过（`python tools/rates.py`）
- 长块 + 瞬态短块/窗切换（`block_type` 0/1/2/3），窗与 MDCT 余弦矩阵跨帧缓存
- 采样率自适应的 scalefactor band：Table B.8.a（32 kHz）、B.8.b（44.1 kHz）、B.8.c（48 kHz）三套 21 带长块与 12 带短块边界
- 15 张可选的 MPEG-1 `big_values` Huffman 表（1–3、5–13、15、16、24）与 `count1` Table A。全零 granule 的最小编码开销可降至 **1 bit**
- 跨帧位保留区（`main_data_begin`）与近满幅输入的连续衰减
- 明确不做：MP3 解码（生态已有）、MPEG-2 / MPEG-2.5 半采样率（8–24 kHz）、VBR / 联合立体声、复杂心理声学掩蔽模型、播放与设备 IO

## 用法

在已有的 MoonBit 模块中安装依赖。

```bash
moon add Sakuraqwq1/moonmp3-encoder
```

在使用它的目录下，将依赖加入 `moon.pkg` 的测试导入。

```moonbit
import {
  "Sakuraqwq1/moonmp3-encoder" @moonmp3_encoder,
} for "test"
```

将以下示例保存为 `encode_test.mbt`，运行 `moon test`。

```moonbit
test "encode signed 16-bit PCM" {
  let samples : Array[Int32] = [0, 0, 100, -100]
  let a = @moonmp3_encoder.encode(samples, 44100, 2)
  let b = @moonmp3_encoder.encode(samples, 48000, 2, bitrate=192)
  let c = @moonmp3_encoder.encode_at(samples, 32000, 1, 64000)
  assert_eq(a.length(), 2925)
  assert_eq(b.length(), 4032)
  assert_eq(c.length(), 2016)
}
```

采样按声道交织，取值范围为 `[-32768, 32767]`。码率参数可用 kbps（如 `192`）或 bps（如 `192000`），省略时为 128 kbps。

编码器会刷新尾部，调用方可直接传入原始 PCM。每声道的输入采样数按 1152 向上取整后加一帧，输出至少 7 帧。短流补帧用于帮助解码器自动识别，遵循原采样率和 CBR 帧长。直接解码的 PCM 含起始延迟和尾部填充。

`sample_rate` 只接受 `32000` / `44100` / `48000`，`bitrate` 只接受上表 14 档标准值，其余参数以 `UnsupportedSampleRate` / `UnsupportedBitrate` / `UnsupportedChannels` 拒绝——非法参数不会静默产出不合规的流。

> 核心声学与技术指标：稳态音调主频偏差 ≤0.12 Hz、扫频探针 SNR 27.57–32.61 dB；正弦/多音/扫频/白噪声四个探针优于同码率 LAME；满幅探针因保留约 1 dB 防削顶余量低于 LAME（17.9 vs 26.0 dB），归一到同一电平后 28.92 dB 高于 LAME；已接入采样率自适应的 scalefactor band、位保留区和瞬态短块切换，44.1 kHz / 128 kbps 的 440 Hz 单声道满幅正弦回归用例解码峰值 ≤1.00，输出电平低约 1.2 dB。

### 质量边界

- 本项目**没有心理声学掩蔽模型**：位分配以固定 SNR 判据和位预算收敛为目标，不按人耳掩蔽曲线丢弃"听不见"的成分。因此"支持 32–320 kbps 全档"是**格式与参数覆盖**的声明，不等于音质对标 LAME。
- 纯音探针上 SNR 与码率基本无关：此前的 44.1 kHz 单声道 440 Hz 探针在 32–320 kbps 全部 14 档测得 **29.40 dB**（编码器按目标信噪比收敛后不再花掉多余预算；多出来的位变成帧内填充/保留区，不会自动变成更高的重建精度）。
- 32 kHz 与 48 kHz 单声道 440 Hz 实测 **30.09 dB / 29.10 dB**；全频段扫频（440 Hz–12 kHz，44.1 kHz / 128 kbps）**27.57–32.61 dB**，最差点在 4 kHz。
- 对有声输入，编码器从量化结果估算 PCM 峰值。估算峰值越过阈值时，以整段统一的增益降低电平。满幅宽带、瞬态及约 0.74 FS 的宽带回归用例由 mpg123 与 FFmpeg 验证解码采样峰值 ≤1.0。
- 短块按采样率重排频线，在 `global_gain` 量化后对 12 个频带 × 3 个窗口独立搜索 scalefactor。候选按重建误差下降与位开销排序，并用完整 granule 的精确位数确认预算。
- 白噪声这类平坦信号约 13.5 dB，属 128 kbps 单声道下量化格点的固有边界，不是结构缺陷。
- 低码率下真正受限的是**位预算**而非本次新增的采样率/码率通路：`count1` 1-bit 提前终止正是为了在 32–96 kbps 下让每 granule 的位预算装得下。

### 同码率基准测试（vs LAME）

> **测试基准说明**：采用行业标准 `libmp3lame`（128 kbps mono CBR，0.18 s 片段），编码输出统一由第三方独立解码器 `libsndfile` 解码并进行时延对齐后计算信噪比（SNR）：

| 探针 | 本编码器 | LAME 128k | 差异 | 说明 |
| --- | ---: | ---: | ---: | --- |
| 440 Hz 正弦 | 28.30 dB | 26.03 dB | +2.27 dB | 优于 LAME |
| multitone | 27.77 dB | 26.01 dB | +1.76 dB | 优于 LAME |
| 扫频 | 28.34 dB | 26.00 dB | +2.34 dB | 优于 LAME |
| 白噪声 | 13.50 dB | 8.49 dB | +5.01 dB | 优于 LAME |
| 满幅 99 % 正弦 | 17.92 dB | 26.02 dB | -8.10 dB | 防削顶余量（归一化后 28.92 dB 高于 LAME） |

> 复现工具：`python tools/lame_ref.py`（支持 `--json`）。

## 验证方式

编码器的正确性不靠"能跑"判断：

- `tools/rates.py`：**84 组全矩阵**（3 档采样率 × 14 档码率 × 单/双声道）逐组编码并检查每帧头、CBR 填充和位保留区边界。mpg123（经 libsndfile）和 FFmpeg（经 PyAV）各自检查采样率、声道数、样本数和非静音输出。CI 同时运行默认的 4 帧输入和 `--frames 1` 的短输入矩阵。
- `tools/verify.py structure` 分别用 mpg123 和 FFmpeg 解码，检查采样率、帧数、声道数和静音正确性（18 项）。
- `tools/lame_ref.py` 对比 PyAV `libmp3lame` 128k mono CBR 在五个探针上的表现（支持 `--json` 输出）。
- `tools/mp3dump.py` 逐帧解析 MP3 流，可输出人类可读报告或 JSON，并用 `--strict` 检查结构警告。
- `tools/gen_fixtures.py` 生成确定性的正弦、多音、扫频、噪声和瞬态素材，manifest 记录 SHA-256。
- `tools/probe_lines.py` 逐条激励频线并测量解码后的频率，产出 `docs/line-frequencies.md` 那张映射表。
- `tools/analysis_ref.py` 用 numpy 独立重算分析滤波器组与 MDCT，和 MoonBit 输出逐线比对（残差 2e-16）。
- `tools/huffman_tables.py` 校验 15 张 big_values 表与两张 count1 表（Kraft 和、码字冲突、表尺寸）。
- `tools/decoder_ref.py` 复现参考解码器（与 libsndfile 吻合 127.5 dB），再用无量化闭环给分析层打分。
- `tools/cross_spec.py` 把交付的分析子带输出接进已验证解码器，判断它是不是解码器的逆，并证明 `(−1)^n` 是承重的。
- `tools/crossdecode.py` 用 mpg123 与 ffmpeg 两个独立解码器解同一条流并比对（当前相关度 1.000000、差异 125.6 dB）。
- `tools/sweep_snr.py` 扫全频段 SNR，专治"抽查几个整数频率都正常"的错觉。
- `tools/snr.py` 测量逐声道和整体 SNR，可按已知延迟（本编码器 1057）对齐。
- `moon run cmd/main -- gen 48000 192000 2 4 440` 在任意采样率 / 码率 / 声道组合下编码一段正弦并打印 base64 流（`tools/rates.py` 就是用它驱动 84 组矩阵的）。
- `moon run cmd/main -- alloc 440 50 5` 打印某个 granule 每个候选增益的精确 Huffman 代价与重建误差，用来判断分配器为什么选了这个增益。
- `tools/spectrum.py` 报告主频和强峰，确认 440/660 Hz 没有丢失或串声道。
- `tools/selftest.py` 验证上述工具本身没有回归（35 例）。
- `tools/doctor.py` 检查 MoonBit、libsndfile、MP3 解码后端和素材是否就绪。
- `tools/check_release.py` 核对版本三处同步、必需文件和 CI 覆盖。

本地一次跑完：

```bash
python tools/gen_fixtures.py --quiet
python tools/selftest.py
python tools/verify.py structure
python tools/rates.py
```

`tools/rates.py` 在任一组合编码、帧结构或解码检查失败时返回非零退出码。

## 开发资料

- [频线到频率的映射](docs/line-frequencies.md)：实测的"尺子"，以及单线探针为什么分不清奇数 bin。
- [测试素材](docs/fixtures.md)：每个 fixture 的内容和预期现象。
- [工具链说明](docs/tooling.md)：素材、帧解析、频谱、SNR 和自测命令。
- [验收自查](docs/acceptance.md)：验收 9 条现状与初审门槛。
- [来源与许可证](docs/provenance.md)：规范、数据表和 oracle 的边界。
- [贡献约定](CONTRIBUTING.md)：门禁、提交和发布规则。

## 许可证与参考

Apache-2.0，原创实现。

- 规范：ISO/IEC 11172-3（MPEG-1 Audio），含 Table B.7（count1 码表）、Table B.8.a/b/c（32/44.1/48 kHz 长块 scalefactor band）
- 不读取、不移植 shine 或 LAME（均为 LGPL），也未查阅 mpg123、libavcodec 源码；分析窗、big_values 与 count1 Table A 数值表取自 `hajimehoshi/go-mp3`（Apache-2.0）的固定版本，blob 与 SHA-256 来源记录见 `docs/provenance.md`
