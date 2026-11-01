# 阶段 0 笔记：MP3 帧布局（对照 LAME 参考文件实测）

日期：2026-11-01
工具：`tools/mp3dump.py`（帧级解析器，已能完整解析 LAME 输出与本编码器输出）
参考文件：`target/lame-ref-128.mp3`（libsndfile/LAME 写出，1 秒 440 Hz 立体声正弦）

## 1. 帧头（4 字节，全部大端，MSB-first）

```
sync(11)=0x7FF | version(2)=11(MPEG1) | layer(2)=01(LayerIII) | protection(1)
| bitrate_idx(4) | samplerate_idx(2) | padding(1) | private(1)
| mode(2) | mode_ext(2) | copyright(1) | original(1) | emphasis(2)
```

- 128 kbps / 44100 Hz / 无 CRC / 立体声：`FF FB 90 00`（padding=1 时 `FF FB 92 00`）
- 单声道（mode=11）：第四字节为 `C0`
- protection=1 表示帧头后**没有** 16-bit CRC；LAME 默认也无 CRC

## 2. 帧长与 padding（128 kbps / 44.1 kHz）

`size = floor(144 * bitrate / samplerate) + padding` → 417 或 418 字节。

实测 LAME 与本编码器的共同规律：**padding 必须按累积误差计算**，使 n 帧后的总字节数
恒等于 `floor(n * 144 * 128000 / 44100)`。在 128k/44.1k 下 49 帧恰为 20480 字节，
即每 49 帧中有 47 帧带 padding。本编码器 `FrameSizer` 直接由累计总量推导每帧尺寸，
首帧 417、其后以 418 为主，已通过 200 帧不变量测试。

## 3. 边信息（side information）

- 位置：帧头之后（无 CRC 时偏移 4），主数据之前
- 长度：**单声道 17 字节（136 bit），立体声 32 字节（256 bit）**
- 布局（MPEG-1）：
  ```
  main_data_begin(9) | private(5 单声道 / 3 其他) | scfsi(4 × 声道数)
  然后 每 granule × 每声道：
    part2_3_length(12) big_values(9) global_gain(8) scalefac_compress(4)
    window_switching_flag(1)
    若 wsf=0：table_select×3(各5) region0_count(4) region1_count(3)
    若 wsf=1：block_type(2) mixed_block_flag(1) table_select0/2(各5) subblock_gain×3(各3)
    preflag(1) scalefac_scale(1) count1table_select(1)
  ```
- 每个 granule-channel 恰为 59 bit；2 granules × 声道数 + 头部正好凑成整字节
- `table_select` 是**三张表**（region0/1/2 各一），初学者容易漏算一张导致总位数对不上

## 4. Xing/Info 帧（LAME 实测）

- LAME 输出的 **frame 0 是 Xing 帧**：`main_data_begin=0`、全部 granule 为零、
  在边信息之后的主数据区以 ASCII `Xing`（CBR 时为 `Info`）开头，后随 4 字节 flags
  （实测 `flags=0xf`：frames/bytes/TOC/quality 全有）
- Xing 帧不占音频内容；编码器延迟（LAME 为 576+528+1=1105 样本）通过 Xing/LAME tag 告知
- **本项目 v1 不写 Xing**：后果是输出比源多 `nframes*1152 - N` 个尾部样本，
  验证时以帧数对齐长度，不声称 gapless

## 5. LAME 行为观察（VBR 文件）

- 默认 mode=joint stereo；本编码器 v1 用普通 stereo（mode=00），合法且更保守
- 瞬态帧 wsf=1（block_type 短块），稳态帧 wsf=0 —— 印证"v1 只做长块"的简化边界
- bit reservoir：frame 2 起 `main_data_begin` 为数百字节（回溯到前面帧的主数据区），
  frame 0/1 为 0。**reservoir 写错不会报错，只会出噪音**——阶段 2 的主战场

## 6. oracle 限制（实测踩到）

- **libsndfile/mpg123 打不开只有一帧的 MP3**：`Cannot read next header, a one-frame
  stream?`——解码侧验证从 ≥2 帧开始；单帧结构用 mp3dump 检查
- libsndfile 的 `bitrate_mode="CBR"` 默认输出并非恒定 128 kbps（实测帧码率在
  32–224 kbps 间变化）；要 128k CBR 参考需另找途径（ffmpeg 或指定压缩级别），
  阶段 3 的体积对照届时处理

## 7. 当前状态

- `tools/mp3dump.py` 可完整解析 LAME 参考文件（帧头、边信息、Xing、帧网格汇总）
- 本编码器静音骨架已被独立解码器验证：`verify.py structure` 12 例全过
  （≥2 帧、单/双声道、块边界 ±1、1 秒），解码长度精确、样本全零
