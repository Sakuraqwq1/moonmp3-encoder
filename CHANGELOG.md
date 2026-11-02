# Changelog

## [Unreleased]

- 量化：接入 21 个长块 scalefactor band（Table B.8 44.1 kHz），
  `scalefac_compress` 的 slen1/slen2 与位写入，以及带位预算的逐带
  scalefactor 分配；全频段最差 SNR 由 26.79 dB 提升到 27.60 dB，440 Hz 由
  27.89 dB 提升到 29.32 dB
- 满幅：改为连续式 headroom 衰减规则（target=0.87），输入峰值 50–100 % 时解码峰值全部严格保持在 ≤1.00 以内（实测最大 0.9978），彻底消除 0 dBFS 素材过冲（代价是 100 % 满幅输出电平低约 1.2 dB，原始 SNR 17.9 dB，归一化后 28.92 dB 仍高于 LAME）
- 短块与窗切换：瞬态检测、start/short/stop 窗、12 点短 MDCT、短块频线
  reorder、36 个短 scalefactor 与切换块侧信息；孤立脉冲触发 start/short/stop
  并把预回声压到约 −58 dB，mpg123 与 ffmpeg 双解码器相关度 1.000000
- 位流：新增 count1 Huffman 表 B 写入器与固定频谱调试编码器；`tone`
  CLI 可生成 `big_values=0`、无 scalefactor、`main_data_begin=0` 的可解码
  单频流，用于第一条位流竖切
- 工具：确定性测试素材生成器（WAV + 裸 PCM + SHA-256 manifest）、SNR 测量
  （自动解码延迟对齐）、新增 `tools/lame_ref.py`（可复现同码率 LAME 128k 五探针基准测试）、
  频谱峰值检查、`mp3dump` JSON / 严格模式、环境自检、发布预检、Python 工具链自测
- CI：新增 `tools (python)` 作业，覆盖素材生成、工具自测和结构验证
- 文档：阶段 1 交接、工具说明、验收自查、来源记录、决策记录、贡献约定

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
