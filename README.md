# DSH Remote

DeepSeek Harness (dsh) 的手机客户端，Flutter 构建。通过局域网连接运行 `dsh web` 的主机，在手机上使用 dsh 的会话能力。

## 架构

```
手机 App (Flutter)  ──HTTP/WS──>  relay/dsh-relay.mjs (0.0.0.0:3081)  ──>  dsh web (127.0.0.1:3080)
```

- dsh 的 Web 主机只绑定 loopback，且有 Host-header trust fence；中继把请求转发到 `127.0.0.1:3080` 并把 `Host` 改写为回环地址，从而让手机通过校验。
- 传输协议：`POST /api/<method>` 信封 RPC + `/api/events.mux`、`/api/events.host` 两条 WebSocket downlink。详见 `docs/api-reference.md`。

## 运行

```bash
# 1. 启动 dsh web（默认 127.0.0.1:3080）
dsh web

# 2. 启动中继（手机可达地址会打印出来）
node relay/dsh-relay.mjs            # 监听 0.0.0.0:3081

# 3. 手机上安装 App 后，在设置页填入中继地址，如：
#    http://192.168.1.5:3081
```

## 已实现

- 服务器配置与连通性探测（host.describe）
- Workspace / 会话列表（host 事件驱动自动刷新）
- 聊天：历史加载与分页、流式回复（assistant/chunk）、Markdown 渲染、思考过程折叠、工具调用卡片、队列提示
- 交互：askUserQuestion 选项/自定义回答、工具审批（批准/拒绝）、停止当前回合
- 断线自动重连

## 开发

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```
