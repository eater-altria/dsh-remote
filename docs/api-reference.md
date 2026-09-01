# DeepSeek Harness (dsh) client↔host Wire API 参考手册（旧版协议，≤0.1.1-rc.2）

> ⚠️ dsh 0.1.2-alpha.2 起协议已更换（typert remote + remote.mux），新版见 `api-reference-v2.md`。
> 本文件仅保留作历史参考与旧版 host 兼容。

> 面向 Flutter / 手机客户端实现的完整逆向参考。
> 提取自 dsh 安装产物 `/usr/local/lib/node_modules/@deepseek-ai/dsh/`（版本 `0.1.0-rc.6`），
> 主要源码依据：`dsh-host-apiproxy/lib/types/api/*.schema.js`（zod schema，金标准）、
> `dsh-client-connection/lib/client.js`（浏览器载体）与 `lib/index.js`（host 端 /api 路由 + trust fence）、
> `dsh-api-gateway` / `dsh-api-remotes` / 各业务包的 `typert.remote-client.js`（Remote 端点）、
> `dsh-session/lib/types/types.d.ts` + `known-event-types.js`（SessionEvent 词汇表）、
> `dsh-llm/lib/types/types.d.ts` + `message.d.ts`（消息/流式词汇表）。
>
> 标注「（未确认）」的条目表示在构建产物中未能找到直接证据，实现时需实测验证。

---

## 目录

1. [传输层总览](#1-传输层总览)
2. [Host header trust fence（手机经 LAN 访问的关键）](#2-host-header-trust-fence)
3. [Unary RPC：POST /api/&lt;method&gt;](#3-unary-rpcpost-api小于method大于)
4. [/api/respond：应答 approval / question](#4-apirespond应答-approval--question)
5. [WebSocket downlink：/api/events.mux 与 /api/events.host](#5-websocket-downlink)
6. [完整方法清单（RpcMethodMap，52 个）](#6-完整方法清单)
7. [Remote（Typert）端点：/api/&lt;namespace&gt;/&lt;method&gt;](#7-remotetypert端点)
8. [事件流：MuxFrame / HostFrame 全字段](#8-事件流帧格式)
9. [SessionEvent 词汇表（session/event 的 data）](#9-sessionevent-词汇表)
10. [Session 投影（session/projection）](#10-session-投影)
11. [错误码全集（RpcErrorDetailsMap）](#11-错误码全集)
12. [辅助端点：session.export 下载](#12-辅助端点sessionexport-下载)
13. [最小连接流程示例](#13-最小连接流程示例)
14. [Flutter 实现注意点](#14-flutter-实现注意点)

---

## 1. 传输层总览

dsh 的 client↔host 协议由 **三种载体** 组成，全部挂在同一 HTTP 服务的 `/api` 前缀下：

| 通道 | 方向 | 协议 | 路径 |
|---|---|---|---|
| Unary RPC | client → host（请求/响应） | HTTP POST + JSON | `POST /api/<method>` |
| Respond | client → host（应答 host 发起的 question/approval） | HTTP POST + JSON | `POST /api/respond` |
| Mux downlink | host → client（session 相关事件流） | WebSocket（**仅下行文本帧**） | `GET /api/events.mux`（Upgrade） |
| Host downlink | host → client（workspace/session 列表等全局事件） | WebSocket（仅下行文本帧） | `GET /api/events.host`（Upgrade） |
| 文件下载 | host → client | 普通 HTTP GET（无信封） | `GET /api/session.export?...` |

要点：

- **消息层是四象限信封**（four-quadrant envelope），由 `type` 字段判别：`client-request` / `server-response` / `server-request` / `client-response`。Unary 用前两个；downlink 帧一律是 `server-request`；`/api/respond` 用 `client-response`。
- **两级解析纪律**：信封层只校验 `type`/`rpcId`/`method`，`payload` 与 `result.value` 槽位为 `unknown`，按 method 做第二次 schema 校验。客户端实现应同样分层。
- **WebSocket 是浏览器载体的唯一 downlink 形态**。SSE（`text/event-stream`）只存在于同进程（in-process）载体中，真实 HTTP 服务器对这两条路径的普通 GET 返回 **426 Upgrade Required**（带 `connection: Upgrade` / `upgrade: websocket` 头），**没有 SSE 回退**。手机客户端必须用 WebSocket。
- 两条 WebSocket **纯下行**：客户端在 socket 上不发送任何应用数据。二进制帧会被客户端视为错误（`binary WebSocket frame`），host 只发文本帧。
- 任何一条 socket 断开 → 当前「连接代（generation）」整体失败，两条流一起重建。就绪（ready）握手 = 两条 socket 均打开 **且** `host.describe` HTTP 调用成功。
- HTTP 状态码只表达载体层错误：`404` 未知路径 / `415` 非 JSON Content-Type / `400` body 非 JSON / `500` handler 崩溃 / `403` trust fence 拒绝 / `426` 需要 WS Upgrade。**业务错误一律 HTTP 200 + `server-response` 信封内 `result.ok=false`**。

---

## 2. Host header trust fence

源码：`dsh-client-connection/lib/index.js`（`isTrustedApiRequest`）。这是**每一个 `/api` 请求（含 WebSocket Upgrade 握手）**进入 RPC 分发前的强制检查，失败直接 `403 forbidden`（Upgrade 则拒绝握手）。它是**可达性策略，不是认证层**。

判定逻辑（`isTrustedApiRequest(request, trustedHosts)`）：

```
1. 取 Host 头；缺失或无法按 WHATWG URL 解析 → false
2. Host 的 hostname 必须满足其一：
   a. 是 loopback：'localhost'、'[::1]'、或 127.0.0.0/8 任意 IPv4（逐段校验 0-255）
   b. 命中 trustedHosts 某条目：
      - 条目带端口 'host:port' → 精确匹配 host:port
      - 条目不带端口 'host'       → 匹配该 hostname 的任意端口
      （两侧都经 WHATWG 规范化比较，大小写/冗余 :80 不影响判定 → 防 DNS rebinding）
3. 若带 sec-fetch-site: cross-site 头 → false
4. 若带 Origin 头 → Origin 的 host 必须与 Host 头完全一致，否则 false
```

`trustedHosts` 条目本身在插件加载时严格校验：必须是裸 `host[:port]` authority（WHATWG 解析后逐字节读回），否则**插件加载直接报错**（`client-connection: trustedHosts entry ... is not a bare host[:port] authority`）。

### 对手机客户端（LAN 访问）意味着什么

手机 app 不是浏览器，不携带 `Origin` / `sec-fetch-site`，因此只需要 **Host 头过关**。三种过法：

1. **SSH 隧道回环**（最省事，无需改服务端）：`ssh -L 3080:127.0.0.1:3080 user@host`，手机连本地转发端口时 Host 为 `127.0.0.1` → 直接过。
2. **LAN IP 字面量自动信任**：当 webserver 以 `0.0.0.0` 绑定（cordis.yml 的 `webServer.host: 0.0.0.0`）时，web runtime 会把本机所有非回环 IPv4 地址自动并入 trustedHosts（`resolveLanTrust`：`networkInterfaces()` → 非 internal 的 IPv4）。手机以 `http://<LAN-IP>:<port>` 访问时 Host 即该 IP → 通过。
3. **显式声明**：CLI `dsh --profile web --trusted-host <authority...>`（可重复），或 cordis.yml 中 client-connection 插件配置 `trustedHosts: [...]`。

**注意 CLI 层故意拒绝 `--host 0.0.0.0`**（报错「intentionally not supported yet for safety: it would expose remote code execution to the network」）。要 LAN 暴露只能在 cordis.yml 里把 webserver 绑定改成 `0.0.0.0`。

### browser-session 认证（dsh ≥ 0.1.2 新增，fence 之后的第二道门）

0.1.2 起，trust fence 之外**每个请求（含 WS 握手）还须通过 browser-session 认证**
（`dsh-client-connection/lib/index.js` 的 `BrowserAuth`）：

- **令牌交换**：`GET /?token=<launchToken>` → `303` + `Set-Cookie: dsh-auth-<b64u(sha256(authority))>=v1.<b64u(payload)>.<b64u(hmac)>`。
  launchToken 是**每进程随机**的（WeakMap 持有，不持久化），打印在 `dsh web` 启动 URL 里。
- **cookie 校验**：payload = `{version:1, authority, issuedAt, expiresAt}`，HMAC-SHA256 签名，
  密钥持久化在 `~/.dsh/.credentials.yaml`（`client-connection/browser-session` 记录，32 字节
  base64url）——所以**已铸 cookie 跨 dsh 重启仍有效**，直到自身过期（`cookieMaxAgeDays`，默认 30 天）。
- cookie 绑定 authority（Host 头）：经 relay 访问时 relay 已把 Host 改写为
  `127.0.0.1:3080`，所以交换与后续请求的 authority 必须一致。
- 失败一律 `401`（`dsh web authentication required; reopen the URL printed by dsh web.`）。

**relay 的处理**：App 在主机配置里填 launch token，随请求带 `x-dsh-token` 头；
relay 用 `GET /?token=` 向上游交换 cookie 并缓存（剩余有效期 <5min 才重换），注入所有
转发请求（HTTP + WS 握手 + slim history）；上游 401 时失效缓存、强制重换并重试一次。
launch token 在 dsh 重启后失效，但缓存 cookie 未过期时 relay 继续可用；cookie 也过期后
需在 App 里更新 token。

### 特权方法（loopback-only 清单）

即使通过了 trustedHosts fence，下列方法仍被**额外**以空信任列表再过一次 fence —— 即 **LAN/手机客户端永远 403**，在认证层落地之前只能 loopback 使用：

```
agentPreset.read / agentPreset.copy / agentPreset.openDocument / agentPreset.remove
host.pickDirectory / host.openPath
settings.describe / settings.openDocument / settings.update / settings.replace / settings.mutate
credentials.describe / credentials.set / credentials.unset
llm.discoverModels
```

不在清单内的方法（含 `llm.providers`、`llm.models`、`agentPreset.list`、`agentPreset.select`、全部 `session.*`、`workspace.*`、`goal.*`、`host.describe` 等）trustedHost 可达。

### 其他载体层限制

- 请求体默认上限 **160 MiB**（`maxRequestBodyBytes`，默认 167772160），按「100 MiB 聚合图片上限 base64 膨胀 4/3 + 1 MiB 信封余量」校核；超限由 bridge 层拒绝。
- 仅接受 `Content-Type: application/json`（按分号前媒体类型、忽略大小写比较）。这是跨站写防护：浏览器对 `text/plain`/表单 POST 不做 CORS 预检，强制 JSON 迫使恶意页面走预检，而本服务器从不应答预检。

---

## 3. Unary RPC：`POST /api/<method>`

### 3.1 请求信封（ClientRequest）

```json
{
  "type": "client-request",
  "rpcId": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
  "method": "session.list",
  "payload": { }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | `"client-request"` 字面量 | 必填 |
| `rpcId` | string | 客户端生成的关联 id（官方实现用 `crypto.randomUUID()`）；响应原样回显，**必须校验回显一致**，否则视为协议错误 |
| `method` | string | 必须**与 URL 路径段完全一致**：`POST /api/session.list` 的 body 里 `method` 必须是 `"session.list"`，不匹配返回 `bad-request` |
| `payload` | 任意 JSON | 方法的业务参数，schema 见第 6 节；无参方法传 `{}` |

### 3.2 响应信封（ServerResponse）

成功：

```json
{
  "type": "server-response",
  "rpcId": "<原样回显>",
  "result": { "ok": true, "value": { /* 方法业务返回值 */ } }
}
```

失败（**HTTP 仍是 200**）：

```json
{
  "type": "server-response",
  "rpcId": "<原样回显；若请求信封本身无法解析则为固定哨兵 \"invalid-request\">",
  "result": {
    "ok": false,
    "error": {
      "code": "session-not-found",
      "message": "...",
      "details": { "sessionId": "..." }
    }
  }
}
```

- `result.ok=true` 时 `value` 槽位对「无返回值」的方法**整个字段缺省**（void 结果序列化为无 `value` 键）。
- `error.details` **必定存在**（可能是 `{}`），其形状按 `code` 判别，见第 11 节。
- 客户端应对 `value` 做二次校验（官方实现对 52 个方法各有一张 value schema 表 `UNARY_VALUE_SCHEMAS`）。

### 3.3 超时

- 官方客户端默认 unary 超时 **30 s**（`DEFAULT_TIMEOUT_MS = 30_000`，`AbortSignal.timeout` 与调用方 signal 合并）。
- 例外：`host.pickDirectory`（原生系统对话框，用户节奏）**不使用默认超时**，只随调用方 signal。
- 流式通道无超时，由重连循环管理（见 5.3）。

---

## 4. `/api/respond`：应答 approval / question

host 通过 mux downlink 推送 `approval/requested` 或 `question/requested` 帧（这两类帧的 `rpcId` 是**在 host 的 pending 注册表中生成的稳定 id**，而非随机帧 id）。客户端用 `/api/respond` 应答：

### 请求（ClientResponse 信封）

```json
{
  "type": "client-response",
  "rpcId": "<对应 requested 帧的 rpcId，原样回显>",
  "result": { "ok": true, "value": { /* 应答 payload，见下 */ } }
}
```

approval 应答 `value`（`approvalResponsePayloadSchema`）：

```json
{ "sessionId": "...", "approvalId": "...", "outcome": "allowed-once" }
```
`outcome` ∈ `"allowed-once" | "rejected"`。

question 应答 `value`（`questionResponsePayloadSchema`）：

```json
{
  "sessionId": "...",
  "answer": {
    "answers": [
      { "id": "<问题 id>", "selected": ["选项 label"], "custom": "可选自由文本" }
    ]
  }
}
```

### 响应（Receipt，非信封）

```json
{ "accepted": true }
```
或
```json
{ "accepted": false, "reason": "not-pending" }
```
`reason` ∈ `"not-pending" | "bad-response"`（信封无法解析时直接 `{accepted:false, reason:"bad-response"}`）。应答成功后 host 会向所有 mux 消费者广播对应的 `approval/resolved` / `question/resolved` 帧。

---

## 5. WebSocket downlink

### 5.1 连接

- URL：`ws(s)://<authority>/api/events.mux` 与 `ws(s)://<authority>/api/events.host`（协议由页面/基准地址推导：`https:` → `wss:`，否则 `ws:`）。无子协议、无查询参数。
- Upgrade 握手同样过 trust fence（Host 头判定，浏览器握手会带 Origin 做同源比较），失败在协商前拒绝（裸 `HTTP/1.1 403 Forbidden`）。
- 每条消息是一个 JSON 文本帧，内容为 **ServerRequest 信封**：

```json
{
  "type": "server-request",
  "rpcId": "<每帧随机 UUID；approval/question 的 requested 帧除外，为 pending 稳定 id>",
  "method": "<帧 type，如 \"session/event\">",
  "payload": { "type": "session/event", "...": "..." }
}
```

`method` 恒等于 `payload.type`。客户端两层解析：先 `serverRequestSchema`，再按流类型用 `muxFrameSchema` / `hostFrameSchema` 解析 `payload`。**解析失败的单帧被丢弃并记日志，不kill流**（seq 缺口检测兜底，见 5.4）。

### 5.2 mux 流的打开即订阅语义

`events.mux` **没有按 session 订阅的调用**——打开 socket 即订阅 host 上当前 attach 的所有 session。打开时 host 立即推送基线（baseline）：

1. 每个活跃 session 一帧 `session/subscribed`（携带该 session 的 `lastSeq`）；
2. 所有未决 `question/requested`、`approval/requested`（用 pending 表里的稳定 rpcId 重放）；
3. 有未读队列的 session 各一帧 `session/queue`；
4. 有 jobs 的 session 各一帧 `session/jobs`。

之后新 session 创建（`session/created`）时再推其 `session/subscribed`。此后 `session/event`、`session/projection`、`session/queue`、`session/jobs`、approval/question 帧实时推送。

`events.host` 打开时无强制基线帧（host 端用 SSE 注释行 `: connected` 保活——WS 载体下无对应物；基线数据如 workspace 列表由客户端主动调 `workspace.list` / `session.list` 拉取，变更靠 host 帧驱动）。（未确认：WS 载体是否发初始 `: connected` 等价物——官方 WS 客户端不依赖它。）

### 5.3 重连 / ready 握手（ConnectionController）

官方循环（`dsh-client-connection/lib/client.js`）：

```
loop:
  1. 并行打开 mux + host 两条 socket
  2. 并发执行: host.describe({}) 与 「两 socket 均 open（3 s streamOpenTimeoutMs 上限）」
  3. host.describe 失败 → 本代失败；成功 → attempt=0, 状态 connected, 发布 hostDescription
  4. 任一 socket 关闭/出错/收到 stream/error 帧 → 整代中止（abort 另一条）
  5. 状态 reconnecting，指数退避：delay = jitter(cap/2)，cap = min(10000, 500 * 2^(attempt-1))
  6. 回到 1
```

退避参数：`backoffBaseMs=500, backoffFactor=2, backoffMaxMs=10000, streamOpenTimeoutMs=3000`，实际等待为 `cap/2 + random*cap/2`。

### 5.4 seq 缺口检测

每个 `session/event` 的 `event.seq` 在 session 内单调连续。客户端对照 `session/subscribed.lastSeq` 与本地已见 seq：发现缺口说明漏帧（被丢弃的坏帧或断流窗口），应重拉 `session.history` 补齐。`lastSeq = session.seq - 1`；**-1 表示空日志**。

---

## 6. 完整方法清单

`RpcMethodMap` 共 **52 个方法**。下表字段按 zod schema 逐字段提取；`?` = optional。`SessionId`/`WorkspaceId`/`MessageId`/`AttachmentId`/`ApprovalRequestId` 均为 branded string（wire 上就是 string；SessionId/WorkspaceId/MessageId/AttachmentId 要求 `min(1)`）。

### 6.1 session 域（12）

#### session.list
- **payload**: `{ cursor?: string }`（cursor 为 v1 预留席位，未实现）
- **value**: `{ items: SessionSummary[] }`
- `SessionSummary`: `{ sessionId, updatedAt: number(epoch ms), running: boolean, blank: boolean, parentSessionId?: SessionId, origin?: "subagent", cwd?: string, agentPreset?: string, projections?: ProjectionsBlock }`
  - `blank=true` 表示尚无 `turn/start`（只跑过 /plan、改标题等不产生 turn 的操作）。
  - `ProjectionsBlock`（见第 10 节）: `{ asOfSeq: number(int ≥ -1), values: Record<string, unknown> }`

#### session.search
- **payload**: `{ query: string }`（trim 后 1–500 字符，不得含 NUL）
- **value**: `{ items: Array<{ sessionId, snippet: string }>, hasMore: boolean }`（items 上限 `SESSION_SEARCH_RESULT_LIMIT`，snippet 有 Unicode code point 上限）

#### session.create
- **payload**: `{ workspaceId?: WorkspaceId, cwd?: string, sessionId?: SessionId, agentPreset?: string }`
  - 约束：`workspaceId` 与 `cwd` **至多传一个**（refine 校验，同传报 bad-request）。`sessionId` 可指定恢复既有 session。
- **value**: `{ sessionId, agentPreset?: string }`

#### session.history
- **payload**: `{ sessionId, beforeSeq?: number(int ≥ 0), maxMessages?: number(int > 0) }` — 从窗口尾部向前翻页
- **value**: `{ events: HistoryEntry[], hasMore: boolean, projections?: ProjectionsBlock }`（`projections` 只挂在尾部页）
- `HistoryEntry`: `{ event: SessionEvent, view?: ToolEventView }`
  - `SessionEvent`: `{ type: string, seq: int ≥ 0, time: number(epoch ms), data: unknown(按 type 判别, 见第 9 节), sourceEventSeqs?: number[], surfaceOp?: unknown, ignorable?: true }`
  - `ToolEventView`: `{ for: "call" | "result", view: { card: string, ... } }`（host 计算的工具卡片视图，客户端只读不回显）

#### session.models
- **payload**: `{ sessionId }`
- **value**: `{ current: ModelSelection, routable: boolean, groups: ModelProviderGroup[], failures: ModelCatalogFailure[] }`
  - `ModelSelection`: `{ provider: string(min 1), model: string(min 1), reasoningEffort?: string(min 1) }`
  - `ModelProviderGroup`: `{ id, name, models: ModelCatalogModel[] }`；`ModelCatalogModel`: `{ id, name, description?: string, reasoning?: { efforts: Array<{id, name, description?}>(min 1), defaultEffort?: string } }`
  - `ModelCatalogFailure`: `{ id, name, message }`

#### session.selectModel
- **payload**: `{ sessionId, provider: string(min 1), model: string(min 1), reasoningEffort?: string(min 1) }`
- **value**: `{ selected: ModelSelection }`

#### session.rename
- **payload**: `{ sessionId, title: string }`（原始标题，host 侧归一化决定是否接受）
- **value**: `{ title: string(min 1, 归一化后实际接受的标题), seq: int ≥ 0 }`

#### session.fork
- **payload**: `{ sessionId, atSeq?: int ≥ 0 }`（atSeq 锚定已完成 turn 的切点）
- **value**: `{ sessionId }`（子 session id）

#### session.prompt
- **payload**:
```json
{
  "sessionId": "...",
  "mode": "queue | steer",
  "content": [ PromptContentPart ],
  "clientTimeZone": "Asia/Shanghai (可选, IANA 时区)"
}
```
  - `PromptContentPart`（判别联合，wire 上刻意比持久层 ContentBlock 窄）：
    - `{ "type": "text", "text": string }`
    - `{ "type": "image", "mediaType": "image/png|image/jpeg|image/webp|image/gif", "data": string(base64), "name"?: string }`
  - 图片限额由 `imageLimits` 投影下发（见第 10 节）：`maxImageBytes / maxImagesPerMessage / maxMessageImageBytes / maxImagePixels / mediaTypes`。
- **value**: `{ accepted: true, command?: { kind: "success", text?: string } }`（prompt 触发了 slash command 时才带 `command`）

#### session.attachment
- **payload**: `{ sessionId, attachmentId: string(min 1) }`
- **value**: `{ attachment: ImageAttachmentRef, data: string(base64) }`
  - `ImageAttachmentRef`: `{ attachmentId, mediaType(同上四种), bytes: int > 0, width: int > 0, height: int > 0, name?: string }`

#### session.updateQueue
- **payload**: `{ sessionId, itemId: MessageId, action: {kind:"edit", content: ContentBlock[]} | {kind:"remove"} | {kind:"steer"} }`
  - 此处 `ContentBlock` 是宽型 `{ type: string, ... }`（loose object，合并可扩展）。
- **value**: `{ accepted: true }`

#### session.cancel
- **payload**: `{ sessionId }`
- **value**: `{ accepted: true }`

### 6.2 subagent 域（4）

`SubagentListEntry`（判别联合）：
- 一次性子代理：`{ kind:"child", id, mode:"one-shot", activity:"running"|"inactive", hasChildren: boolean, label?: string }`
- 可续聊子代理：`{ kind:"child", id, mode:"continuable", activity:..., hasChildren, label: string }`（label 必填）
- 诊断行：`{ kind:"diagnostic", id, reason: "corrupt"|"unsupported"|"unavailable" }`

| 方法 | payload | value |
|---|---|---|
| subagent.list | `{ parentSessionId }` | `{ entries: SubagentListEntry[], parentAvailable: boolean }` |
| subagent.history | `{ parentSessionId, childSessionId, mode: "one-shot"\|"continuable", beforeSeq?, maxMessages? }` | 同 session.history 的 value |
| subagent.prompt | `{ parentSessionId, childSessionId, mode: "continuable", content: ContentBlock[], clientTimeZone? }` | `{ messageId }` |
| subagent.interrupt | `{ parentSessionId, childSessionId, mode: "continuable" }` | `{ accepted: true }` |

### 6.3 host 域（5）

| 方法 | payload | value |
|---|---|---|
| host.describe | `{}` | `{ version: string, cwd: string, provider?: string, model?: string, attachedSessions: int ≥ 0, canOpenPath: boolean }` |
| host.pickDirectory ⚠️loopback-only | `{}` | `{ path: string \| null }`（null = 用户取消） |
| host.listDirectory | `{ path?: string }`（缺省列 home） | `{ path, home, crumbs: DirectoryEntry[], entries: DirectoryEntry[], truncated: boolean }`；`DirectoryEntry`: `{ name, path, hidden: boolean }` |
| host.createDirectory | `{ path, name }`（name 必须是单个非空路径段：非 `.`/`..`、不含 `/` `\`） | `{ path }`（新建目录绝对路径） |
| host.openPath ⚠️loopback-only | `{ path: string(min 1) }` | `{ opened: true }` |

### 6.4 workspace 域（7）

`WorkspaceView`: `{ workspaceId, path, title, sessionIds: SessionId[], createdAt: string(ISO), updatedAt: string(ISO) }`

| 方法 | payload | value |
|---|---|---|
| workspace.list | `{}` | `{ items: WorkspaceView[], archivedSessionIds: SessionId[] }` |
| workspace.create | `{ path }`（采纳既有目录） | `{ workspace: WorkspaceView, created: boolean }` |
| workspace.rename | `{ workspaceId, title }`（trim 后非空） | `{ workspace }` |
| workspace.delete | `{ workspaceId }` | `{ deleted: true }` |
| workspace.insertBefore | `{ workspaceId, beforeWorkspaceId? }`（锚缺省=移到末尾） | `{ workspaceIds: WorkspaceId[] }`（完整持久顺序） |
| workspace.insertSessionBefore | `{ workspaceId, sessionId, beforeSessionId? }` | `{ workspace }` |
| workspace.archiveSession | `{ sessionId }` | `{ archivedSessionIds: SessionId[] }` |

### 6.5 skill 域（1）

| 方法 | payload | value |
|---|---|---|
| skill.list | `{ sessionId }` | `{ skills: Array<{ name(min 1), description, whenToUse?, modelInvocable: boolean }> }` |

### 6.6 agentPreset 域（6）

`AgentPresetEntry`: `{ id(min 1), trust: "system"|"user", isDefault: boolean, name?, description?, broken?: string(min 1) }`

| 方法 | payload | value | 可达性 |
|---|---|---|---|
| agentPreset.list | `{}` | `{ presets: AgentPresetEntry[], authorable: boolean, hasDocument: boolean }` | trustedHost 可达 |
| agentPreset.select | `{ sessionId, agentPreset(min 1) }` | `{ agentPreset }` | trustedHost 可达 |
| agentPreset.read | `{ agentPreset(min 1) }` | `{ agentPreset, trust, content: string, name?, description? }` | ⚠️loopback-only |
| agentPreset.copy | `{ from(min 1), agentPreset(min 1), name? }` | `{ agentPreset }` | ⚠️loopback-only |
| agentPreset.openDocument | `{ agentPreset(min 1) }` | `{ opened: true }` 或 `{ opened: false, path }` | ⚠️loopback-only |
| agentPreset.remove | `{ agentPreset(min 1) }` | `{}` | ⚠️loopback-only |

### 6.7 goal 域（6）

所有非 clear 变更的 value 都是 `{ ref: GoalRef }`；当前完整 goal 状态只通过 `goal` session 投影下发（见第 10 节）。`GoalRef`: `{ id: string, revision: int > 0 }`（CAS 语义）。

| 方法 | payload | value |
|---|---|---|
| goal.create | `{ sessionId, objective(min 1), maxGoalRounds?: int > 0 }` | `{ ref }` |
| goal.edit | `{ sessionId, ref, objective?, maxGoalRounds? }`（至少传一个） | `{ ref }` |
| goal.pause | `{ sessionId, ref }` | `{ ref }` |
| goal.resume | `{ sessionId, ref }` | `{ ref }` |
| goal.complete | `{ sessionId, ref }` | `{ ref }` |
| goal.clear | `{ sessionId, ref }` | `{ cleared: true }` |

### 6.8 settings 域（5，全部 ⚠️loopback-only）

`SettingsNamespaceView`: `{ ns(min 1), schema: unknown(JSON Schema), value: unknown(脱敏后当前值), base?: unknown, user?: unknown, applies: "live"|"restart", secrets: Array<{ path: string[], set: boolean }>, revision: number }`

| 方法 | payload | value |
|---|---|---|
| settings.describe | `{}` | `{ writable: boolean, hasDocument: boolean, namespaces: SettingsNamespaceView[] }` |
| settings.openDocument | `{}` | `{ opened: true }` |
| settings.update | `{ ns, patch: Record<string, unknown>, expectedRevision?: number }`（合并补丁） | `SettingsNamespaceView` |
| settings.replace | `{ ns, section: Record<string, unknown>, expectedRevision? }`（整节替换） | `SettingsNamespaceView` |
| settings.mutate | `{ ns, ops: Array<{op:"set", path: string[], value} \| {op:"unset", path: string[]}>, expectedRevision? }` | `SettingsNamespaceView` |

`expectedRevision` 为乐观锁，不匹配报 `settings-conflict`。

### 6.9 credentials 域（3，全部 ⚠️loopback-only）

ref 名必须是 POSIX 环境变量名：`/^[A-Za-z_][A-Za-z0-9_]*$/`。

| 方法 | payload | value |
|---|---|---|
| credentials.describe | `{ refs: string[](max 64) }` | `{ credentials: Record<string, { configured: boolean, source?: string, writable: boolean }> }` |
| credentials.set | `{ ref, value: string(min 1) }` | `{}` |
| credentials.unset | `{ ref }` | `{}` |

### 6.10 llm 域（3）

| 方法 | payload | value | 可达性 |
|---|---|---|---|
| llm.providers | `{}` | `{ providers: Array<{ provider(min 1), displayName(min 1), settingsNs, settingsPath: string[], active: boolean, declared?: boolean }> }` | trustedHost 可达 |
| llm.models | `{}` | `{ groups: ModelProviderGroup[], failures: ModelCatalogFailure[] }`（结构同 6.1 session.models） | trustedHost 可达 |
| llm.discoverModels | `{ settingsNs(min 1), provider?, baseURL?, api?, apiKey? }`（apiKey 仅本次探测用，host 不存储不返回） | `{ models: Array<{ id(min 1), name?, contextWindow?: int > 0, maxTokens?: int > 0 }> }` | ⚠️loopback-only |

---

## 7. Remote（Typert）端点

除 52 个 API Proxy 方法外，host 还在同一 `/api` 前缀上暴露一组 **Typert Remote 端点**（由 dsh-api-gateway 的拦截器优先认领，未认领的才落回 API Proxy）。

### 7.1 调用形式

```
POST /api/<namespace>/<method>
{ "type": "client-request", "rpcId": "...", "method": "<namespace>/<method>", "payload": { "args": { ... } } }
```

- 路径段 = `namespace/method`（如 `goals/create`）；body 的 `method` 必须与之相等。
- `payload` 恒为 `{ args: { <wireName>: <value>, ... } }`——**命名参数**，按 descriptor 的 `wire` 名组织。标识类参数（session）以 wire 名 `agentId` 携带（descriptor 里 `source:"lookup"` 的参数，客户端照传 SessionId 字符串即可）。
- 响应仍是标准 ServerResponse 信封；普通业务异常被映射为 `internal` 错误码（空 details），lookup 策略拒绝保留原错误码。
- endpoint 段字符集：`[A-Za-z0-9_$.-]+`。

### 7.2 goals（namespace `goals`，6 个）

每个都以 `agentId`（= SessionId）为 lookup 参数。`GoalRef` = `{ id, revision: number }`。`GoalView` = `{ id, revision, objective, phase: "active"|"paused"|"blocked"|"complete", blockedReason?: { code, message }, maxGoalRounds, roundsStarted, createdAt, updatedAt, activation: "armed"|"disarmed" }`。

| endpoint | args | value |
|---|---|---|
| goals/create | `{ agentId, request: { objective, maxGoalRounds? } }` | `{ ref: GoalRef }` |
| goals/edit | `{ agentId, ref, request: { objective?, maxGoalRounds? } }` | `GoalView` |
| goals/pause | `{ agentId, ref }` | `GoalView` |
| goals/resume | `{ agentId, ref }` | `GoalView` |
| goals/complete | `{ agentId, ref }` | `GoalView` |
| goals/clear | `{ agentId, ref }` | `GoalRef` |

### 7.3 commands（namespace `commands`，2 个）

| endpoint | args | value |
|---|---|---|
| commands/execute | `{ agentId, line: string }` | （command 执行结果；具体形状未在 descriptor 摘要中提取，（未确认）） |
| commands/list | `{ agentId }` | （可用命令清单，（未确认）） |

### 7.4 pluginInventory（namespace `pluginInventory`，1 个）

| endpoint | args | value |
|---|---|---|
| pluginInventory/list | `{}`（无参数） | `{ entries: Array<{ entryId: string, moduleName: string, enabled: boolean, fiberPhase: "failed"\|"pending"\|"active"\|"loading"\|"unloading"\|null }> }` |

### 7.5 dynamicCordisRunner（namespace `dynamicCordisRunner`，5 个）

动态插件（cordis host-runner）支撑面，手机端一般用不到：

| endpoint | args |
|---|---|
| dynamicCordisRunner/getClientCode | `{ agentId, pluginId, pluginRunId }` |
| dynamicCordisRunner/inventory | （无业务参数） |
| dynamicCordisRunner/invoke | `{ pluginId, pluginRunId, method, args }` |
| dynamicCordisRunner/reportClientGuardFailure | `{ agentId, pluginId, pluginRunId, failure }` |
| dynamicCordisRunner/reportRenderFailure | `{ agentId, pluginId, pluginRunId, ... }` |

### 7.6 messageFeedback（namespace `messageFeedback`，3 个）

| endpoint | args |
|---|---|
| messageFeedback/put | `{ request: {...} }` |
| messageFeedback/list | `{ request: {...} }` |
| messageFeedback/delete | `{ request: {...} }` |

（request 内部字段见 `dsh-message-feedback/lib/typert.remote-client.js`，本文未逐字段展开。（未确认））

### 7.7 转发的 host 事件（host/remote-event 帧的 event 名）

Host cordis 事件经 `host/remote-event` 帧原样转发，当前白名单 11 个：

```
agent-preset/selected      commands/change            credentials/updated
cordis/request-run         cordis/request-run-resolved
cordis/dynamic-package     cordis/dynamic-retract
cordis/inspect-query       cordis/inspect-query-resolved
llm/adapters-updated       settings/document-updated
```

payload 为 `args: unknown[]`（事件原参数列表，无投影无脱敏）。

---

## 8. 事件流：帧格式

所有帧均为 downlink ServerRequest 信封的 `payload`，按 `type` 判别。

### 8.1 MuxFrame（/api/events.mux，10 种）

#### session/event —— session 日志事件（主流量）
```json
{
  "type": "session/event",
  "sessionId": "...",
  "event": { "type": "assistant/chunk", "seq": 12, "time": 1750000000000, "data": { } },
  "view": { "for": "call", "view": { "card": "..." } }
}
```
`event` 结构见第 9 节；`view`（可选）仅工具相关事件携带。

#### session/subscribed —— 订阅基线
```json
{ "type": "session/subscribed", "sessionId": "...", "lastSeq": -1 }
```
`lastSeq: int`（可为 -1 = 空日志）。

#### approval/requested —— 工具审批请求（需 /api/respond 应答）
```json
{
  "type": "approval/requested",
  "sessionId": "...",
  "approvalId": "...",
  "toolName": "bash",
  "callId": "...",        // 可选
  "reason": "..."          // 可选
}
```
**信封 rpcId = 该 approval 的稳定 pending id**，应答时回显。

#### approval/resolved
```json
{ "type": "approval/resolved", "sessionId": "...", "approvalId": "...",
  "outcome": "allowed-once | rejected | cancelled | unavailable" }
```

#### question/requested —— ask_user_question（需 /api/respond 应答）
```json
{
  "type": "question/requested",
  "sessionId": "...",
  "questions": [
    {
      "id": "q1",
      "question": "...",
      "header": "...",        // 可选
      "detail": "...",        // 可选
      "options": [{ "label": "...", "description": "..." }],  // 可选
      "multiSelect": false,   // 可选
      "intent": { "kind": "plan-review", "approve": "..." }   // 可选, 判别联合
    }
  ]
}
```
`questions` 数组 min(1)。信封 rpcId = question 的稳定 id。

#### question/resolved
```json
{ "type": "question/resolved", "sessionId": "...", "questionRpcId": "<被应答的 rpcId>",
  "outcome": "answered | cancelled" }
```

#### session/queue —— 待发消息队列快照
```json
{
  "type": "session/queue",
  "sessionId": "...",
  "items": [
    {
      "id": "<MessageId>",
      "placement": "queued | steering | context",
      "message": {
        "id": "...", "role": "system | user | assistant",
        "content": [ { "type": "text", "...": "..." } ],
        "source": { "kind": "user", "...": "..." }
      }
    }
  ]
}
```

#### session/jobs —— 后台任务快照
```json
{
  "type": "session/jobs",
  "sessionId": "...",
  "jobs": [
    { "id": "...", "kind": "...", "label": "...",
      "status": "running | stopping | completed | killed | failed",
      "detail": "...",                    // 可选
      "startedAt": 1750000000000,         // int ≥ 0
      "finishedAt": 1750000001000 }       // 可选
  ]
}
```

#### session/projection —— 投影增量（见第 10 节）
```json
{ "type": "session/projection", "sessionId": "...", "key": "goal",
  "value": { }, "seq": 42 }
```
`value` 为宽槽（各 key 自有 schema），`seq: int ≥ 0`。

#### stream/error —— 流级致命错误
```json
{ "type": "stream/error", "error": { "code": "internal", "message": "...", "details": {} } }
```
官方客户端收到此帧即终止本代连接并重建。

### 8.2 HostFrame（/api/events.host，10 种）

| type | 字段 |
|---|---|
| host/session-added | `{ sessionId, blank: boolean, parentSessionId?, origin?: "subagent", cwd?, agentPreset? }` |
| host/session-removed | `{ sessionId }` |
| host/session-status | `{ sessionId, running: boolean }` |
| host/agent-error | `{ sessionId, message: string }` |
| host/workspace-changed | `{ workspace: WorkspaceView }` |
| host/workspace-removed | `{ workspaceId }` |
| host/workspace-order-changed | `{ workspaceIds: WorkspaceId[] }` |
| host/archived-sessions-changed | `{ archivedSessionIds: SessionId[] }` |
| host/remote-event | `{ event: string(min 1), args: unknown[] }`（白名单见 7.7） |
| stream/error | `{ error: RpcError }`（同上） |

---

## 9. SessionEvent 词汇表

`session/event` 帧与 `session.history` 的 `event` 字段共享此结构：

```json
{
  "type": "<事件类型>",
  "seq": 12,                      // int ≥ 0, session 内单调连续
  "time": 1750000000000,          // epoch ms
  "data": { },                    // 按 type 判别
  "sourceEventSeqs": [3, 4],      // 可选, 仅 surface 事件
  "surfaceOp": "append",          // 可选, 仅 surface 事件: "append" 或 {"op":"replace","start":n,"end":n}
  "ignorable": true               // 可选; 未知类型无此标记时读取方应拒绝重建而非静默丢弃
}
```

### 9.1 核心事件（dsh-session SessionEventMap，13 种）

| type | data |
|---|---|
| turn/start | `{ turn: number }` |
| turn/end | `{ turn, reason: TurnEndReason }` — `{kind:"stop"}`/`{kind:"tool-calls"}`(由 TurnEndReasonMap 决定，（未确认）)/`{kind:"error", error: LlmFailure}`/`{kind:"max-tokens"}`/`{kind:"interrupted"}`(持久层关闭崩溃孤儿 turn 的标记) |
| step/start | `{ turn, step }` |
| step/end | `{ turn, step }` |
| user/message | `UserMessage`（见 9.2）— 真实人类输入 / `agent.inject()` 合成上下文 / goal 续轮，靠 `source.kind` 区分 |
| assistant/chunk | `{ turn, step, chunk: StreamChunk }`（见 9.4，token 级流式增量） |
| assistant/message | `{ turn, step, message: AssistantMessage, usage?: TokenUsage }`（组装完整的一步回复） |
| tool/call | `{ turn, step, callId, name, arguments: string }`（arguments 是模型产出的**未解析 JSON 字符串**） |
| tool/result | `{ turn, step, message: ToolResultMessage, error?: { name, code }, meta?: JsonValue }` |
| todo/write | `{ todos: Array<{ content: string, status: "pending"\|"in_progress"\|"completed" }> }`（全量替换快照） |
| request/header | `{ header: { config, adapterDefaults?, system?, tools? }, reason: "initial"\|"resume"\|"change" }` |
| request/context | `{ provider, model, contextWindow?: number }` |
| session/end-seed | `{}`（构造种子结束标记，空 payload） |

### 9.2 消息结构（dsh-llm）

```
Message = {
  id: string,                            // MessageId
  role: "system" | "user" | "assistant",
  content: ContentBlock[],
  source: MessageSource
}
AssistantMessage: role="assistant", source: ModelMessageSource
ToolResultMessage: role="user", content=[ToolResultBlock](恰好一个), source: ToolMessageSource
```

`MessageSource`（判别联合，kind 可插件扩展）：
- `{ kind: "user" }`
- `{ kind: "plugin", plugin: string, ...ContextFormed }`
- 模型来源 `ModelMessageSource`（AssistantProvenance）
- 工具来源 `ToolMessageSource`

`ContentBlock`（判别联合，可插件扩展）：

| type | 字段 |
|---|---|
| text | `{ type:"text", text: string }` |
| reasoning | `{ type:"reasoning", text: string }`（思考内容，与可见文本分离） |
| image | `{ type:"image", attachment: ImageAttachmentRef }`（持久引用；base64 经 session.attachment 另取） |
| tool-call | `{ type:"tool-call", id: CallId, name, arguments: string }` |
| tool-result | `{ type:"tool-result", toolCallId, content: ContentBlock[], isError?: boolean }` |

### 9.3 TokenUsage / LlmFailure

```
TokenUsage = { inputTokens, outputTokens, cacheReadTokens?, cacheWriteTokens?, reasoningTokens? }
  // 计数互斥：inputTokens 仅未缓存输入；计费输入 = 三者之和
LlmFailure = { message, code, status?, providerRetryAfterMs?, requestId? }
```

### 9.4 StreamChunk（assistant/chunk 的 chunk，流式渲染的核心）

判别联合：

| type | 字段 | 说明 |
|---|---|---|
| block-start | `{ index, blockType: ContentBlockType }` | 开一个新内容块 |
| text-delta | `{ index, text }` | 可见文本增量 |
| reasoning-delta | `{ index, text }` | 思考增量 |
| tool-call-delta | `{ index, id, name?, argumentsDelta: string }` | 工具调用增量（arguments 为 JSON 字符串片段，需自行拼接） |
| block-end | `{ index, block: ContentBlock }` | 块组装完成（携带整块） |
| usage | `{ usage: TokenUsage }` | 在终止 finish 之前发出 |
| finish | `{ reason: FinishReason, replayState?: unknown }` | `reason.kind` ∈ `stop`/`tool-calls`/`max-tokens`/`aborted`/`error`（后两者带 `failure: LlmFailure`） |

`index` 关联交错块的增量。适配器抛错会被归一化为终态 `error`/`aborted` finish，不会裸露异常。

### 9.5 完整已知事件类型清单（本构建 43 种）

核心 13 种 + 插件声明合并的扩展（持久层目录 `KNOWN_SESSION_EVENT_TYPES`）：

```
agent-preset/selected   agent/inbox/spliced    approval/asked        approval/decided
approval/policy         assistant/chunk        assistant/message     command/done
command/run             compaction/end         compaction/prune      compaction/start
compaction/summary      feedback/record        goal/change           hook/invoked
hook/result             llm/retry              llm/retry-started     permission/preset
plan/mode               request/context        request/header        sandbox/mode
schedule/change         session/end-seed       session/title         session/title-llm-request
step/end                step/start             subagent/descriptor   todo/write
tool-workflow/agent-end tool-workflow/agent-start  tool-workflow/run-end  tool-workflow/run-start
tool/call               tool/code-dispatch     tool/code-dispatch-start  tool/result
turn/end                turn/start             user/message
```

（其中 `assistant/chunk` 出现两次是源列表如此，共 44 行去重后 43 种。）扩展事件的 data 形状由所属插件包声明；客户端对未知 type 应**透传存储、按 ignorable 策略处理**（无 ignorable 标记的未知类型在重建 session 时应拒绝，而非静默丢弃）。

---

## 10. Session 投影

投影是 host 从事件日志折叠出的**整值（whole-value）派生状态**，两个下发通道：

1. **基线**：`session.list` 每行的 `projections` 与 `session.history` 尾部页的 `projections`：`{ asOfSeq: int ≥ -1, values: Record<string, unknown> }`
2. **增量**：mux 的 `session/projection` 帧 `{ key, value, seq }`（last-wins，整值替换）

声明合并的已知投影 key：

| key | 值类型 | 来源包 |
|---|---|---|
| `goal` | `GoalProjection \| null`：`{ goal: GoalSnapshot, roundsStarted, createdAt, updatedAt }`；`GoalSnapshot = { id, revision, objective, phase: active\|paused\|blocked\|complete, blockedReason?: {code, message}, maxGoalRounds }` | dsh-goal |
| `title` | `string \| null`（最新 `session/title`） | dsh-session-title |
| `todos` | `TodoItem[] \| null` | dsh-tool-todo |
| `plan` | `PlanProjection`（plan 模式协作状态） | dsh-plan-mode |
| `permissions` | `PermissionSelect`（preset/sandbox/approval 三旋钮折叠值；key 缺省 = 未组合权限服务） | dsh-permission-presets |
| `session-list`（host 侧内部名） | `{ blank: boolean, lastPromptAt: number \| null }` | dsh-host-apiproxy |
| `imageLimits` | `{ maxImageBytes, maxImagesPerMessage, maxMessageImageBytes, maxImagePixels, mediaTypes: string[] }` | dsh-attachment（经 apiproxy 校验） |

（`session-list` / `imageLimits` 的 wire key 名以实际下发为准，（未确认）。）

---

## 11. 错误码全集

`rpcErrorSchema` 判别联合，共 **40 个 code**。`message: string` 与 `details` 恒在；details 按 code 判别：

| code | details |
|---|---|
| bad-request | `{ issues: unknown[] }`（zod issues；信封/payload 校验失败、method 与路径不符） |
| cancelled | `{}` |
| session-not-found | `{ sessionId }` |
| model-unavailable | `{ provider, model }` |
| session-conflict | `{ sessionId, requestedCwd, existingCwd? }` |
| invalid-time-zone | `{ value }` |
| workspace-attach-failed | `{ sessionId, workspaceId }` |
| workspace-not-found | `{ workspaceId }` |
| workspace-invalid-path | `{ path }` |
| workspace-name-conflict | `{ name }` |
| workspace-move-invalid | `{ workspaceId, sessionId, beforeSessionId? }` |
| directory-unreadable | `{ path }` |
| directory-exists | `{ path }` |
| directory-create-failed | `{ path }` |
| directory-picker-unavailable | `{ capability }` |
| agent-preset-read-only | `{ agentPreset, reason }` |
| agent-preset-locked | `{ sessionId, agentPreset }` |
| agent-preset-conflict | `{ sessionId, requestedPreset, existingPreset? }` |
| agent-preset-not-found | `{ agentPreset, available: string[] }` |
| agent-preset-invalid | `{ agentPreset, reason }` |
| agent-busy | `{ reason }` |
| attachment-error | `{ reason }` |
| queue-item-not-found | `{ itemId }` |
| steer-unavailable | `{ itemId }` |
| command-error | `{}` |
| unknown-command | `{}` |
| settings-rejected | `{ ns }` |
| settings-not-exposed | `{ ns }` |
| settings-conflict | `{ ns, expected: number, actual: number }` |
| credential-rejected | `{ ref }` |
| model-discovery-failed | `{ settingsNs, baseURL? }` |
| title-invalid | `{ sessionId }` |
| fork-unavailable | `{ sessionId }` |
| subagent-parent-unavailable | `{ parentSessionId }` |
| subagent-not-found | `{ parentSessionId, childSessionId }` |
| subagent-catalog-diagnostic | `{ parentSessionId, childSessionId, reason: "corrupt"\|"unsupported"\|"unavailable" }` |
| subagent-not-resumable | `{ childSessionId }` |
| subagent-unauthorized | `{ childSessionId }` |
| subagent-delivery-unavailable | `{ childSessionId }` |
| internal | `{}`（实现崩溃、Remote 业务异常的统一映射） |

---

## 12. 辅助端点：session.export 下载

无信封的原始下载通道（GET 或 HEAD）：

```
GET /api/session.export?sessionId=<id>&includeDescendants=true
```

- query 参数全部字符串；`includeDescendants` 只接受字面 `true`/`false`/缺省，其他值 400。
- 响应为文件流（session 日志导出），HEAD 只取头。同样过 trust fence。

---

## 13. 最小连接流程示例

以下是从零到流式收回复的完整消息序列（`→` 客户端发，`←` host 发）：

```
# 0. （LAN 部署前提）Host 头必须为 loopback / LAN IP / trustedHosts 条目

# 1. 就绪握手：host.describe
→ POST /api/host.describe
  { "type": "client-request", "rpcId": "r1", "method": "host.describe", "payload": {} }
← 200 { "type": "server-response", "rpcId": "r1",
        "result": { "ok": true, "value": {
          "version": "0.1.0-rc.6", "cwd": "/Users/me", "provider": "deepseek",
          "model": "deepseek-chat", "attachedSessions": 2, "canOpenPath": true } } }

# 2. 打开两条 downlink（与 1 可并行；ready = 两 socket open + describe 成功）
→ WS Upgrade ws://127.0.0.1:3080/api/events.mux
→ WS Upgrade ws://127.0.0.1:3080/api/events.host

# 3. mux 基线帧（对既有 session）
← { "type": "server-request", "rpcId": "f1", "method": "session/subscribed",
    "payload": { "type": "session/subscribed", "sessionId": "s-existing", "lastSeq": 87 } }

# 4. 创建工作区并创建 session
→ POST /api/workspace.create
  { "type": "client-request", "rpcId": "r2", "method": "workspace.create",
    "payload": { "path": "/Users/me/projects/demo" } }
← 200 { ..., "result": { "ok": true, "value": { "workspace": {
        "workspaceId": "w1", "path": "/Users/me/projects/demo", "title": "demo",
        "sessionIds": [], "createdAt": "...", "updatedAt": "..." }, "created": true } } }
← (events.host) { ..., "payload": { "type": "host/workspace-changed", "workspace": { ... } } }

→ POST /api/session.create
  { "type": "client-request", "rpcId": "r3", "method": "session.create",
    "payload": { "workspaceId": "w1" } }
← 200 { ..., "result": { "ok": true, "value": { "sessionId": "s1" } } }
← (events.mux)  { "payload": { "type": "session/subscribed", "sessionId": "s1", "lastSeq": -1 } }
← (events.host) { "payload": { "type": "host/session-added", "sessionId": "s1", "blank": true, ... } }

# 5. 发送 prompt
→ POST /api/session.prompt
  { "type": "client-request", "rpcId": "r4", "method": "session.prompt",
    "payload": { "sessionId": "s1", "mode": "queue",
                 "content": [{ "type": "text", "text": "你好，写个 hello world" }],
                 "clientTimeZone": "Asia/Shanghai" } }
← 200 { ..., "result": { "ok": true, "value": { "accepted": true } } }

# 6. mux 流式事件（典型序列）
← session/event: { type:"turn/start",        seq:0, data:{ turn:1 } }
← session/event: { type:"user/message",      seq:1, data:{ id, role:"user", content:[...], source:{kind:"user"} }, surfaceOp:"append" }
← session/event: { type:"step/start",        seq:2, data:{ turn:1, step:1 } }
← session/event: { type:"request/header",    seq:3, data:{ header:{...}, reason:"initial" } }
← session/event: { type:"assistant/chunk",   seq:4, data:{ turn:1, step:1, chunk:{ type:"block-start", index:0, blockType:"text" } } }
← session/event: { type:"assistant/chunk",   seq:5, data:{ turn:1, step:1, chunk:{ type:"text-delta", index:0, text:"好的" } } }
← session/event: { type:"assistant/chunk",   seq:6, data:{ turn:1, step:1, chunk:{ type:"text-delta", index:0, text:"，这是" } } }
   ... (更多 text-delta)
← session/event: { type:"assistant/chunk",   seq:N, data:{ turn:1, step:1, chunk:{ type:"block-end", index:0, block:{ type:"text", text:"好的，这是..." } } } }
← session/event: { type:"assistant/chunk",   seq:N+1, data:{ turn:1, step:1, chunk:{ type:"usage", usage:{ inputTokens: 812, outputTokens: 96 } } } }
← session/event: { type:"assistant/chunk",   seq:N+2, data:{ turn:1, step:1, chunk:{ type:"finish", reason:{ kind:"stop" } } } }
← session/event: { type:"assistant/message", seq:N+3, data:{ turn:1, step:1, message:{ id, role:"assistant", content:[{type:"text",text:"..."}], source:{...} }, usage:{...} }, surfaceOp:"append" }
← session/event: { type:"step/end",          seq:N+4, data:{ turn:1, step:1 } }
← session/event: { type:"turn/end",          seq:N+5, data:{ turn:1, reason:{ kind:"stop" } } }
← (events.host) { "payload": { "type": "host/session-status", "sessionId": "s1", "running": false } }
← (可能还有) session/projection { key:"title", value:"hello world 示例", seq:N+6 }

# 7. （若 agent 提问）question 应答
← { "type": "server-request", "rpcId": "q-stable-id", "method": "question/requested",
    "payload": { "type": "question/requested", "sessionId": "s1",
                 "questions": [{ "id": "q1", "question": "选哪个方案？",
                                 "options": [{ "label": "A" }, { "label": "B" }] }] } }
→ POST /api/respond
  { "type": "client-response", "rpcId": "q-stable-id",
    "result": { "ok": true, "value": { "sessionId": "s1",
                "answer": { "answers": [{ "id": "q1", "selected": ["A"] }] } } } }
← 200 { "accepted": true }
← (events.mux) { "payload": { "type": "question/resolved", "sessionId": "s1",
                 "questionRpcId": "q-stable-id", "outcome": "answered" } }
```

断线恢复：任一 WS 断开 → 关闭另一条 → 退避（0.5 s 起、×2、封顶 10 s、±50% jitter）→ 重开两条 socket + 重调 host.describe → 用 `session/subscribed.lastSeq` 与本地 seq 对比，缺口部分调 `session.history` 补齐。

---

## 14. Flutter 实现注意点

1. **业务错误不走高危 HTTP 码**：所有方法（包括失败）都返回 HTTP 200 + 信封；必须把「HTTP 层错误（403/404/415/400/426/500）」与「`result.ok=false` 业务错误（40 个 code）」分成两条处理链。403 特指 trust fence 拒绝——先检查 Host 头与部署配置，不要当成认证失败重试。
2. **downlink 只有 WebSocket，没有 SSE 回退**：普通 GET `/api/events.*` 拿 426。用 Dart `WebSocketChannel`，按文本帧 `jsonDecode` → 先校验 `{type:"server-request", rpcId, method, payload}` 信封，再按流分发 `muxFrameSchema`/`hostFrameSchema` 判别联合；单帧解析失败必须**跳过而不是断流**（官方客户端如此），靠 seq 缺口检测重拉 `session.history` 兜底。
3. **LAN 部署的 fence 三要素**：手机无 Origin 头，只需 Host 头过关——推荐把 webserver 绑 `0.0.0.0`（cordis.yml，CLI 故意拒绝 `--host 0.0.0.0`）让 LAN IP 字面量自动入信任表，或 `--trusted-host`；**15 个特权方法（settings/credentials/llm.discoverModels/host.openPath 等）对非 loopback 永远 403**，手机端 UI 应直接隐藏这些入口。全程明文 HTTP + 无认证层，不要暴露到公网。
4. **流式渲染拼 `assistant/chunk` 而非 `assistant/message`**：chunk 用 `index` 关联块、`text-delta`/`reasoning-delta` 增量追加、`tool-call-delta.argumentsDelta` 是 JSON 字符串片段需自行拼接、`block-end` 携带整块可校正；`usage` 先于 `finish`；`assistant/message` 是终态整消息（含 usage），history 翻页用它。所有历史/流事件共享 `{type, seq, time, data}` 信封，43 种已知 type，未知 type 要透传并按 `ignorable` 策略处理。
5. **question/approval 是带稳定 rpcId 的双向交互**：这两类 `*/requested` 帧的信封 rpcId 是 pending 表里的稳定 id（重连会重放），应答走 `POST /api/respond`（client-response 信封回显该 rpcId，receipt 只有 `{accepted}`）；其余帧的 rpcId 每帧随机、仅作日志关联。同理，`settings.*` 的 `expectedRevision`、`goal.*` 的 `GoalRef{id, revision}` 都是 CAS 乐观锁，UI 必须先读最新值再提交。
