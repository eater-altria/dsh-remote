# AGENTS.md

## 项目

DSH Remote——DeepSeek Harness (dsh) 的 Flutter 手机客户端。仓库内包含：

- `lib/` Flutter App（riverpod 状态层、`lib/api/` 传输与事件折叠、`lib/ui/` 页面）
- `relay/dsh-relay.mjs` 局域网中继（Host 头改写 + WS 隧道 + 目录浏览/文件推送 + 可选令牌 + x-dsh-token 上游鉴权）
- `docs/api-reference-v2.md` dsh host 的字段级 API 参考（新版 typert 协议；旧版点式协议见 `docs/api-reference.md`）

## 硬性规则

1. **设计系统**：做任何新功能、新组件、新页面或 UI 改动前，**先读 `docs/design.md`**。
   色板/字阶/圆角/组件模式都从 `lib/ui/theme.dart`（NekoTheme）取，禁止在页面里
   硬编码色值；`outline` 系列颜色仅用于边框，禁止用作文字色。
2. **API 契约**：与 host 交互前查 `docs/api-reference-v2.md`（dsh ≥0.1.2 新协议）；不要凭印象猜字段——
   不确定时用 curl 直连 host/relay 实测真实数据形状（历史教训：user/message、
   tool/result、command/run 的真实结构都与初版猜想不同）。
3. **异步数据读取**：Riverpod 的 `AsyncValue` 一律用 `.valueOrNull`（`.value` 在错误态会
   重新抛异常，曾导致整个页面灰屏）。
4. **改代码必须验证**：`flutter analyze` 零问题 + `flutter test` 全绿才算完成；
   UI 行为改动优先补测试（`test/` 里有连真实 relay 的集成测试范式）。
5. **批量补丁工具**：用 heredoc/python 生成 Dart 代码时**不要**手写 `\$` 转义——
   它会让 replace 静默失配或把字面 `\$` 写进源码。优先用 edit 工具做精准替换，
   替换后必须编译验证。
6. **提交**：有意义的提交粒度 + 中文 commit message；密钥类文件（`android/key.properties`
   `android/keystore/`）不入库。
