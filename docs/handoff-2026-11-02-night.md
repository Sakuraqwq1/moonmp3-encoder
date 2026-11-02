# 交接：moonmp3-encoder（2026-11-02 夜）

> 给接手的新会话用。**先读这一份**，它压缩了整轮工作的全部上下文。
> 历史细节在 `docs/stage1-progress.md`（按时间倒序），任务书在 `docs/stage1-handoff.md`。
> 仓库 `<repo>`，`main` @ `2b73454`，CI 6/6 绿。

## 0. 30 秒速览

| 项 | 状态 |
| --- | --- |
| 阶段 1 | ≈70%（编码链路完整可听，但**分析层对宽带信号不互逆**） |
| 阶段 2 | ≈35%（双解码器一致 ✅、边界矩阵 ✅、SNR 门槛 ❌） |
| 整个项目 | ≈47% |
| **唯一待办** | **把分析滤波器组做成已验证解码器链的两侧反卷积逆** |
| **唯一判据** | `python tools/decoder_ref.py --score --noise`：现在 **0.01 dB**，目标 ≥30 dB |
| 花费 | 已用 ≈¥12 / 30 |
| 不要做 | 别再试线域置换/折叠变体（已数学证明不可能），别用单音判据 |

## 1. 仓库、门禁、环境

```powershell
Set-Location <repo>
$env:MOON = "$env:USERPROFILE\.moon\bin\moon.exe"
$PY = "<python>"

& $env:MOON fmt --check
& $env:MOON check --deny-warn
& $env:MOON test --deny-warn              # 当前 29
& $PY tools/decoder_ref.py --verify      # 必须 ≥40 dB，当前 127.5
& $PY tools/decoder_ref.py --score --noise
& $PY tools/selftest.py                  # 当前 32
& $PY tools/verify.py structure          # 12
& $PY tools/check_release.py
```

环境坑（都会直接卡住你）：

| 坑 | 解法 |
| --- | --- |
| `git.exe` 写不了盘 | 用 `dulwich` 提交推送（模板见 `docs/handoff-2026-11-02-pm.md` 第 8 节） |
| `raw.githubusercontent.com` 被挡 | 走 `api.github.com` contents 端点（base64） |
| PowerShell here-string 弄坏长提交信息 | **先 `write` 成文件，再 `open(...,'rb').read()`** |
| `moon fmt` 会重排函数签名 | 别用正则匹配源码做自动改写，用 `edit` 工具 |
| 改完代码要跑 `moon info` | 否则 CI 接口检查红 |

## 2. 已认证的地基（这些别动，也别怀疑）

| 资产 | 证据 |
| --- | --- |
| 帧头 / 边信息 / CBR 帧尺寸 | 字节级白盒；49 帧恰 20480 字节；200 帧不漂移 |
| 分析窗 `C[512]` | `tools/window_table.py --check`：512/512 匹配上游 blob |
| big_values Huffman（15 表） | Kraft 和 = 1、无码冲突、表尺寸全过；`tools/huffman_tables.py --report` |
| **解码器模型** | `tools/decoder_ref.py --verify` = **127.5 dB，拟合增益 1.0000**（int16 上限）→ 这个模型**就是**解码器 |
| 双解码器一致 | `tools/crossdecode.py`：mpg123 vs ffmpeg 相关度 **1.000000**、差 126.3 dB |
| 边界矩阵 | selftest：`2*1152±1`、满幅 99/100%、单样本脉冲 |
| 量化器 | 逐 granule 增益搜索 + 误差最小化；`global_gain = 210 + 4log2(peak/15^(4/3))` |

MPEG-1 关键事实（两源交叉核对）：**表 0–15 无 linbits，所以 `|is| ≤ 15`**。`MaxQuantLevel = 15`。

## 3. 核心诊断：分析层不是解码器的逆

证明链（每一步都可复现）：

1. 现分析层 = 512 点加窗 → 8 个 64 点块按列求和 → `cos((16+j)(2m+1)π/64)` 矩阵 →
   奇数带 18 条线倒序。这是**双边带**调制，奇数带在带内镜像。
2. 单音测不出问题：**单音是频率反转的特征函数**（反转后仍是同频单音），延迟搜索再把相位
   吃掉。所以单音闭合环能拿 35–46 dB —— **是相位巧合，不是重建**。
3. 白噪声立刻暴露：闭合环 **0.01 dB**（用 `analysis_ref.py` 里与 MoonBit 吻合 1e-16 的实现
   测的，与辅助实现一致，所以不是实现 bug）。加 `antialias` 的逆也没用（0.00 dB）。
4. 频线层倒序对宽带**数学上不可能修好**：把带宽内的谱反转再反转，恢复不了相位。

推论（重要）：**多音 4.56 dB、扫频 0–20 dB、带边缘塌陷，根因都在这里**，不是量化、
不是位预算、不是 scalefactor。所以 scalefactor 现在做也没用。

## 4. 三条已证伪的路线（别重复，每条都烧过钱）

| 路线 | 结果 |
| --- | --- |
| **线域置换**（11 个候选：identity/倒序17/倒序18/符号交替若干/边缘不动/整带取负/三种半 bin 插值） | 没有一种同时满足带内与带边缘；`reverse_negated` 最差 4.86 dB 但 440 掉到 18.02 |
| **折叠变体**（6 个：块内镜像/跨块镜像/先折叠后加窗/先加窗后折叠/双加号/双减号） | 奇数带镜像**完全不变**（子带主频都是 379.0 Hz）——实数调制天生双边带 |
| **因果反卷积**（`x_g = H0·lines_g + Σ H_j·lines_{g-j}`，逐 granule `pinv(H0)`） | **数值发散**：同块映射 `H0` 奇异 → 必须两侧（含未来 granule） |

另外：合成滤波器组直转置（选择性 0.33–0.76）也不可用。

## 5. 唯一正确路径

### 5.1 构造解码器的冲激矩阵 H

```python
# 关键结构（完整可跑版本见 git 历史里的 target/exp_adjoint6.py 思路）
E = eye(576); 对每条频线施加解码器的 antialias（八对 Givens，系数在 decoder_ref.py 的 CS/CA）
raw[band] = (COS36 @ E[:, band*18:(band+1)*18].T) * WINDOW   # IMDCT
sub[0:18] = raw[:18]; sub[18:36] += raw[18:]                 # overlap-add
奇数带奇数时间点取负                                          # frequencyInversion
每步 v[:64] = M @ sub[t]；u = 两项 U 构造；u *= D；out = u.reshape(16,32).sum(0)
H[:, t*32:(t+1)*32] = out.T                                  # (576, n_granules*576)
```

（`M`、`D`、`COS36`、`WINDOW`、`CS`、`CA` 全部在 `tools/decoder_ref.py` 里可直接 import。）

### 5.2 两侧反卷积（这一步是任务）

正问题：`x = Hᵀ·lines`（H 是 576×L，L 跨多个 granule）。
先验：`H0` 奇异 → 不能用因果递归。用下面任一种：

- **Wiener / 正则化逆**：`lines = Hᵀ (H Hᵀ + λI)⁻¹ x`，`H Hᵀ` 是带状，
  用共轭梯度或 `scipy`-free 的 Gauss-Seidel 迭代求解（禁止 scipy，用 numpy 手写 CG）。
- **块 Toeplitz 最小二乘**：取 12–16 个 granule 的短流，把整个系统（(N·576)×(N·576)）
  建成稀疏带状，用 `np.linalg.lstsq` 或多个小块迭代求解。

验收：`tools/decoder_ref.py --score --noise` **≥30 dB**（现在 0.01 dB）。

### 5.3 抽出 32 条带通原型（可移植的关键洞察）

逆算子必然是**带解耦 + 调制**结构：对逆算子输入一个单位频线（带 b、线 k），
得到一条 ~512–1000 抽头的响应，应满足

```text
h_{b,k}[n] ≈ P_b[n] · cos(π/72 · (2n+19) · (2k+1))
```

用最小二乘拟合出每带的 `P_b`（32 × ~512 = 16k 系数，和窗表同量级）。
**不需要把 576×L 的矩阵搬进 MoonBit**。

### 5.4 移植

- 只替换 `src/mp3/analysis.mbt` 的滤波器组部分（`AnalysisFilterbank::step`），
  MDCT、量化、Huffman、帧封装都不动。
- 新增 `src/mp3/prototype.mbt`（生成物，像 `window.mbt`）：由 `tools/` 里新脚本生成并校验。
- 判据：MoonBit 的 `lines` 与 Python 参考逐线吻合（1e-12 量级），且 white-noise 闭合环
  ≥30 dB，然后跑全部门禁 + `tools/sweep_snr.py`（应全频段 ≥20 dB）。

## 6. 测量方法学（血泪）

1. **不要用单音判据**：任何线性系统都把单音映射成同频单音；延迟搜索还会锁到别的周期
   （实测延迟出现 0/175/180/290/480/565 —— 固定系统不可能）。**一律用白噪声。**
2. **`--verify` 是所有结论的前提**：解码器模型掉到 40 dB 以下，后面的数全部作废。
3. 端到端 SNR（带量化）只能当参考，不能当分析层的判据。

## 7. 红线（违反会毁掉验收）

1. 不读、不移植 LAME / shine / libavcodec 源码（LGPL/GPL）。数据表只可用 MIT/Apache/CC0，
   并记入 `docs/provenance.md`。
2. 不改已稳定的帧头 / 边信息 / CBR 帧尺寸器。
3. `encode()` 公开契约不变（交织 Int32、44100 Hz、1/2 声道）。
4. 阶段 1 不做短块 / 联合立体声 / VBR / 心理声学模型。
5. **不 bump 版本、不打标签、不发布 mooncakes**（由项目所有者决定）。
6. `src/mp3/window.mbt`、`src/mp3/huffman_tables.mbt` 是生成物，不要手改。

## 8. 需要人类做的事（agent 做不了）

1. **申报书由本人主笔**（组委会明确点名过 AI 撰写，flac 因此被驳一次）。agent 只供素材：
   生态占位（有 MP3 读、无 MP3 写）、算法栈区别（MDCT/量化/Huffman vs LPC/Rice）、
   边界声明（无心理声学模型、固定 SNR 判据）、**人工调试叙事**（这一轮有三个现成的一手素材：
   折叠漏 4 dB、奇数子带镜像、单音判据的相位巧合）。
2. 决定何时报初审、要不要做浏览器 demo、第三项目名额用不用。
3. 如果能拿到 **ISO/IEC 11172-3 Annex B 分析滤波器组的折叠伪代码**，可以跳过 §5.2 直接写对分析层
   —— 这是最快的捷径（但注意：折叠必须同时把矩阵选对，单独改一个无效）。

## 9. 节奏建议

- 这一轮后半段三次失败烧了约 ¥4，教训是：**长会话后期每块钱产出明显下降，该换会话就换**。
- 新会话建议收窄到 §5.2 一件事，做完就停、写快照、再开新会话。
- 剩余额度 ≈¥18，走完 §5.2–§5.4 预计 ¥5–8，够。
