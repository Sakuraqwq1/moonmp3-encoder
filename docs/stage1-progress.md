# 阶段 1 进度记录

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
