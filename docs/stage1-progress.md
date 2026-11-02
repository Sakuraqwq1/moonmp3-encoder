# 阶段 1 进度记录

## 2026-11-03：PCM → 频线 → 位流打通（首个可听链路）

### 做了什么

- **分析窗表**：`src/mp3/window.mbt`，512 个 ISO/IEC 11172-3 Annex B 系数，
  取自 `hajimehoshi/go-mp3`（Apache-2.0，blob 与 SHA-256 记在 `docs/provenance.md`）。
  `tools/window_table.py` 可复现并逐项校验，`--check` 当门禁用。
- **分析滤波器组**：`src/mp3/analysis.mbt`。
  `S[m] = sum(n) x[n] C[n] cos((16 + n mod 64)(2m + 1) pi / 64)`，512 点滑窗 + 32 子带。
- **长块 MDCT**：同文件。36 点正弦窗、18 条输出线，符号与频线顺序按规范。
- **量化**：`src/mp3/quantize.mbt`。把每个 granule 压到 count1 能表示的 -1/0/1，
  `global_gain = 210 + 4 log2(peak)`；带预算控制，系数过多时抬高门限而不是撑爆帧。
- **`encode()` 真正编码**：公开签名与帧布局不变，主数据不再全零。
- **CLI**：新增 `sine`（内部生成正弦，可任意长）、`encode`（base64 PCM）、
  `lines`（导出一个 granule 的 576 条频线）；`tone` 支持逗号分隔的多条频线。
- **量具**：`tools/probe_lines.py`（频线→频率实测）、`tools/analysis_ref.py`
  （numpy 独立参考 + 逐线比对）、`tools/window_table.py`（窗口表来源校验）。

### 三个必须记住的坑

1. **分析滤波器组的折叠不能想当然。** 先用"块内镜像折叠"写，滤波器组看起来正常工作、
   位流也合法，但每个相邻子带漏进 4 dB：440 Hz 正弦的能量分散到子带 0/1/2/4/6，
   解码主频跑到 1816 Hz。改成按定义式直接求和（窗 → 8 块按列相加 → 32×64 矩阵）
   之后，344 Hz 单音在子带 0 的能量占比 0.9996。**折叠只是这个求和的优化，
   写错了不会报错，只会"能出声但频率不对"。**
2. **奇数子带频谱是反的。** 分析滤波器组对奇数子带的输出在带内镜像：
   1000 Hz 会落到 subband 1 的 bin 10（应 8），解码成 1066–1077 Hz；
   8000 Hz 解码成 7847.66 Hz。修法是奇数子带把 18 条线倒序并交替变号
   （`analysis.mbt` 里有注释）。规范从解码器那头描述同一件事：`frequency inversion`。
3. **重复单线探针只能探到偶数线。** 见 `docs/line-frequencies.md`：
   恒定频谱让子带信号退化成周期 18，能量只落在 76.5625 Hz 网格上，
   所以 line 11 和 line 12 都测出 459.375 Hz。这不是解码器错，是探针退化。

### 验证证据

- `moon test --deny-warn`：22/22。新增 5 条：窗口表形状、子带选择性
  （带外/带内峰值比 < 0.1）、长块 MDCT 的 TDAC 重建（拟合增益 9.0、相对残差 < 1e-9）、
  granule 级子带集中度、量化器行为（增益 222、单位系数、半峰门限）。
- `python tools/analysis_ref.py --compare --freq 440`：与 numpy 参考的最大绝对误差
  `1.1e-16`（相对 `3.5e-16`），即双精度机器精度；1000 Hz 同样。
- `python tools/probe_lines.py --lines 0-35 --pairs`：35/35 条线落在
  `2 ceil(k/2) × 38.28125 Hz` 上，最大偏差 0.042 Hz（峰值估计不确定度 ±1.346 Hz）。
- 真实 PCM 路径（`sine` 命令 → libsndfile 解码 → 8192 点以上 FFT）：

  | 输入 | 440 | 900 | 1000 | 2000 | 3000 | 5000 | 8000 |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | 解码主频偏差 Hz | +0.23 | -0.39 | -10.16 | -1.17 | -0.39 | +28.52 | +0.78 |

  全部在一条频线（38.28125 Hz）以内。
- 幅度：`SynthesisGain = 288`（逆 MDCT 增益 9 × 子带 32 倍过采样）把解码 RMS
  校到输入的 1.00–1.05 倍，100 Hz–8 kHz 一致；峰值是输入的 1.36–1.95 倍，
  这是每线一位量化带来的过冲（Gibbs），不是增益错。
- **第一次 SNR 记录**（完成判据第 9 条，阶段 1 不要求达标）：

  ```bash
  python tools/snr.py target/ref440.wav target/dec440.mp3
  # 参考：440 Hz、峰值 0.5、39 帧的 int16 参考波形（与 `sine 39 440 50 1` 同式）
  # 解码：libsndfile / mpg123
  # alignment: delay=130 samples, trim=0
  # ch0: SNR=10.058 dB, signal_rms=0.353556, noise_rms=0.111057, corr=0.950
  ```

  10.06 dB 明显低于阶段 2 的正弦 ≥20 dB 门槛，正是"每线一位"的预期结果；
  接入 big_values 与 scalefactor 之后要重测同一条命令并对比。
- 回归门禁未退：`moon fmt --check`、`moon check --deny-warn`、
  `tools/selftest.py`（27）、`verify.py structure`（12）、`check_release.py` 全过。
  静音输入仍然解出全零，帧网格未变。

### 现在的边界

- `big_values` 恒为 0，`part2_3_length = 576 + 非零系数个数`，无 scalefactor。
- 每条频率线只有 ±1，因此宽带素材、瞬态、多音的音质都很粗：440 Hz 正弦的
  SNR 只有 10.06 dB。
- 立体声左右独立处理，未做联合立体声；预算按 `(帧位数 - 32 - 边信息) / (2 × 声道)`
  平均分配，系数过多时量化器抬高门限自保。
- 未做 bit reservoir，`main_data_begin` 恒为 0。

### 下一步

按 `docs/stage1-handoff.md` 第 4 节继续：

1. **big_values Huffman 表（0–15 号表、region0/1、linbits）**——这是把 ±1 换成真实
   幅度、让量化误差下降的必经步骤；表按计划取自 CC0 minimp3 并在 `provenance.md` 记录。
2. **scalefactor band 表 + 逐带 scalefactor + 真正的 `global_gain` 迭代**，
   替换现在"半峰硬门限"的做法。
3. 接 `snr.py` 记录一次真实 SNR，并按完成判据补齐 `multitone` / `chirp` / `impulse`
   与立体声用例。
4. 顺手项：`analysis_ref.py` 的参考实现可以加一份 IMDCT + 合成滤波器组，
   这样编码器内部就能预测重建峰值，把 `SynthesisGain` 的常数换成真正的增益搜索。

## 2026-11-02：count1 位流竖切完成

### 做了什么

- 新增 `src/mp3/count1.mbt`：count1 Huffman 表 B 写入器。
  - 每 4 个 `-1/0/1` 系数生成一个 4 位非零掩码。
  - 码字为掩码的 4 位补码（`15 - mask`）。
  - 每个非零系数追加 1 位符号位，1 表示负数。
- 新增 `src/mp3/main_data.mbt`：固定频谱测试编码器。
  - 每个 granule 都写入同一组 576 个 count1 系数；
  - `big_values = 0`、不传 scalefactor、`count1table_select = 1`；
  - `main_data_begin = 0`，每帧完全自洽；
  - 写帧前预先检查容量，越界直接拒绝。
- CLI 新增调试命令 `tone`：`tone [frames] [line] [gain] [channels]`。

这不是 PCM 编码器，也不改变 `encode()` 的现有行为；它只验证 Huffman、边信息、主数据、帧封装和独立解码器之间的完整通道。

### 验证证据

单条非零频线 `line=12`、4 帧、单声道、`global_gain=210`：

```bash
moon run cmd/main -- tone 4 12 210 1
python tools/mp3dump.py target/tone-line12.mp3 --first 1 --verbose --strict
python tools/spectrum.py target/tone-line12.mp3 --top 5
```

结果：

- `part2_3_length = 577`（576 个掩码位 + 1 个符号位）；
- 4 帧、1671 字节、128 kbps CBR、`mp3dump --strict` 无警告；
- libsndfile 解码出 4608 个样本；
- 解码峰值约 1.0065，主频 459.393 Hz。

幅度校准时将 `global_gain` 降到 206：

- 解码峰值约 0.503，RMS 约 0.333；
- 主频仍为 459.393 Hz。

频线映射探针说明：count1 输入索引并不是直接等于输出 FFT 的线性频点；它经过 Layer III 的合成滤波器组。当前实测 line 11/12 都落在约 459 Hz。这个竖切的目标是位流与帧封装正确，不是建立最终 PCM→频线映射。

### 回归保护

`tools/selftest.py` 新增两条固定频谱用例，锁定：

- 每帧每 granule 的 `part2_3_length = 577`、`big_values = 0`、`count1table_select = 1`；
- 解码长度 4608、峰值在 0.3–0.6、主频 459.375 Hz ±15 Hz。

### 下一步

从这里开始接 PCM 分析路径：先实现多相分析滤波器组，再做长块 MDCT，最后把 576 条频线接到现有 count1 路径。`tone` 命令只保留为位流调试入口，不把它当真实编码功能。
