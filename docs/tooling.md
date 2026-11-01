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

## 3. 解析 MP3 帧

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

## 4. 结构验证

```bash
python tools/verify.py structure
```

当前验证的是静音结构：CLI 产出的流被 libsndfile 解码后，必须得到 `frames * 1152` 个零样本，单/双声道和块边界都要通过。

阶段 1 增加真实音频后，保留这个命令作为回归门禁；新增音频用例另加命令，不要削弱现有检查。

## 5. SNR 测量

```bash
python tools/snr.py target/fixtures/sine440_mono_1s.wav decoded.wav
python tools/snr.py target/fixtures/sine440_mono_1s.wav decoded.mp3 --json
python tools/snr.py target/fixtures/sine440_mono_1s.wav decoded.mp3 --trim 1152
```

工作方式：

1. 读取参考和候选文件；
2. 用 FFT 互相关搜索 ±`--max-delay` 范围内的整数延迟；
3. 按最佳延迟对齐；
4. 逐声道计算 SNR、RMS、最大误差和相关系数；
5. 输出功率加权的整体 SNR。

注意：

- 正延迟表示候选信号比参考信号晚。MP3 编解码器有固定延迟，未对齐的逐样本 SNR 没有意义。
- 默认 `trim=0`。如果解码器首尾瞬态明显，可用 `--trim` 明确排除边缘样本，并在报告中写明。
- SNR 不是感知音质指标。阶段 2 的门槛是工程判据，不替代主观试听。
- 报告时应同时给出参考文件、解码器、延迟和 trim，不能只报一个数字。

## 6. 频谱检查

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

## 7. 工具自测

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
- 发布前检查器的版本同步、文件完整性和 CI 命令覆盖。

工具改动后必须先跑这个命令，再动编码器。

## 8. 发布前检查

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

## 9. 一次完整的本地检查

```bash
moon fmt --check
moon check --deny-warn
moon test --deny-warn
python tools/check_release.py
python tools/gen_fixtures.py --quiet
python tools/doctor.py
python tools/selftest.py
python tools/verify.py structure
```

CI 会执行同一组检查；`tools (python)` 作业覆盖发布预检、素材生成、环境自检、工具自测和结构验证。
