# Changelog

## [Unreleased]

- 位流：新增 count1 Huffman 表 B 写入器与固定频谱调试编码器；`tone`
  CLI 可生成 `big_values=0`、无 scalefactor、`main_data_begin=0` 的可解码
  单频流，用于第一条位流竖切
- 工具：确定性测试素材生成器（WAV + 裸 PCM + SHA-256 manifest）、SNR 测量
  （自动解码延迟对齐）、频谱峰值检查、`mp3dump` JSON / 严格模式、环境自检、
  发布预检、Python 工具链自测
- CI：新增 `tools (python)` 作业，覆盖素材生成、工具自测和结构验证
- 文档：阶段 1 交接、工具说明、验收自查、来源记录、决策记录、贡献约定
- 编码逻辑未变；0.1.1 仍是可解码静音结构里程碑

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
