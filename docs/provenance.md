# 实现来源与许可证记录

本文件用于验收时的开源合规审查。原则：规范可以读，LGPL 实现不能读、不能移植；任何数据表都要有明确来源和许可证。

## 本仓库代码

- 原创实现，许可证 Apache-2.0，见根目录 `LICENSE`。
- 帧头、边信息、CBR 帧尺寸器、BitWriter、count1 表 A 写入器（含全零尾部的 1-bit 终止码）均按 ISO/IEC 11172-3 的位流定义独立实现。
- 分析滤波器组、长块 MDCT、量化器均按 ISO/IEC 11172-3 的公式独立实现（`src/mp3/analysis.mbt`、`src/mp3/quantize.mbt`）。
- **许可边界声明**：全部实现只依据 ISO/IEC 11172-3 公开规范文本与下表中的公开数值表。全过程**未查阅、未复制、未移植** LAME（LGPL）、shine（LGPL）、mpg123（LGPL）与 libavcodec/ffmpeg（LGPL/GPL）的源代码；mpg123 与 ffmpeg 仅以**编译好的解码器**身份在 Python 验证阶段充当 oracle（`libsndfile`/`PyAV` 调用），其源码不进入本仓库、不参与构建、不分发。仓库内不存在任何 LGPL/GPL 派生代码。
- count1 四元表（Table A / Table B）的核对数据来自 minimp3 `tab33`（CC0-1.0）：仓库 `lieff/minimp3`，blob `9fbd4d2cc50c06cc3e63dcafdd506dc6512b2103`，SHA-256 `57e437c5c1f0e8b243885d3929c8973b5e6c778451e0100ab4251d19915cb3ad`。只使用其公开码表数据核对，未复制代码。
- count1 **Table A**（编码器实际输出，`src/mp3/count1_tables.mbt`）取自 `hajimehoshi/go-mp3`（Apache-2.0）`internal/huffman/huffman.go` 的解码表 32：blob `abc30058a5cb0e8a75ea40aed2aa88dd02f2c96e`，整文件 SHA-256 `6ffbac45b10aabb6cd1a5e37736743ec84ddb8c145fbdd22b2638f1a66cb6b1d`。`tools/huffman_tables.py` 用与 big_values 表相同的文档化遍历规则把解码侧二叉树展开成编码侧 `(mask) -> (码长, 码字)`，并校验 16 个符号的完备前缀性、码字无冲突与 Kraft 和恰为 1（`1/2 + 4/16 + 5/32 + 6/64 = 1.0`）；`moon test` 的白盒用例对数组本身重复这三项校验。符号 0 的码字是规范规定的单位码 `1`，即全零尾部的终止码，这是 Table A 的规范属性而非本项目自创。
- 分析窗 512 系数（`src/mp3/window.mbt`）取自 `hajimehoshi/go-mp3`（Apache-2.0）：仓库 `hajimehoshi/go-mp3`，路径 `internal/frame/frame.go`，变量 `synthDtbl`，git blob `3532e6c549b5dcc6409d3a2c8b8e16b67b0369b5`，整文件 SHA-256 `e0b901f2291c89ff44fa904299eaf23e9141f0a8d54fe0f04f55189c3e0bdf1d`，512 系数表的 SHA-256 `386658ca6803d2364797ef160ff4a33951f4ab986cebc8860a1fdbc1cc66933f`。该表是 ISO/IEC 11172-3 Annex B 的规范数据（不是可推导的公式），因此照抄数值而非法计算；选择该来源的理由是它按规范下标 0..511 顺序完整列出、许可证与本模块兼容，而多数解码器只存一个重排过的压缩子表。只使用数值，滤波器组结构按规范描述独立实现，未复制其代码。`tools/window_table.py` 可复现并逐项校验这张表。
- big_values Huffman 表（`src/mp3/huffman_tables.mbt`）取自同一仓库的 `internal/huffman/huffman.go`（Apache-2.0）：blob `abc30058a5cb0e8a75ea40aed2aa88dd02f2c96e`，整文件 SHA-256 `6ffbac45b10aabb6cd1a5e37736743ec84ddb8c145fbdd22b2638f1a66cb6b1d`，展开后的 15 张表 SHA-256 `c531992c6bbf83d4d5ade857a4121d71ca243eddc38e8f2a18f96dacdd6ada4d`（含两 张 count1 四元表，共 4994 个符号）。上游存的是解码侧压缩二叉树，`tools/huffman_tables.py` 用文档化的遍历规则把它确定性地展开成编码侧的 `(x, y) -> (码长, 码字)`，并在写出前校验：每表 Kraft 和 = 1、无码字冲突、表尺寸是 2/3/4/6/8/16 方阵。只使用表数据，编码写入逻辑按位流定义独立实现，未复制其解码代码。
- **MPEG-1 表的 linbits 全为 0** 这一事实用两处独立来源交叉核对：go-mp3 的 `huffmanMain`（0–15 号表）与 minimp3（CC0-1.0）的 `g_linbits` 前 16 项都为 0，其中 1/2/3/4/6/8/10/13 属于 MPEG-2 的 16–23 号表。结论直接影响实现：MPEG-1 量化系数上限是 15，`MaxQuantLevel` 就是这个约束。
- 解码器 `antialias` 的八对 Givens 系数是 ISO/IEC 11172-3 Table B.9 的规范数值（8 个余弦 + 8 个正弦），按标准数值抄录：`tools/decoder_ref.py` 的 `CS`/`CA` 与 `src/mp3/analysis.mbt` 的 `antialias_cosine`/`antialias_sine` 都用这一份。抄录的正确性由 `tools/decoder_ref.py --verify` 反向验证（与 libsndfile 吻合 127.5 dB，即 int16 上限）。
- libsndfile/mpg123 只在 Python 验证阶段作为解码 oracle 使用，不参与构建，不分发其代码。

## 规范与数据表

| 内容 | 当前状态 | 来源/计划 |
| --- | --- | --- |
| 帧头字段、帧长公式、边信息布局 | 已实现 | ISO/IEC 11172-3（MPEG-1 Audio） |
| 分析窗 `C[512]` | 已接入 | `hajimehoshi/go-mp3`（Apache-2.0）`synthDtbl`，见上；数值为 ISO/IEC 11172-3 Annex B 规范数据。仓库里存的是合成窗 `D`，分析窗 `C = D/32`（Table C.1）在 `analysis.mbt` 里按比例应用 |
| 解码器 antialias 系数（Table B.9） | 已接入（编码器侧做其逆） | ISO/IEC 11172-3 Table B.9 规范数值，见上 |
| 长块 MDCT、窗切换 | 长块与 start/short/stop 窗切换均已实现 | ISO/IEC 11172-3 §2.4.2.2 |
| scalefactor band 表 | 长块 21 带与短块 12 带均已接入；长块按采样率选表：32000 Hz 用 Table B.8.a、44100 Hz 用 B.8.b、48000 Hz 用 B.8.c | ISO/IEC 11172-3 Table B.8.a / B.8.b / B.8.c（规范数值），见 `src/mp3/scalefactor.mbt` 三个 `long_scalefactor_starts_*` 表；三段末尾的未编码尾带分别覆盖 550..575 / 418..575 / 384..575 |
| Huffman count1 表 A | 已实现（编码器输出表 A，全零尾部用 1-bit 终止码） | 依据 ISO/IEC 11172-3 Table B.7；数值表取自 `hajimehoshi/go-mp3`（Apache-2.0）解码表 32，blob 与 SHA-256 见上；并用 minimp3（CC0-1.0）`tab33` 交叉核对 |
| Huffman count1 表 B | 仅作数据校验，不在编码路径 | 依据 ISO/IEC 11172-3 Table B.7；`tools/huffman_tables.py` 对 A/B 两张四元表都做 Kraft 和、前缀冲突与表尺寸三项校验 |
| Huffman big-values 表 | 已实现 | `hajimehoshi/go-mp3`（Apache-2.0）`internal/huffman/huffman.go`，blob 与三重校验见上；linbits 用 minimp3（CC0-1.0）交叉核对 |
| 心理声学模型 | 不在 v1 范围 | 不实现，质量判据使用固定 SNR |

如果最终改用其他来源的 Huffman 表或窗系数，必须在合并前更新本文件，并保留原始许可证文本或链接。

## 测试素材

`tools/gen_fixtures.py` 生成的所有 WAV/PCM 都是合成信号（正弦、多音、扫频、白噪声、脉冲、静音、DC），不含第三方录音，不涉及音乐版权。

生成物位于 `target/fixtures/`，不提交到仓库；manifest 记录 SHA-256，便于复现和引用。

## Python 开发依赖

`numpy`、`soundfile`（libsndfile，其 MP3 解码由 mpg123 提供）与 `av`（PyAV，内含 ffmpeg 解码器）仅用于 `tools/` 下的验证和测量，不进入 MoonBit 包的运行时依赖。MoonBit 包本身零依赖。

## 变更要求

- 新增任何外部代码、数据表或生成脚本，必须同时更新本文件。
- 不允许把“参考了算法思路”写成“独立实现”而不说明来源；也不允许直接复制 LGPL 代码后改写成 MoonBit。
- 提交 PR 时在检查表中确认本文件已更新（如适用）。
