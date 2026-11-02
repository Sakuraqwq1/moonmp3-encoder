# 交接文档（2026-11-02 下午）

> 给接手的 agent 用。读完这一份就能知道：现在在哪、什么已验证、下一步做什么、哪里不能碰。
> **本文件取代 `docs/handoff-2026-11-02.md`（当天上午的快照）**；通用的任务书和判据在 `docs/stage1-handoff.md`。
> 进度详情见 `docs/stage1-progress.md`，频线映射见 `docs/line-frequencies.md`。

## 1. 一句话现状

阶段 1 完成约 **70%**。链路是：PCM → 分析滤波器组 → 长块 MDCT → **companded 量化
（逐 granule 增益搜索）** → **big_values Huffman + count1 尾部** → 位流 → 独立解码器。
440 Hz 单声道 **SNR 21.73 dB**（满幅 22.06，10% 幅度 21.68），主频 438.7 Hz，
`mp3dump --strict` 无警告，帧网格与 128 kbps CBR 未变。

缺的是 **scalefactor band 与逐带步长**，以及一个已定位但未修的**带边缘缺陷**（见第 4 节）。

## 2. 仓库与环境

| 项 | 值 |
| --- | --- |
| 仓库 | https://github.com/Sakuraqwq1/moonmp3-encoder（公开） |
| 本地目录 | `<repo>` |
| 分支 / HEAD | `main` @ `fbb3ab0`（已推送） |
| 版本 | `moon.mod` 仍是 0.1.1；**main 已明显领先该包，不要发布** |
| 模块名 | `Sakuraqwq1/moonmp3-encoder`，Apache-2.0，纯 MoonBit 零 FFI |
| moonc | v0.10.16（`C:\Users\dev\.moon\bin\moon.exe`） |

Python（验证用）：`<python>`
（numpy 2.3.5 / soundfile 0.14.0 / libsndfile 1.2.2）。

### 环境坑（和上一轮一致）

1. **`git.exe` 写不了盘**：`add`/`commit`/`clone` 全部失败在创建 `.git/index.lock`。
   用 `dulwich` 提交与推送，示例见第 8 节。
2. **`curl` / `raw.githubusercontent.com` 不可用**（`schannel` 与 TLS 都被掐断）。
   `pypi.org`、`registry.npmjs.org`、`github.com`、**`api.github.com` 可用**。
   抓单个文件走 GitHub API contents 端点（base64 解码），`tools/window_table.py` 就是这么做的。
3. **别依赖 `cd` 保持工作目录**：统一用绝对路径或 `Set-Location`。

## 3. 代码结构与职责

| 文件 | 责任 | 可否改动 |
| --- | --- | --- |
| `src/bits/bits.mbt` | MSB-first 写位、字节对齐 | 稳定，勿改 |
| `src/mp3/frame.mbt` | 帧头、帧尺寸器、padding 累积 | **稳定资产，勿重构** |
| `src/mp3/sideinfo.mbt` | 边信息打包 | **稳定资产，勿重构** |
| `src/mp3/encode.mbt` | 公开入口，现在真编码 | 内部可改，契约不变 |
| `src/mp3/count1.mbt` | count1 表 B 写入器 | 已完成 |
| `src/mp3/window.mbt` | **生成物**：512 个 ISO 分析窗系数 | 只由 `tools/window_table.py --write` 生成 |
| `src/mp3/analysis.mbt` | 多相滤波器组 + 长块 MDCT + 奇数子带修正 + `SynthesisGain` | 新增逻辑放这里 |
| `src/mp3/quantize.mbt` | `global_gain` 选择 + ±1 量化 + 预算控制 | 当前是"半峰硬门限"，要被替换 |
| `src/mp3/main_data.mbt` | 固定频谱调试编码器 | 调试用 |
| `cmd/main/main.mbt` | CLI：`selftest`/`silent`/`sine`/`encode`/`lines`/`tone`/`version` | 可加命令 |
| `src/mp3/mp3_wbtest.mbt` | 帧/边信息/count1 的 17 条白盒测试 | 可加 |
| `src/mp3/analysis_wbtest.mbt` | 窗口表、子带选择性、TDAC、量化、granule 的 5 条 | 可加 |

**下一步该新建的文件**：`src/mp3/huffman.mbt`（big_values 表 0–15、region0/1、linbits）
与 `src/mp3/scalefactor.mbt`（band 表 + 逐带 scalefactor）。不要塞进 `frame.mbt` /
`sideinfo.mbt` / `analysis.mbt`。

帧预算（128 kbps / 44100）：每帧 417 或 418 字节，减 4 字节头、减 136/256 位边信息，
**单声道每 granule 约 1584 位、立体声约 762 位**。当前 `encode()` 按
`(帧位数 - 32 - 边信息) / (2 × 声道)` 分配并约束非零系数个数；换成 big_values 后要改成按带分配。

## 4. 已完成并验证

| 能力 | 证据 |
| --- | --- |
| 帧头 / 边信息 / CBR 帧尺寸 | 字节级白盒测试；49 帧恰 20480 字节；200 帧不漂移 |
| 静音流可解码 | `verify.py structure` 12/12，peak 全 0 |
| count1 表 B | 逐位白盒测试 |
| 分析窗 `C[512]` | `tools/window_table.py --check`：512/512 逐项匹配上游 blob |
| 多相分析滤波器组 | 344 Hz 单音在子带 0 占 0.9996 能量；numpy 参考逐线差异 1e-16 |
| 长块 MDCT | TDAC 重建：拟合增益 9.0，相对残差 < 1e-9 |
| **big_values Huffman（15 张表）** | Kraft 和 = 1、无码字冲突、表尺寸全部通过；440 Hz 用 13/15 号表解码正常 |
| **真实量化 + 增益搜索** | 440 Hz @50% **21.73 dB**、@满幅 22.06 dB、@10% 21.68 dB |
| PCM→位流→出声 | 主频 438.7 / 1001.3 / 3001.2 / 7999.6 / 15000.6 Hz，全部在一条频线内 |
| 频线映射尺子 | `docs/line-frequencies.md`，35/35 线，最大偏差 0.042 Hz |
| 质量门 | `moon test` 28/28、`selftest.py` 28/28（含 SNR ≥ 20 dB）、`verify.py structure` 12/12 |

## 4b. 已定位的缺陷：带边缘的音塌到 2.86 dB

660 Hz 的 SNR 只有 2.86 dB，而 440 Hz 有 21.73 dB。原因已定位，不是量化问题：

- MPEG-1 原型滤波器的过渡带很宽，660 Hz 的能量约 **64% 落在子带 0、36% 落在子带 1**。
- 伪 QMF 的奇数子带在带内频谱是反的，编码器必须把子带 1 的 18 条线倒序修正
  （`analysis.mbt` 的 `odd_band_value`）。这一步对**带内**内容正确，但会把子带 1 的
  **边缘**能量搬到带内另一端，破坏了 0/1 两个带之间的混叠抵消。
- 同一个根因让奇数子带里的音（1000/8000/15000 Hz）比偶数子带低 3–6 dB，也让
  立体声 440/660 那组只有 8.32/2.13 dB（**不是串扰**：左右频率各自正确）。

**解法**：把分析滤波器组的**折叠形式**按规范写对。现在的实现是"加窗 + 8 块按列求和"，
它是规范求和式的直和等价式，但丢掉了折叠带来的带间相位关系。判据很明确：修好之后
`tools/odd_band.py` 的扫描里 identity 应当变成最优，且 660 Hz 与 1000 Hz 的 SNR 都 ≥ 20 dB。

已经试过但**不对**的三条路（别重复）：合成滤波器组直转置（选择性掉到 0.33–0.76）、
块内镜像折叠（相邻带漏 4 dB）、倒序 + 交替变号（频率对、波形毁，−1.7 dB）。

## 5. 未完成（阶段 1 剩余）

| 模块 | 状态 | 难度 |
| --- | --- | --- |
| big_values Huffman（表 0–15） | **已完成**（region 全用同一张表，规避带表依赖） | — |
| scalefactor band 表 + 逐带 scalefactor + 逐带 gain | 0% | ★★★★★ |
| 立体声按带独立预算（现在是均分） | 20% | ★★★ |
| **分析滤波器组的规范折叠**（带边缘缺陷的根因） | 0% | ★★★★ |
| 多音 / 扫频 / 脉冲用例 | 30%（多音三个分量已在，但 SNR 4.56 dB） | ★★★ |
| bit reservoir 跨帧复用 | 有意留阶段 2 | — |

## 6. 建议的开工顺序

1. **把分析滤波器组的折叠写对**（见 4b）：这是 660 Hz / 奇数子带 / 立体声三组数字的共同根因，
   优先级最高。想省事的话，可以先用"对 32 个候选窗-调制对做选择性搜索"的办法反推，
   判据是 660 Hz 的 SNR 从 2.86 dB 抬到 20 dB 以上。
2. **scalefactor band 表 + 逐带 scalefactor**：接上之后才有按带压缩，也才能进码率控制；
   顺带能把多音的 4.56 dB 拉起来。
3. **补齐用例**：`chirp`、`impulse`、满幅（99% 时解码峰值 1.150，有削波风险）进
   `tools/selftest.py`，重测 `snr.py`。
4. 立体声按带分配预算（现在均分；660 Hz 那组受影响也有预算因素）。

## 7. 红线

1. **不读、不移植 LAME / shine / libavcodec 源码**。libsndfile/mpg123/go-mp3/minimp3
   只能当解码 oracle 或**数据表来源**，不能从中抄编码逻辑；数据表来源必须进 `docs/provenance.md`。
2. **不改已稳定的帧头、边信息布局、CBR 帧尺寸器**，除非测试证明有 bug。
3. **`encode()` 的公开契约不变**：交织 `Int32`、44100 Hz、1/2 声道、16-bit 范围。
4. **阶段 1 不做**短块、联合立体声、VBR、心理声学模型。
5. **不 bump 版本、不打标签、不发布 mooncakes**。
6. **失败模式是静默的**：这一轮三个 bug（折叠、奇数子带反转、探针退化）都"能跑、能解析、
   能出声"。每个新模块都要有数值参考——`tools/analysis_ref.py` 是模板。
7. `src/mp3/window.mbt` 是生成物，不要手改；要改就走 `tools/window_table.py --write` 并更新
   `docs/provenance.md`。

## 8. 每步必跑的门禁

```powershell
Set-Location <repo>
$env:MOON = "$env:USERPROFILE\.moon\bin\moon.exe"
$PY = "<python>"

& $env:MOON fmt --check
& $env:MOON check --deny-warn
& $env:MOON test --deny-warn              # 当前 22
& $PY tools/doctor.py
& $PY tools/window_table.py --check      # 512 系数逐项比对（需要网络或 target/ref 缓存）
& $PY tools/analysis_ref.py --self
& $PY tools/analysis_ref.py --compare --freq 440
& $PY tools/selftest.py                  # 当前 27
& $PY tools/verify.py structure          # 当前 12
& $PY tools/check_release.py
```

改了分析层或量化层，再加跑：

```powershell
& $PY tools/probe_lines.py --lines 0-35 --pairs      # 约 1 分钟，35/35 才算过
& $PY tools/snr.py target/ref440.wav target/dec440.mp3
```

### 提交与推送（dulwich，因为 `git.exe` 写不了盘）

```python
from dulwich import porcelain
from dulwich.repo import Repo

repo = Repo(r"<repo>")
author = b"Sakuraqwq1 <Sakuraqwq1@users.noreply.github.com>"
porcelain.add(repo, paths=["src/mp3/huffman.mbt", "src/mp3/pkg.generated.mbti", ...])
sha = porcelain.commit(repo, message=open(r"target\commit.txt", "rb").read(),
                       author=author, committer=author)
porcelain.push(repo, "origin", refspecs=["refs/heads/main:refs/heads/main"])
```

**提交信息用长字符串时，先写到文件再读**：PowerShell 的 here-string 会把长文本里的
引号弄坏（本轮踩过）。改完 `moon check` 记得跑 `moon info` 更新 `pkg.generated.mbti`，
否则 CI 的接口检查会红。提交信息用语义化前缀，正文讲清**为什么改**和**怎么验证**，
按真实节奏分散提交。

## 9. 当前已知风险

| 风险 | 说明 |
| --- | --- |
| **带边缘缺陷** | 660 Hz 只有 2.86 dB，奇数子带低 3–6 dB，立体声那组因此偏低。根因与解法见 4b，修好前不要拿这组数字去申报 |
| 峰值过冲 | 满幅（99%）输入解码峰值 1.150，仍有过冲；`fullscale_mono_1s` 尚未进门禁 |
| `SynthesisGain` 常数 | 288 是由"逆 MDCT 9 × 子带 32"推出的，实测 294.7–301.2，差 3%；换真实量化后要重新推导 |
| 奇数子带修正 | "倒序 + 交替变号"是对着解码器实测出来的，规范只是从解码器那头描述；若换解码器 oracle，先复验 8000 Hz |
| 立体声预算 | 按声道均分，不是按复杂度；一侧安静时浪费预算 |
| 探针限制 | `tone` 单线探针只能探偶数 bin，别再用它判断奇数 bin 的频率 |
| 包落后于仓库 | `main` 领先 0.1.1，阶段 1 完成时统一升版发布 |

## 10. 完成后怎么算过

见 `docs/stage1-handoff.md` 第 2 节的 9 条判据。当前状态对照：

| # | 判据 | 状态 |
| --- | --- | --- |
| 1 | 440 Hz 单声道非静音且主频正确 | ✅ 438.7 Hz，SNR 21.73 dB |
| 2 | 立体声 440/660 不串音 | ✅ 左右分别 438.7 / 659.5 Hz（SNR 偏低见 4b） |
| 3 | `multitone_mono_1s` 三分量都在 | ✅ 441.4 / 877.5 / 1318.9 Hz（SNR 4.56 dB） |
| 4 | 单/立体声帧数、长度、声道数正确 | ✅ 结构门禁覆盖 |
| 5 | `mp3dump --strict` 无警告，位长与实际一致 | ✅ 逐 granule 断言 written == cost |
| 6 | `main_data_begin` 不越界 | ✅ 恒为 0 |
| 7 | 精确 128 kbps CBR，帧网格不漂移 | ✅ |
| 8 | `verify.py structure` 不回归 | ✅ 12/12 |
| 9 | 至少记录一次 SNR | ✅ 21.73 dB（另有 2.86 dB 的带边缘反例） |

阶段 1 不要求 SNR 达标（正弦 ≥20 dB / 音乐 ≥15 dB 是阶段 2 门槛）。
