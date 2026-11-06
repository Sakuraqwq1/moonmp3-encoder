# Changelog

## [Unreleased]

## [0.2.2] - 2026-11-07

- 性能：缓存长/短块 MDCT 的余弦矩阵及四种块窗口，不再为每个子带、每个
  granule 重复计算三角函数；本地 3 秒单声道探针的热身运行耗时约从 1.01 s
  降至 0.82 s（约 19 %），公开 API 不变，优化前后 MP3 输出逐字节一致
- 测试：新增缓存窗口与余弦矩阵的逐项定义校验，`moon test` 由 42 增至 43 例
- 文档：修正公开接口注释中“scalefactor 尚未接入”的过期描述，以及 README
  中 Huffman 表仍“计划采用 minimp3”的过期来源说明

## [0.2.1] - 2026-11-03

- 包描述修正：`moon.mod` 的 description 还写着"stream writer ... decodable
  silence; audio coding is under development"，与 0.2.0 的实际能力矛盾；改为
  "MPEG-1 Layer III encoder ... 27.6-32.7 dB SNR"。0.2.0 的代码内容一字未改，
  这里只改包元数据，所以单独发一个补丁版本
- 版本号三处同步（`moon.mod` / `lib.mbt` / 本节）；`tools/check_release.py` 仍
  blocking=0

## [0.2.0] - 2026-11-03

- 音频编码真正落地：多相分析滤波器组与长块 MDCT 现在是**已验证解码器链的逆**
  （无量化闭环白噪声 84.44 dB、685 Hz 96.66 dB），端到端全段 SNR 27.6-32.7 dB
- 量化：接入 21 个长块 scalefactor band（Table B.8 44.1 kHz）与带位预算的逐带分配；
  全段最差 26.79 -> 27.60 dB，440 Hz 27.89 -> 29.32 dB，解码/参考幅度比由 0.965
  回到 0.997-1.000
- 主数据位保留区：`main_data_begin` 跨帧复用（实测 0..511），mpg123 与 ffmpeg
  相关度 1.000000
- 短块与窗切换：瞬态检测、start/short/stop 窗、12 点短 MDCT、短块频线 reorder、
  36 个短 scalefactor 与切换块侧信息；孤立脉冲把预回声压到约 -58 dB
- 满幅：连续式 headroom（target=0.87），输入峰值 50-100 % 时解码峰值全部 <=1.00
  （实测最大 0.9978）；代价是 100 % 满幅输出电平低约 1.2 dB，原始 SNR 17.9 dB、
  归一化后 28.92 dB 仍高于同码率 LAME
- 工具：新增 `tools/lame_ref.py`（可复现的同码率 LAME 128k 五探针基准）与 `alloc`
  分配器诊断命令；`tone` 可生成无 scalefactor 的固定频谱流
- 已知限制：短块 36 个 scalefactor 仍为全零（解码正确；逐带细化实测收益 <0.3 dB，
  未合入）；没有心理声学模型，质量判据是固定 SNR
- CI：`tools (python)` 作业覆盖素材生成、工具自测与结构验证
- 文档：阶段 1/2 进度、工具说明、验收自查、来源记录同步到实测数字

## [0.1.1] - 2026-11-01

- 修复 Windows CI 的接口新鲜度检查：提交 `.gitattributes`，强制 `.mbti` /
  `.mbt` / `.pkg` 使用 LF，避免 CRLF 检出把 `moon info` 的 LF 重写误判为接口过期
- 编码逻辑与 0.1.0 完全一致，发布包中的源文件内容不变

## [0.1.0] - 2026-11-01

- 帧头（MPEG-1 Layer III，128 kbps / 44100 Hz，无 CRC）与 CBR 帧尺寸控制：
  padding 按累积误差计算，`n` 帧后的字节总数恒等于 `floor(n * 144 * bitrate / samplerate)`
- 边信息打包：单声道 17 字节 / 立体声 32 字节，含窗口切换的完整布局
- MSB-first BitWriter
- 一次性 `encode` 入口：输出主数据为静音的合法帧流（结构里程碑，
  音频编码在后续版本落地）
- CLI：`selftest` / `silent` / `version`，二进制以 base64 传输
- 工具：`mp3dump.py` 逐帧解析 MP3 流（对照 LAME 参考文件校准）
