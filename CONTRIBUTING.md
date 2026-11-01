# 贡献与开发约定

## 环境

- MoonBit：`moon` 在 PATH，或设置 `MOON`。
- Python 3.10+；开发依赖：

```bash
python -m pip install -r requirements-dev.txt
```

## 本地门禁

任何提交前必须通过：

```bash
moon fmt --check
moon check --deny-warn
moon test --deny-warn
python tools/check_release.py
python tools/gen_fixtures.py --quiet
python tools/selftest.py
python tools/verify.py structure
```

改了界面/CLI 或验证脚本时，同时更新 `docs/tooling.md` 和对应测试。

## 仓库结构

```text
src/bits/        MSB-first 位写入
src/mp3/         帧头、边信息、CBR 帧尺寸、编码入口
cmd/main/        base64 CLI（selftest / silent / version）
tools/           测试素材、帧解析、SNR、验证、自测
docs/            阶段交接、工具说明、验收、来源记录
target/          生成物，已忽略，不提交
```

新增编码层时优先新建模块，不要把分析、量化、Huffman 全部塞进 `encode.mbt`。

## 提交规范

使用语义化前缀：

- `feat:` 新能力
- `fix:` 修复
- `test:` 测试
- `docs:` 文档
- `chore:` 构建/仓库维护
- `perf:` 性能

提交正文说明**为什么**改，以及**怎么验证**。不要单日堆大量无意义提交；验收会看提交记录。

## 版本与发布

版本号三处同步：

1. `moon.mod` 的 `version`
2. `lib.mbt` 的 `version()`
3. `CHANGELOG.md` 的 `## [x.y.z] - YYYY-MM-DD`

发布顺序是：门禁 → 提交 → 推送 → 打标签 → `moon publish` → 下载发布包逐字节比对 → CI 全绿 → 全新目录复验。

**已发布的标签不删除、不移动。** 修复用新补丁版本。

## 许可证红线

- 不读取、不移植 LAME、shine 或其他 LGPL 编码器源码。
- 新的数据表或外部代码必须更新 `docs/provenance.md`。
- 测试 oracle 不等于实现来源；不要从解码器反推并复制编码逻辑。

## PR 检查

- [ ] 本地门禁全绿
- [ ] 新增/修改行为有测试
- [ ] 文档与命令同步
- [ ] 没有提交 `target/`、`_build/`、`*.mbti` 之外的生成物
- [ ] 如涉及外部代码/数据表，已更新 `docs/provenance.md`
- [ ] 提交信息说明了动机和验证方式
