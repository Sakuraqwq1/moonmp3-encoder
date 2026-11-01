# 测试素材与预期现象

素材由 `tools/gen_fixtures.py` 生成，全部是合成信号，不含第三方录音。默认位置 `target/fixtures/`，不提交。

## 素材表

| 名称 | 时长 | 声道 | 内容 | 预期现象 |
| --- | --- | --- | --- | --- |
| `sine440_mono_1s` | 1.0 s | 1 | 440 Hz，峰值 0.5 | 主峰 440 Hz |
| `sine440_stereo_1s` | 1.0 s | 2 | 左 440 Hz / 右 660 Hz，峰值 0.5 | 左 440 Hz，右 660 Hz，不串音 |
| `sine1k_mono_500ms` | 0.5 s | 1 | 1 kHz，峰值 0.25 | 主峰 1 kHz |
| `multitone_mono_1s` | 1.0 s | 1 | 440/880/1320 Hz，峰值 0.6 | 三个峰，幅度约 0 / -6 / -12 dB |
| `chirp_mono_500ms` | 0.5 s | 1 | 100 Hz → 8 kHz 线性扫频 | 频谱连续，覆盖低频到高频 |
| `noise_mono_500ms` | 0.5 s | 1 | 均匀白噪声，固定 seed | 宽带，无明显单峰 |
| `silence_mono_1s` | 1.0 s | 1 | 全零 | 解码全零，频谱无峰 |
| `impulse_stereo_500ms` | 0.5 s | 2 | 250 ms 处左右相反极性的单样本 | 宽带瞬态；用于检查预回声/量化边界 |
| `fullscale_mono_1s` | 1.0 s | 1 | 440 Hz，峰值 0.99 | 主峰 440 Hz；检查满幅不崩 |
| `dc_mono_500ms` | 0.5 s | 1 | 常数 +0.1 | 边界输入；编码器不应崩溃 |

## 文件格式

每个素材有两份等价数据：

- `.wav`：PCM_16 WAV，供 libsndfile、频谱和 SNR 工具使用。
- `.pcm`：交织 little-endian int16，供 MoonBit CLI 直接读取。
- `manifest.json`：采样率、声道、帧数、峰值、RMS、两个文件的 SHA-256。

WAV 与 PCM 由同一份 int16 主数据写出，逐样本一致；`tools/selftest.py` 会校验这一点。

## 快速检查

```bash
python tools/gen_fixtures.py --quiet

# 主频应在 440 Hz 附近（4096 点 FFT 的容差约 ±1 Hz）
python tools/spectrum.py target/fixtures/sine440_mono_1s.wav

# 右声道应为 660 Hz
python tools/spectrum.py target/fixtures/sine440_stereo_1s.wav --channel 1

# 三个音调
python tools/spectrum.py target/fixtures/multitone_mono_1s.wav --top 3

# 静音应输出 no spectral peak
python tools/spectrum.py target/fixtures/silence_mono_1s.wav
```

## 使用约定

- 报告中写清楚 fixture 名称、seed 和 manifest 的 SHA-256，避免“我这边能复现”的口头结论。
- 修改 fixture 生成逻辑后，更新 manifest 的 `generator_version` 并重跑 `tools/selftest.py`。
- 不用真实音乐作为唯一测试素材：版权和版本不可控，合成 fixture 才能稳定回归。
