# 工具链使用说明

这些脚本只服务于开发和验证，不进入 MoonBit 包的运行时依赖。所有生成物默认写入 `target/`，不会提交。

## 环境

- MoonBit CLI：`moon` 在 PATH，或设置 `MOON` 指向可执行文件。
- Python 3.10+。
- Python 依赖：

```bash
python -m pip install -r requirements-dev.txt
```

- libsndfile 提供 MP3 解码。Python `soundfile` 的 wheel 通常已自带；系统包缺失时安装 `libsndfile1`。

## 1. 环境自检

```bash
python tools/doctor.py
```

检查 MoonBit 路径和版本、CLI 可执行性、numpy/soundfile、libsndfile 版本、MP3 解码格式与子类型、素材是否齐备。阻塞项返回 1，素材缺失只给 warning。

## 2. 生成测试素材

```bash
python tools/gen_fixtures.py
```

输出：

```text
target/fixtures/
  manifest.json
  sine440_mono_1s.wav / .pcm
  sine440_stereo_1s.wav / .pcm
  sine1k_mono_500ms...
  multitone_mono_1s...
  chirp_mono_500ms...
  noise_mono_500ms...
  silence_mono_1s...
  impulse_stereo_500ms...
  fullscale_mono_1s...
  dc_mono_500ms...
```

每个 fixture 同时提供：

- `.wav`：PCM_16，供解码器和量具使用；
- `.pcm`：交织 little-endian int16，供 MoonBit CLI 直接读取；
- manifest：采样率、声道、帧数、峰值、RMS、两个文件的 SHA-256。

素材是合成的，可重复生成；两次生成的 `manifest.json` 字节应完全一致。修改生成器时同步修改 manifest 的 `generator_version`。

常用参数：

```bash
python tools/gen_fixtures.py --list
python tools/gen_fixtures.py --out D:/moonmp3-fixtures
python tools/gen_fixtures.py --seed 42
```

## 3. CLI 命令与 PCM 输入

CLI 没有文件系统绑定：所有数据从命令行进出，MP3 用 base64 打印在 `MP3BEGIN` 之后。

```bash
moon run cmd/main -- sine 16 440 50 1          # 生成并编码 440 Hz 正弦，16 帧，50%，单声道
moon run cmd/main -- sine 16 440,660 50 2      # 左右声道分别 440 / 660 Hz
moon run cmd/main -- encode <base64 pcm> 1     # 编码外部交织 int16 PCM
moon run cmd/main -- tone 16 12,13 206 1       # 调试：固定 count1 频谱（不走分析路径）
moon run cmd/main -- lines 440 50 4 6          # 调试：打印第 6 个 granule 的 576 条频线
```

`sine` / `lines` 需要的信号在进程内生成，因此可以任意长；`encode` 的 payload 走
命令行参数，Windows 单条命令约 32k 字符，实测上限约 0.2 秒单声道。需要更长的
真实素材时，用 `sine` 或分段检查，不要试图把 1 秒 PCM 塞进命令行。

`tone` 是位流调试入口，不经过滤波器组：它在每个 granule 写入同一组系数。正因为
频谱恒定，子带信号退化成周期信号，只有 76.5625 Hz 网格上的频率可探——详见
[频线到频率的映射](line-frequencies.md)。

## 4. 频线映射探针

```bash
python tools/probe_lines.py --lines 0-35 --pairs \
    --json target/line-frequencies.json --markdown target/line-freq-table.md
```

逐条激励频线、解码、用 16384 点 FFT 定位峰值，检查实测频率是否落在
`2 ceil(k/2) × 38.28125 Hz` 的粗网格上。产物与解释见 `docs/line-frequencies.md`。
退出码非 0 表示有线的偏差超过峰值估计的不确定度，可直接当门禁用。

## 5. 分析层数值参考

```bash
python tools/analysis_ref.py --self            # 参考实现自身的解析性质
python tools/analysis_ref.py --compare --freq 440 --granule 4
python tools/analysis_ref.py --compare --freq 1000 --granule 6
```

`tools/analysis_ref.py` 用 numpy 从定义式独立重算多相滤波器组与长块 MDCT
（不复用 MoonBit 的矩阵或折叠技巧），再与 `moon run cmd/main -- lines ...` 的输出
逐线比对。当前残差在 1e-16 量级（相对误差 ~2e-16），即双精度的机器精度。

参考实现里的五件事都与 `analysis.mbt` 一一对应，缺一条就会被 `--compare` 抓出来：

1. 分析矩阵 `cos((2m+1)(k−16)π/64)`（不是 `(16+k)` 那个合成侧形式）；
2. 分析窗 `C = D/32`（`window.mbt` 里存的是合成窗 `D`，峰值 1.144989014）；
3. 奇数子带在奇数步乘 `(−1)^n`（Layer III 方向）；
4. 频线除以 `SynthesisGain = 9`；
5. 频线上的 `antialias` 预补偿（解码器 Table B.9 那八对 Givens 的转置）。

## 6. 窗口表来源校验

```bash
python tools/window_table.py --check     # 逐项比对 src/mp3/window.mbt 与上游 blob
python tools/window_table.py --fetch     # 重新拉取并缓存上游文件（需要网络）
python tools/window_table.py --write     # 重新生成 src/mp3/window.mbt
```

上游文件固定在 `hajimehoshi/go-mp3` 的 blob `3532e6c5…`，整文件 SHA-256 与 512 系数表
的 SHA-256 都记录在 `docs/provenance.md`。缓存落在 `target/ref/`，不提交。

## 7. 双解码器交叉验证

```bash
python tools/crossdecode.py target/sine440.mp3
python tools/crossdecode.py target/sine440.mp3 --json
```

同一条流分别用 libsndfile（mpg123）和 PyAV（ffmpeg）解码，逐声道比较相关度、差异电平
和主频。两个解码器共享零代码，所以"一致"是对流本身的证据，不是某一个库的宽容度。
`requirements-dev.txt` 里的 `av` 就是这个作用；它只是开发期 oracle，不进 MoonBit 包。

## 8. 解码器模型与闭合环

```bash
python tools/decoder_ref.py --verify          # 与 libsndfile 对齐（当前 127.5 dB）
python tools/decoder_ref.py --score           # 用闭环给分析层打分
python tools/decoder_ref.py --score --freq 685
```

`decoder_ref.py` 逐步复现参考解码器：`antialias`（作用在量化后的频线上，八对 Givens 系数）
→ IMDCT + overlap-add（频线 → 子带样本）→ `frequencyInversion`（奇数带奇数时间点取负）
→ 余弦矩阵 + 两项 U 构造 + 512 点合成窗。用 count1 单线流与 libsndfile 比对，
吻合 **127.5 dB**（int16 打印上限），所以这个模型**就是**解码器。

`--score` 把候选分析层接上这个解码器、**中间不做任何量化**，测闭环 SNR。这解决了一个
一直缺的东西：判断"折叠对不对"不再靠肉眼或端到端 SNR 猜。`--score` 打的是
`analysis_model()`，即当前检入 `analysis.mbt` 的那一套：

```text
白噪声  84.44 dB     685 Hz  96.66 dB    440 Hz 96.86 dB
1000 Hz 97.45 dB     1390 Hz 97.06 dB    3000 Hz 96.71 dB
8000 Hz 97.85 dB     延迟 1057   拟合增益 1.00000
```

（对比：修复前的分析层白噪声 1.02 dB、685 Hz 0.07 dB。）延迟 1057 = 滤波器组 481 +
半块重叠 576。整套系统在**无量化**时就是解码器的逆，剩下的端到端差距全部来自量化。

## 9. Huffman 表来源校验

```bash
python tools/huffman_tables.py --report   # 校验并汇总 15 张 big_values 表
python tools/huffman_tables.py --write    # 重新生成 src/mp3/huffman_tables.mbt
python tools/huffman_tables.py --fetch    # 重新拉取上游（需要网络）
```

上游文件固定在 `hajimehoshi/go-mp3` 的 blob `abc30058…`。脚本从解码侧二叉树展开出
编码侧 `(x,y) -> (码长, 码字)`，并在写出前校验 Kraft 和、码字冲突与表尺寸；展开结果
的 SHA-256 与实测的每张表 extent/最大码长都记录在 `docs/provenance.md`。

## 10. 奇数子带方向（历史工具，已移除）

`tools/odd_band.py` 曾把 11 个候选线域映射逐个写进 `analysis.mbt` 的 `odd_band_value`，
重编、解码、打分。它的结论（纯倒序 +16 dB，其余更差）在当时是对的，但整条路线是错的：
带内倒序对单音有效、对宽带无论如何都救不回来。矩阵改成 `cos((2m+1)(k−16)π/64)` 之后，
奇数子带的方向由滤波器组出口的 `(−1)^n` 决定（`AnalysisFilterbank::step`），
`odd_band_value` 已删除，这个脚本也随之删除（历史见 git）。

## 11. 解析 MP3 帧

```bash
python tools/mp3dump.py target/ours-silent.mp3 --first 2 --verbose
python tools/mp3dump.py target/ours-silent.mp3 --json
python tools/mp3dump.py target/ours-silent.mp3 --strict
```

用途：

- 核对帧头、padding、帧大小、`main_data_begin`；
- 核对边信息中的 `part2_3_length`、`big_values`、`global_gain`、`table_select`；
- 发现 Xing/Info 标签；
- JSON 输出用于自动化比较，`--strict` 遇到任何结构 warning 返回 2。

阶段 1 调试时，优先让 `--strict` 零 warning，再判断声音是否正确。

## 12. 结构验证

```bash
python tools/verify.py structure
```

当前验证的是静音结构：CLI 产出的流被 libsndfile 解码后，必须得到 `frames * 1152` 个零样本，单/双声道和块边界都要通过。

阶段 1 增加真实音频后，保留这个命令作为回归门禁；新增音频用例另加命令，不要削弱现有检查。

## 13. SNR 测量

```bash
python tools/snr.py target/fixtures/sine440_mono_1s.wav decoded.wav
python tools/snr.py target/fixtures/sine440_mono_1s.wav decoded.mp3 --json
python tools/snr.py target/fixtures/sine440_mono_1s.wav decoded.mp3 --trim 1152
python tools/snr.py target/fixtures/sine440_mono_1s.wav decoded.mp3 --delay 1057
```

工作方式：

1. 读取参考和候选文件；
2. 用 FFT 互相关搜索 ±`--max-delay` 范围内的整数延迟（给了 `--delay` 就直接用它）；
3. 按最佳延迟对齐；
4. 逐声道计算 SNR、RMS、最大误差和相关系数；
5. 输出功率加权的整体 SNR。

注意：

- 正延迟表示候选信号比参考信号晚。MP3 编解码器有固定延迟，未对齐的逐样本 SNR 没有意义。
- **测本编码器的流一律给 `--delay 1057`**：这是本仓库自己测出来的常数（滤波器组 481 +
  半块重叠 576）。周期性探针（单音）的自相关旁瓣和主峰一样高，互相关搜索会锁到邻近周期，
  把对齐误差当成编码噪声——440 Hz 上同一个流，相关搜索报 16.2 dB，固定延迟报 22.1 dB。
- 默认 `trim=0`。如果解码器首尾瞬态明显，可用 `--trim` 明确排除边缘样本，并在报告中写明。
- SNR 不是感知音质指标。阶段 2 的门槛是工程判据，不替代主观试听。
- 报告时应同时给出参考文件、解码器、延迟和 trim，不能只报一个数字。

## 14. 频谱检查

```bash
python tools/spectrum.py target/fixtures/sine440_mono_1s.wav
python tools/spectrum.py decoded.mp3 --channel 1 --top 5
python tools/spectrum.py decoded.mp3 --json
```

对 `channel` 的采样做半重叠 Hann 窗平均周期图，找局部极大值并用对数幅度抛物线插值频率。阶段 1 用它确认：

- 440 Hz 输入的主峰仍在 440 Hz 附近；
- 立体声左右声道没有交换；
- 多音素材的三个分量都在；
- 静音输出没有虚假峰。

4096 点 FFT 的频率分辨率约 10.8 Hz，插值后正弦峰值误差通常在 ±1 Hz 内。频谱不是音质评分，仍以 SNR 和试听为补充。

## 15. 工具自测

```bash
python tools/selftest.py
```

覆盖：

- 10 个 fixture 的生成与确定性；
- WAV 与裸 PCM 逐样本一致；
- 静音流的单/双声道帧网格；
- JSON 可序列化、损坏流告警、严格模式退出码；
- SNR 的零延迟、123 样本延迟、有限噪声 SNR 和声道不匹配错误；
- 频谱的 440/660 Hz 定位、多音峰值和静音无峰；
- 分析层与 numpy 参考逐线一致，以及参考实现自身的解析性质；
- 真实正弦编码后主频落在输入频率一行之内、立体声不串、`global_gain` 与 `part2_3_length` 在合法范围；
- 发布前检查器的版本同步、文件完整性和 CI 命令覆盖。

工具改动后必须先跑这个命令，再动编码器。

## 16. 发布前检查

```bash
python tools/check_release.py
python tools/check_release.py --json
```

检查：

- `moon.mod`、`lib.mbt`、`CHANGELOG.md` 三处版本一致；
- CHANGELOG 最新日期合法；
- 必需文件齐全；
- 许可证字段是 OSI 许可证；
- CI 仍包含格式、检查、测试、native/wasm-gc 构建和 Python 工具作业；
- README 没有写死版本号（warning，不阻塞）。

它不替代构建和测试，只负责抓住“版本号漏改一处”这类发布事故。

## 17. 一次完整的本地检查

```bash
moon fmt --check
moon check --deny-warn
moon test --deny-warn
python tools/check_release.py
python tools/gen_fixtures.py --quiet
python tools/doctor.py
python tools/window_table.py --check
python tools/analysis_ref.py --self
python tools/analysis_ref.py --compare --freq 440
python tools/selftest.py
python tools/verify.py structure
```

CI 会执行同一组检查；`tools (python)` 作业覆盖发布预检、素材生成、环境自检、工具自测和结构验证。
