# DSH Remote

DeepSeek Harness (dsh) 的手机客户端，Flutter 构建。通过局域网连接运行 `dsh web` 的主机，在手机上使用 dsh 的完整会话能力。

## 环境要求

- **dsh ≥ 0.1.2-alpha.3**（typert 新协议 + browser-session 鉴权，在 0.1.2-alpha.3 上实测）。
  dsh 0.1.2-alpha.2 起旧点式协议被移除，**旧版 App（≤ v1.2.8）无法连接新版 dsh**；
  反之亦然：本版本 App 不支持 dsh ≤ 0.1.1-rc.2（旧协议宿主请使用 App v1.2.8 及以前版本）。
- 主机上运行 relay（见快速开始）；手机与主机同一局域网。

## 架构

```
┌──────────┐  envelope RPC (POST /api/<ns>/<method>) ┌────────────────────────┐
│ 手机 App  │ ◄────────────────────────────────────► │ relay/dsh-relay.mjs     │ ──► dsh web
│ (Flutter)│  WS /api/remote.mux（多路复用逻辑流）    │ 0.0.0.0:3081           │     127.0.0.1:3080
│          │  WS /__relay/outbox（文件推送）          │ （Host 改写+令牌换cookie）│    （loopback only）
└──────────┘                                        └────────────────────────┘
```

- dsh 的 Web 主机只绑定 loopback，且有 Host-header trust fence；relay 把请求转发到 `127.0.0.1:3080` 并把 `Host` 改写为回环地址，手机因此通过校验。
- dsh ≥0.1.2 还有 browser-session 鉴权：App 携带启动令牌（`x-dsh-token` 头），relay 用它向上游换取签名 cookie 并缓存复用（见下「DSH 启动令牌」）。
- 字段级协议参考见 `docs/api-reference-v2.md`（typert RPC + remote.mux 流 + 错误码；旧点式协议见 `docs/api-reference.md`）。

### relay 自有端点（不经过 host）

| 端点 | 用途 |
|---|---|
| `GET /__relay/listDir?path=` | 目录浏览（App 的 Workspace 目录选择器） |
| `POST /__relay/push` | 文件推送（**仅 loopback**，agent/MCP 用） |
| `GET /__relay/files/<id>` | 推送文件下载（`?token=` 可鉴权） |
| `GET /__relay/outbox` + WS | 推送收件箱列表 + 实时广播 |

## 快速开始

```bash
# 1. 启动 dsh web（默认 127.0.0.1:3080）
dsh web

# 2. 启动中继（或安装为常驻服务，见下）
node relay/dsh-relay.mjs            # 监听 0.0.0.0:3081，打印手机可达地址

# 3. 手机安装 App（GitHub Releases 有签名 APK），填入中继地址，如 http://192.168.1.5:3081
```

### 常驻服务（macOS launchd）

```bash
launchctl load ~/Library/LaunchAgents/ai.deepseek.dsh-remote-relay.plist
# 开机自启 + 崩溃自愈，日志 /tmp/dsh-relay.log
```

### 目录浏览（手机端可视化选择 Workspace 路径）

App 的目录浏览器由 **relay 的 `/__relay/listDir`** 提供（relay 跑在主机上，自己列目录）。
⚠️ 不要在 `cordis.patch.yml` 里把 host 的 directory-picker 换成 browse 后端——
那会让 Web GUI 失去新建工作区的原生流程（browse 的浏览器半边不在 web dist 的模块表里）。

### 全文会话搜索

bundle 默认关闭搜索索引（`openAt: never`）。启用（`~/.dsh/profiles/web/cordis.patch.yml`）：

```yaml
- id: session-query-sqlite
  config:
    path: ':memory:'
    openAt: first-search   # 首次搜索时才建索引
```

### 访问令牌（必填）

relay 的访问令牌持久化在主机 `~/.dsh-remote/config.json`（首次启动自动生成并打印
到启动日志），把它填到 App 主机配置的「访问令牌」。它独立于 dsh 的 launch token，
**跨 dsh/relay 重启不变**——dsh 侧的 browser-session cookie 由 relay 直接从
`~/.dsh/.credentials.yaml` 的签名密钥自铸，dsh 重启后自动恢复，无需任何人工操作。
（`DSH_RELAY_TOKEN` 环境变量仍可覆盖 config 文件，供调试；relay 指向远程 host 时
退回 launch-token 交换，App 侧可用 `x-dsh-token` 头携带。）

### 重启 dsh（App 主机菜单）

App 主机列表的「⋯ → 重启 dsh」让 relay 结束当前 dsh 进程并以 `dsh web --no-open`
重新拉起（保留原 cwd，输出到 `~/.dsh/dsh-relay-dsh.log`）。重启期间所有会话连接
中断；因上游 cookie 跨重启有效，恢复后 App 自动重连即可。

### 文件推送（agent → 手机系统下载器）

对 agent 说「把 xx 推送给我」即可。`push_to_phone` MCP 工具（stdio shim 在
`relay/mcp-push.mjs`）经 relay 暂存并广播，手机弹确认框后由**系统 DownloadManager**
下载（通知栏进度、公共 Downloads 目录、APK 可走系统安装器）。dsh 注册：

```yaml
- insert:
    - id: mcp-dsh-remote-push
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: dshremote
        transport: stdio
        command: node
        args: ['/path/to/dsh-remote/relay/mcp-push.mjs']
```

## 功能

**连接与会话**
- 服务器配置 + `host.describe` 连通性探测、relay 令牌、断线自动重连（双 WS + 就绪握手）
- Workspace/会话列表（host 事件驱动刷新）、全文搜索、目录浏览器建 Workspace、Workspace 重命名/删除
- Agent preset 选择器、会话重命名/分叉/归档、子代理查看与续聊（subagent.prompt/interrupt）
- 文件推送接收（弹窗确认 + 收件箱页）+ 回合完成本地通知

**聊天**
- 流式回复（chunk 按 index 拼块，40ms 批量冲刷，流式区独立渲染不阻塞列表）
- 历史分页（session/follow 快照 + session/page 翻页，chunkrow 服务端压缩，isolate 后台解析折叠）
- 上下文占用进度条（contextPressure 投影，三档语义色）、思考过程折叠、工具卡片
- 图片附件收发、askUserQuestion 交互、工具审批、steer 插队（长按发送）
- 队列管理、后台任务条、命令与技能 `/` 合并补全、系统注入消息卡片
- 消息长按复制 / 消息反馈（赞/踩）、导出会话日志 ZIP、模型思考强度切换

**状态与配置**
- goal 横幅（进度、暂停/恢复/完成/关闭）、todos 任务清单、plan 模式横幅
- 模型选择器、权限模式切换、设置页（字段编辑 + CAS 乐观锁 + 密钥掩码）
- NekoTheme 外观（浅色奶蓝樱花 / 深色暗夜粉彩 / 跟随系统），见 `docs/design.md`

## 开发

```bash
flutter pub get
flutter analyze
flutter test                                # 单测 + 真实抓包性能基准 + 活集成测试（需 relay 在跑）
flutter build apk --debug                   # 调试包
flutter build apk --release --split-per-abi # 正式包（需 android/key.properties）
```

签名：`android/key.properties` + `android/keystore/`（不入库）。贡献前必读 `AGENTS.md` 与 `docs/design.md`。
