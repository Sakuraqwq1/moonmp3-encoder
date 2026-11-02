# 阶段 2 进度记录

## 2026-11-03：阶段 2 收尾 —— 连续防削顶 Headroom、LAME 对齐复现与文档实测校准

### 1. 满幅 Headroom 做成连续规则（彻底消除过冲）

- **问题定位**：原规则 `normalised < 0.95: 1.0 else 0.89 / normalised` 在 0.85–0.95 区间完全缺乏保护，且 0.89 过于贴近过冲倍数（1.12–1.15），导致实测 93 % 处解码峰值达 1.0367、95 % 处达 1.0211。
- **连续规则改造**：改为 `h = if normalised <= 0.87 { 1.0 } else { 0.87 / normalised }`，保持整段常量。
- **扫描验证**（`target/peak_scan.py`，50 % 到 100 % 步进 1 % 共 51 个输入电平）：
  - 所有电平解码峰值均 **≤ 1.00**（全段最大峰值 0.9978 @ 90 %，100 % 处 0.9919）；
  - 普通素材（≤ 87 %）位流逐字节不变；
  - 满幅（100 %）电平衰减 1.21 dB，严格满足损失 ≤ 1.3 dB 断言要求（防止压峰值过度压低音量）。
  - `tools/selftest.py` 满幅门禁由 ≤ 1.05 收紧至 ≤ 1.00，并新增 100 % 损失 ≤ 1.3 dB 自动断言。
  - 普通素材 SNR 不回归：440 Hz 29.32 dB，`tools/sweep_snr.py` 最差仍为 27.60 dB（4000 Hz）。

### 2. LAME 128k 可复现对照工具（`tools/lame_ref.py`）

新增标准对照工具，使用 PyAV 的 `libmp3lame` 进行黑盒 mono CBR 128 kbps 编码，使用 libsndfile 解码并由有符号互相关消除半周期误锁；本编码器固定已知延迟 1057。支持 `--json` 输出。

实测同码率对比（0.18 s 片段，libsndfile 解码）：

| 探针 | 本编码器 (128k) | LAME 128k | 差异 | 说明 |
| --- | ---: | ---: | ---: | --- |
| 440 Hz 正弦 | 28.30 dB | 26.03 dB | +2.27 dB | 优于 LAME |
| multitone | 27.77 dB | 26.01 dB | +1.76 dB | 优于 LAME |
| 扫频 (100–8000 Hz) | 28.34 dB | 26.00 dB | +2.34 dB | 优于 LAME |
| 白噪声 | 13.51 dB | 8.49 dB | +5.02 dB | 优于 LAME |
| 满幅 99 % 正弦 | 17.92 dB | 26.02 dB | -8.10 dB | 防削顶余量（归一化后 28.92 dB 高于 LAME） |

### 3. 短块 Scalefactor 细化探针（P2 规则评估）

对短块 36 个 scalefactor 进行逐带细化探针测试：在脉冲与突变瞬态信号上测试，实测端到端 SNR 增益 < 0.3 dB（短块主因是时间分辨率提升压制预回声，量化误差收益有限）。按照验收规则（收益 < 0.3 dB 不合入），短块保持全零 scalefactor 路径，避免引入额外复杂度与位开销风险。

### 4. 文档口径校准

README、CHANGELOG 与 `docs/acceptance.md` 同步修正：
- 撤回“五个探针都不差”的旧表述，如实披露满幅探针因 1.2 dB 防削顶 reserve 电平略低（原始 SNR 17.9 dB vs 26.0 dB，归一化后 28.92 dB 高于 LAME）；
- 更新验收证据行至当前真实基线（440 Hz 29.40 dB，全频段最差 27.60 dB）。

## 2026-11-03：分配器误差指标漏了符号 —— 修好，端到端 +5 dB

### 症状与定位

阶段 1 收口时的数字：440 Hz 端到端 **21.95 dB**，而同一探针下 LAME 128 kbps mono 是
**26.03 dB**。先用离线实验把"分析 → 量化 → 已认证解码器"整条链在 Python 里重放：

| 量化方式（同一批频线） | 时间域 SNR |
| --- | ---: |
| 编码器当时实际写出的增益 | 22.00 dB |
| 每个 granule 只用"峰值→15"的中心增益 | **25.50 dB** |

也就是说损失不在量化器公式，而在**选哪个增益**。为此给 CLI 加了 `alloc` 调试命令
（`moon run cmd/main -- alloc 440 50 5`），直接打印每个候选增益的精确 Huffman 代价和
重建误差。第一条输出就暴露了问题：

```text
granule=5 peak=0.3068 centre=182 budget=1588 energy=0.1649
  gain=182 cost=617 big=8 nonzero=13 error=0.5 -> snr=-4.8 dB
```

**误差比信号能量还大**。原因是 `GranuleQuantiser::error` 重建时用了
`dequant_levels[|is|] * amplitude`，把 `is` 的符号丢了。对正负交替的 granule，每个
负系数都被"当成正的"算了一遍，误差在所有增益上都超过信号能量，于是误差排序变成噪声，
分配器只能按位预算的边界随手挑增益——实测它给一个稳态单音写出了 179/186/190/189/191/
187… 这种相差 13 档的增益，比"峰值对齐"粗 3–7 档。

### 修法

`error()` 里把符号还原：`reconstructed = if is < 0 { -magnitude } else { magnitude }`。
修完同一个 granule 的候选表立刻变成有意义的形状：

```text
gain 180..190: 11.9 15.9 25.1 24.5 24.8 23.2 22.3 21.8 25.7 20.0 17.7 dB
```

（非单调是对的：增益改变时 4/3 幂律的量化格点与系数的相对位置会跳。）

新增回归测试 `quantiser : the error metric puts the sign back on the reconstruction`：
36 条正负交替的线，误差必须小于能量的 1 %。符号丢掉时这条会得到 4 倍能量的误差。

### 效果

| 判据 | 修复前 | 修复后 |
| --- | ---: | ---: |
| `sweep_snr.py` 全段最差 | 21.83 dB（4000 Hz） | **26.79 dB**（560 Hz） |
| 440 Hz | 21.95 dB | **27.89 dB** |
| 685 Hz | 23.04 dB | **30.39 dB** |
| 8000 Hz | 25.77 dB | **32.33 dB** |
| multitone（0.18 s 片段） | 22.12 dB | **26.06 dB** |
| 满幅 99 % | 21.69 dB | **27.42 dB** |

同码率对比（PyAV `libmp3lame`，128 kbps mono CBR，与我们的 CLI 编同一个 0.18 s 片段，
两者都用 libsndfile 解码、无增益拟合、在已知延迟上对齐）：

| 探针 | 本编码器 | LAME 128k |
| --- | ---: | ---: |
| 440 Hz 正弦 | **27.61 dB** | 26.03 dB |
| multitone 440/880/1320 | **26.06 dB** | 26.01 dB |
| 扫频 100–8000 Hz | **26.81 dB** | 26.00 dB |
| 白噪声 | **12.74 dB** | 8.49 dB |
| 满幅 99 % 正弦 | **27.42 dB** | 26.02 dB |

LAME 在每个探针上的误差几乎都集中在"幅度偏小 5 %"（拟合增益 0.950），其余是干净的；
我们的误差则来自量化格点本身。

## 2026-11-03：位保留区（bit reservoir）接通

`main_data_begin` 不再是常数 0。主数据现在是**一条连续的比特流**，帧只是把这条流切
成 `size - 4 - side_info` 长的段，`main_data_begin` 指出本帧数据从自己这一段往前多少
字节开始——最多 511 字节，正好是解码器保留的窗口。这样一帧可以借用前面帧没用完的字节，
瞬时（或噪声这类稠密信号）不再被"每 granule 1588 bit"卡死。

实现要点（`src/mp3/reservoir.mbt` + `src/mp3/encode.mbt`）：

- 新增 `MainDataReservoir`：可增长的 MSB-first 比特缓冲，提供 `append`（把一帧的
  granule 比特接上）、`pad`（丢掉超出 511 的滞后）、`take`（把一段有效载荷交给一帧）。
- `encode()` 改成**两遍**：第一遍分析+量化+拼接，确定每帧数据在流里的起点；第二遍按
  帧尺寸切段发出。之所以必须两遍：一帧的数据可能落在**更早**发出的段里（滞后最多 511
  字节 ≈ 1.2 个帧），所以流必须整条写好再切。
- 预算变成"解码器这一帧能看到的全部"：`(min(lag,511) + capacity)` bit，两个 granule
  平分。写不满的 granule 自然把余量留给后面的帧。

踩到的坑（记下来省下一次）：`area_start` 一开始按"帧尺寸"累加，而流的坐标系只数主数据
字节——帧头和边信息不在里面。每帧差 21 字节，第 25 帧滞后算成负数，直接报
`analysis failed in frame 25`。改成累加 capacity 之后正常。

验证（39 帧 440 Hz 单声道，`target/resv.mp3`）：

```text
mdb 逐帧: 0, 232, 477, 511, 511, ...      全在 0..511
libsndfile 解码 44928 样本，SNR 27.93 dB（与接保留区前的 27.89 一致）
crossdecode: mpg123 vs ffmpeg 相关度 1.000000、差 125.7 dB、主频 441.4 Hz
sweep 最差仍 26.79 dB；moon test 30；selftest 32；verify structure 12
```

稳态单音的 SNR 不变是对的：它用不满预算，保留区的价值在"某帧需要更多比特"的时候，
而阶段 2 剩下的 scalefactor/短块才是真正会用上它的地方。

### 下一步（按收益排）

1. **scalefactor band**（21 带，Table B.8 + `scalefac_compress` 的 slen1/slen2）。
   离线实验（`probe_sf` 思路，未约束逐带最优）：只在 440 Hz 上 +2.3 dB，边界频率 ~0，
   且把每 granule 非零系数从 13 推到 71。所以它必须**带位预算**做，否则是纯亏；
   真正的空间在带间噪声分配（白噪声 12.7 dB 是现在唯一的弱项）。
2. **满幅过冲**：输入 0.99 → 解码峰值 1.12，SNR 虽 27.4 dB 但峰值超过 1.0，需要策略。
3. **短块 / 窗切换**：瞬态预回声。

## 2026-11-03：阶段 2 收口 —— scalefactor、满幅 headroom、短块/窗切换

### scalefactor band（21 带 + `scalefac_compress`）

新增 `src/mp3/scalefactor.mbt`：44.1 kHz 长块频带表（Table B.8.b，22 个分区，
前 21 个带 scalefactor，第 22 个是 158 线的无 scalefactor 尾巴）、`scalefac_compress`
→ `(slen1, slen2)` 的 16 项标准表、以及按组最大值选择最省位 `compress` 的定价。

分配策略是两段式：先按零 scalefactor 做一维 `global_gain` 搜索（沿用上一版），再用
贪心 knapsack 把剩余位预算花在"误差下降 / 位增量"最大的带上。每个候选增量都做一次
精确的整 granule 重新定价，装不下就永久封掉那个带。

踩到的两个坑（都长在可表示范围上，记下来省一次）：

- **slen 是位宽不是数值上限**。第一版把 `slen1 < max1` 当成"放得下"，实际一个
  `slen` 位的字段只能装 `0..2^slen-1`。slen2 顶到 3 位，所以 sfb 11..20 的 scalefactor
  上限是 7 而不是 15；写入 8..15 会让 `scalefactor_compress` 返回 -1、位流里不写任何
  scalefactor，而模型还以为写了——整段 SNR 直接掉 12 dB。
- **短块 sfb12 尾巴映射越界**。短块频线排序里 sfb12 是 168 线的无 scalefactor 尾巴，
  第一版按 `3*sfb + (line-start)/width` 算字段号，宽度 56 导致返回 36/37/38 越界，
  `error_scaled_short` 里 `Array::at` 直接 panic。改成整个尾巴统一映射到哨兵 36。

效果（libsndfile 解码、延迟 1057 对齐）：

| 判据 | 接入前 | 接入后 |
| --- | ---: | ---: |
| `sweep_snr.py` 全段最差 | 26.79 dB（560 Hz） | **27.60 dB**（4000 Hz） |
| 440 Hz | 27.89 dB | **29.32 dB** |
| 685 Hz（带边界） | 30.39 dB | **31.36 dB** |
| 8000 Hz | 32.33 dB | **32.44 dB** |
| multitone（正确幅度 0.6） | 26.06 dB | **28.68 dB** |

白噪声稳定在 13.5 dB，与 LAME 128k 的 8.49 dB 相比仍有优势——它花光预算在
`global_gain` 上，逐带 scalefactor 没有 headroom 可用；这是 128 kbps 单声道的固有
边界，不是结构缺陷。

### 满幅 headroom

`encode_headroom()` 对整段输入算一次峰值，归一化峰值 ≥0.95 时把整段统一乘以
`0.89 / peak`，让 99 % 和 100 % 都落在同一个 0.89 的预留峰值上。整段常量不逐帧切换，
避免幅值调制和立体声平衡漂移。实测：

| 输入 | 修复前峰值 | 修复后峰值 | 修复后 SNR |
| --- | ---: | ---: | ---: |
| 99 % 正弦 | 1.07 | **0.999** | 19.5 dB |
| 100 % 正弦 | 1.07 | **0.999** | 18.9 dB |

50 % 及以下的普通素材位流逐字节不变。SNR 下降是因为参考仍是 0.99 信号、衰减被计入
误差；若允许增益拟合，量化噪声 SNR 仍在 28 dB 量级。新增 selftest 门禁：满幅解码
峰值 ≤1.05。

### 短块 / 窗切换

`src/mp3/analysis.mbt` 增加 12 点短 MDCT、start/stop 窗、`granule_block(pcm, block_type)`
（短块跳过 antialias 预补偿、除以 `N/4=3`，长/start/stop 除以 9），以及短块频线从
`[subband][window][line]` 到 `[sfb][window][line]` 的 Huffman 顺序重排。
`src/mp3/scalefactor.mbt` 增加 12 短带表与 36 个短 scalefactor 的写入/定价。
`encode()` 用 `schedule_block_types` 做瞬态检测：某 granule 的 RMS 超过运行均值 3 倍
即标为短块，前后各补 start/stop。`sideinfo.mbt` 修正了 block_type 注释（2 是短块、3 是
stop，之前写反了）。

TDAC 用 `[long, start, short, short, stop, long]` 序列验证到机器精度；孤立脉冲端到端
触发 1 个 start + 1 个 short + 1 个 stop，双解码器（mpg123 vs ffmpeg）相关度 1.000000、
差 116 dB，解码峰值精确落在 1057+4000 对齐位置，预回声 RMS 约 0.0011（相对峰值约
−58 dB）。

### 收口证据

```text
moon check --deny-warn  通过
moon fmt --check        通过
moon test               42/42（新增窗口互补、TDAC、短块频线双射、短 scalefactor 定价）
tools/selftest.py       34/34（新增近满幅不过冲、瞬态触发短块）
tools/verify.py structure 12/12
tools/crossdecode.py     短块流与立体声流相关度 1.000000
```

阶段 2 的三项（scalefactor、满幅过冲、短块/窗切换）至此全部落地。剩余的可选项是
短块 36 个 scalefactor 的逐带分配（当前短块用全零 scalefactor，已正确解码），以及
发布 0.2.0 的收口动作。
