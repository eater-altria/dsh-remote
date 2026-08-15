# DSH Remote

DeepSeek Harness (dsh) 的手机客户端，Flutter 构建。通过局域网连接运行 `dsh web` 的主机，在手机上使用 dsh 的完整会话能力。

## 架构

```
手机 App (Flutter)  ──HTTP/WS──>  relay/dsh-relay.mjs (0.0.0.0:3081)  ──>  dsh web (127.0.0.1:3080)
```

- dsh 的 Web 主机只绑定 loopback，且有 Host-header trust fence；中继把请求转发到 `127.0.0.1:3080` 并把 `Host` 改写为回环地址，从而让手机通过校验（loopback-only 的特权方法如 settings.* 也因此可用）。
- 传输协议：`POST /api/<method>` 信封 RPC + `/api/events.mux`、`/api/events.host` 两条 WebSocket downlink + `POST /__relay/history.slim` 瘦身历史端点。详见 `docs/api-reference.md`（947 行字段级参考）。

## 快速开始

```bash
# 1. 启动 dsh web（默认 127.0.0.1:3080）
dsh web

# 2. 启动中继（或安装为常驻服务，见下）
node relay/dsh-relay.mjs            # 监听 0.0.0.0:3081，打印手机可达地址

# 3. 手机安装 App 后填入中继地址，如 http://192.168.1.5:3081
```

### 常驻服务（macOS launchd）

```bash
launchctl load ~/Library/LaunchAgents/ai.deepseek.dsh-remote-relay.plist
# 开机自启 + 崩溃自愈，日志 /tmp/dsh-relay.log
```

### 访问令牌（推荐在不可信网络启用）

```bash
DSH_RELAY_TOKEN=你的口令 node relay/dsh-relay.mjs
# App 设置页填入同一令牌；HTTP 与 WebSocket 握手均鉴权
```

## 功能

**连接与会话**
- 服务器配置 + `host.describe` 连通性探测、relay 令牌、断线自动重连（双 WS + 就绪握手）
- Workspace/会话列表（host 事件驱动刷新）、会话内容搜索、目录浏览器建 Workspace、Workspace 重命名/删除
- Agent preset 选择器、会话重命名/分叉/归档、子代理查看与续聊（subagent.prompt/interrupt）

**聊天**
- 流式回复（assistant/chunk 按 index 拼块，40ms 批量冲刷，流式区独立渲染）
- 历史分页（relay slim 瘦身 90%+，isolate 后台解析折叠）、seq 缺口检测自动补拉
- Markdown 渲染、思考过程折叠、工具调用卡片（宿主 view 标题/输出）、图片附件收发
- askUserQuestion 选项/自定义回答、工具审批（批准/拒绝）、steer 插队（长按发送）
- 队列管理（长按移除）、后台任务条（session/jobs）、命令与技能 `/` 合并补全
- 消息长按复制全文 / 消息反馈（赞/踩 + 备注，messageFeedback Remote）
- 导出会话日志（ZIP，含子代理与图片）

**状态与配置**
- goal 横幅（进度、暂停/恢复/完成，CAS ref）、todos 任务清单条、plan 模式横幅
- 模型选择器（session.models/selectModel）、权限模式切换（/permission）
- 设置页（settings.describe 命名空间 + 字段编辑 + expectedRevision 乐观锁 + 密钥掩码）
- 回合完成本地通知（后台时）、外观主题（浅色奶蓝樱花 / 深色暗夜粉彩 / 跟随系统）

## 开发

```bash
flutter pub get
flutter analyze
flutter test                                # 含真实抓包的 fold 性能基准
flutter build apk --debug                   # 调试包
flutter build apk --release --split-per-abi # 正式包（需 android/key.properties）
```

签名：`android/key.properties` + `android/keystore/`（不入库）。视觉系统见 `lib/ui/theme.dart`（NekoTheme）。
