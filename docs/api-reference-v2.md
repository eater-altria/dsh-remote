# DeepSeek Harness (dsh) 0.1.2-alpha 新协议参考（v2）

> 面向 dsh-remote App 迁移的新版 client↔host 协议参考。
> 提取自 dsh 安装产物 `/usr/local/lib/node_modules/@deepseek-ai/dsh/`（版本 `0.1.2-alpha.3`），
> 主要源码依据：`dsh-client-connection/lib/index.js`（host 端 fence+鉴权）、
> `dsh-client-connection/lib/client.js`（官方客户端 RPC 实现）、
> `dsh-api-gateway/lib/index.js`（remote.mux 服务端）与 `lib/client.js`（官方 mux 客户端）、
> `dsh-api-session-controller` / `dsh-api-workspace-controller` 的 `typert.host.js`（端点与类型金标准）、
> `dsh-api-remotes/lib/index.js`（转发事件白名单）。
>
> 旧版（0.1.0-rc.x，点式 RPC + events.mux/events.host）见 `api-reference.md`；
> 旧协议在 0.1.2-alpha.2 起被移除，无兼容层。

---

## 0. 新旧对照总览

| 维度 | 旧协议（≤0.1.1-rc.2） | 新协议（≥0.1.2-alpha.2） |
|---|---|---|
| 鉴权 | 仅 Host header trust fence | fence + browser-session cookie（见 api-reference.md 第 2 节，relay 已处理） |
| Unary RPC | `POST /api/<dot.method>`，payload 直接是参数 | `POST /api/<ns>/<method>`，`payload = {args: {...}}` |
| 响应信封 | `server-response` + `result.ok/value/error` | **相同** |
| 事件下行 | 两条被动 WS：`events.mux`（会话）+ `events.host`（全局） | 一条多路复用 WS：`remote.mux`，客户端发「开流」帧创建逻辑流 |
| 会话历史 | `session.history` 分页拉取 | `session/follow` 流（开头 snapshot + 无缝实时事件）+ `session/page` 翻旧页 |
| 队列/jobs/投影 | mux 帧 `session/queue|jobs|projection` | `session/control` 流（baseline + 替换帧） |
| 工作区 roster | `workspace.list` + host 帧刷新 | `workspace/follow` 流（baseline + 增量） |
| 审批/提问 | mux 帧 + `POST /api/respond` | `$events` 流 waterfall 帧 + `$events/result` unary 应答 |

## 1. Unary RPC

### 1.1 信封（与旧版几乎相同，仅两处差异）

```json
// 请求 POST /api/<ns>/<method>
{ "type": "client-request", "rpcId": "<uuid>", "method": "<ns>/<method>",
  "payload": { "args": { /* 端点参数 */ } } }
// 响应
{ "type": "server-response", "rpcId": "<回显>",
  "result": { "ok": true, "value": ... } }
// 或 { "ok": false, "error": { "code": "...", "message": "...", "details": {} } }
```

- 差异 1：`method` 必须与 URL 路径端点完全一致（`ns/method` 形式），否则 `gateway/bad-request`。
- 差异 2：typert Remote 端点的 `payload` 必须是**恰好一个 `args` 键**的 plain object，
  且 `args` 也是 plain object，否则报 `Remote payload must contain exactly one plain-object args field`。
- **args 的键 = Remote 方法声明的参数名**（不含 `signal`）。绝大多数方法签名是
  `method(request: XxxRequest, signal)`，所以 args 要再包一层 `request`：
  `{"args": {"request": {...}}}`（漏包会报 `gateway/arguments-invalid: missing "request"`）。
  少数方法按值参（如 `fileReferences/list(agent, query)`）则 args 直接是 `{agent, query}`。
  无参方法（`session/control`、`workspace/follow`、`$events`、`session/modelCatalog`）用 `{"args":{}}`。
- HTTP 错误：404 未知端点 / 415 非 JSON / 400 非 JSON body / 401 未认证 / 403 fence 拒绝。业务错误一律 200 + error 分支。

### 1.2 旧点式名 → 新端点映射（实测）

| 旧名 | 新端点 | 说明 |
|---|---|---|
| host.describe | **不存在** | 就绪握手改为 `$events` 流 ready 帧；活性探测用 `session/modelCatalog` |
| workspace.list | **无 unary** | 用 WS `workspace/follow` baseline |
| session.list | `session/list` | **args 键名是 `_request`**（全 API 唯一例外） |
| session.history | `session/page` | 需先经 follow 快照拿 cursor 作 throughSeq |
| session.prompt | `session/prompt` | 客户端铸造 requestId |
| session.cancel | `session/cancel` | |
| session.create | `session/create` | |
| session.rename | `session/rename` | |
| workspace.archiveSession | `workspace/archiveSession` | |
| session.search | `session/search` | |
| session.updateQueue | `session/updateQueue` | |
| session.models | `session/modelCatalog` | 注意改名 |
| session.selectModel | `session/selectModel` | |
| skill.list | `skills/list` | 复数 ns |
| subagent.list | `subagents/list` | 复数 ns |
| subagent.prompt | `subagents/prompt` | |
| subagent.interrupt | `subagents/interruptByParent` | 改名 |
| goal.* | `goals/create\|edit\|pause\|resume\|complete\|clear` | args: `{agentId, ref?, request?}` |
| agentPreset.list | `agentPresets/list` | |
| settings.describe | `settings/describe` | |
| settings.update | `settings/update` | `{ns, patch, expectedRevision?}` |
| session.attachment | `session/attachment` | |
| host.listDirectory | `directoryPicker/list` | 需 browse capability；本机部署为 native → `directory-picker/unavailable`（relay 的 `/__relay/listDir` 不受影响） |

### 1.3 session 命名空间

| 端点 | args | value |
|---|---|---|
| `session/list` | `{_request: {cursor?: string}}` | `{items: SessionSummary[]}`；SessionSummary = `{sessionId, updatedAt, running, blank, parentSessionId?, origin?, cwd?, projections?:{asOfSeq, values}}` |
| `session/search` | `{request:{query}}` | `{items:[{sessionId,snippet}], hasMore}` |
| `session/create` | `{request:{workspaceId?, cwd?, sessionId?, agentPreset?}}` | `{sessionId, agentPreset?}` |
| `session/rename` | `{request:{sessionId, title}}` | `{title, seq}` |
| `session/fork` | `{request:{sessionId, atSeq?}}` | `{sessionId}` |
| `session/prompt` | `{request:{requestId, sessionId, mode:'queue'\|'steer', content:PromptContentPart[], clientTimeZone?}}` | `{accepted:true}`；PromptContentPart = `{type:'text',text}` \| `{type:'image',mediaType,data,name?}` |
| `session/cancel` | `{request:{sessionId}}` | `{accepted:true}` |
| `session/updateQueue` | `{request:{sessionId, itemId, action:{kind:'edit',content}\|{kind:'remove'}\|{kind:'steer'}}}` | `{accepted:true}` |
| `session/selectModel` | `{request:{sessionId, provider, model, reasoningEffort?}}` | `{selected:{...}}` |
| `session/modelCatalog` | `{}` | `{default, routableProviders[], groups:[{id,name,models:[{id,name,description?,reasoning?}]}], failures:[...]}` |
| `session/attachment` | `{request:{sessionId, attachmentId}}` | `{attachment:{...}, data:base64}` |
| `session/page` | `{request:{address, throughSeq, beforeSeq?, maxMessages?(默认50)}}` | `{records, hasMore}`；records 升序；向上翻页传本页首 seq 作 beforeSeq |
| `session/canOpenWorkspacePath` | `{}` | `boolean` |

### 1.4 其他命名空间

- **workspace**：`create {request:{path}}`、`rename {request:{workspaceId,title}}`、`delete {request:{workspaceId}}`、`archiveSession {request:{sessionId}}`（注意：无 archived 布尔参数，就是归档）、`insertBefore`、`insertSessionBefore`。
- **skills**：`skills/list {request:{sessionId}}` → `{skills:[{name,description,whenToUse?,modelInvocable}]}`。
- **subagents**：`list {parentSessionId}` → `{entries, parentAvailable}`；`prompt {request:{requestId,parentSessionId,childSessionId,mode:'continuable',content,clientTimeZone?}}`；`interruptByParent {childSessionId, parentSessionId, mode:'continuable'}`。
- **goals**：`create {agentId, request:{objective,maxGoalRounds?}}`、`edit {agentId, ref, request}`、`pause|resume|complete {agentId, ref}`、`clear {agentId, ref}`；GoalView = `{id,revision,objective,phase,blockedReason?,maxGoalRounds,roundsStarted,createdAt,updatedAt,activation}`。
- **agentPresets**：`list {}` → `{presets:[{id,trust,isDefault,name?,description?,broken?}], authorable}`；`select {agentId, agentPreset}`。
- **settings**：`describe {}` → `{writable, hasDocument, namespaces:[{ns, schema, value, applies, secrets, revision}]}`；`update {ns, patch, expectedRevision?}` → 更新后 NamespaceView。
- **commands**：`list {agentId}` → `[{name,description,input?}]`；`execute {agentId, line, images}` → `{commandId,result} | undefined`。
- **messageFeedback**：`list/put/delete {request:{...}}` —— **双层结果**：`result.value = {ok:true,value} | {ok:false,error}`，要解两层 ok。
- **fileReferences**：`list {agentId, query}` → `[{path, kind}]`（输入框路径补全）。
- **directoryPicker**：`list {path?}` → `{path, home, crumbs, entries, truncated}`（本机 native-only，不可用）。

## 2. remote.mux 多路复用 WebSocket

**一条物理 WS**（`GET /api/remote.mux`，Upgrade）承载多条逻辑流。与旧版被动下行
**根本不同**：客户端必须主动发「开流」帧。

### 2.1 客户端 → host 帧

```json
// 开流（payload 与 unary 相同，{args:{...}}；无参流用 {args:{}}）
{ "type": "open", "streamId": "<uuid>", "endpoint": "<ns>/<method>", "payload": { "args": { } } }
// 取消一条逻辑流
{ "type": "cancel", "streamId": "<uuid>" }
```

### 2.2 host → 客户端帧

```json
{ "type": "item",  "streamId": "...", "value": /* 流元素 */ }
{ "type": "end",   "streamId": "..." }              // 流正常结束
{ "type": "error", "streamId": "...", "error": { "code", "message", "details" } }
```

- **严格 exact-keys 校验**：open 帧多一个字段即整连接 close 1008；streamId 重复同样 1008。
- 心跳：host 每 **2s** 发 WS Ping，连续 2 次未 Pong 即 terminate；dart:io 的
  WebSocket 在协议层自动回 Pong，无需处理。
- 物理 socket 断开 = 所有逻辑流失败 → 连接代重建（与旧版语义一致）。
- 断线重建后需要**重新开所有流**；`session/follow` 支持从已知游标恢复。

## 3. $events 流（全局事件 + 审批/提问）

endpoint = `$events`，payload `{args:{}}`。这是旧版 `events.host` + 审批/提问通道的合体。

### 3.1 帧序列

```json
// 第一个 item 必是 ready（连接就绪标志 + host 事实）
{ "type": "ready", "clientId": "<本代客户端 id>", "host": { "home": "/Users/..." } }
// 通知（无需应答）
{ "type": "emit", "event": "api-session/added", "args": [ ... ] }
// 请求-应答（审批/提问，必须应答）
{ "type": "waterfall", "event": "approval/request", "eventId": "<id>",
  "agentId": "<session id>", "request": { ... } }
// host 侧取消一个 pending 请求
{ "type": "cancel", "eventId": "<id>" }
```

### 3.2 emit 事件白名单（dsh-api-remotes）

`agent-preset/selected`、`api-session/activity`、`api-session/added`、`api-session/error`、
`api-session/removed`、`api-session/status`、`commands/change`、`credentials/reference-updated`、
`cordis/*`、`llm/adapters-updated`、`settings/document-updated`。

emit 的 args（位置参数数组）：`api-session/added(summary)`（summary 与 session/list
item 同形）、`api-session/removed(sessionId)`、`api-session/status(sessionId, running)`、
`api-session/activity(sessionId, time)`、`api-session/error(sessionId, message)`。

roster 刷新时机：`api-session/added|removed|status` + `workspace/follow` 增量。

### 3.3 waterfall 应答（unary `$events/result`）

```json
// POST /api/$events/result
{ "type": "client-request", "rpcId": "...", "method": "$events/result",
  "payload": { "args": {
    "clientId": "<ready 帧给的 id>",
    "eventId": "<waterfall 帧的 eventId>",
    "outcome": { "kind": "result", "value": <应答值> }
  } } }
```

outcome 另有 `{kind:'next'}`（让给下一个监听者）与 `{kind:'rejected', error:{...}}`。

### 3.4 审批（approval/request）

request：`{ "toolName": "bash", "callId"?: "...", "reason"?: "..." }`
应答 value：`'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'`（同旧版词汇）。

### 3.5 提问（user-questions/request）

request：`{ "questions": [ {id, question, header?, options?:[{label,description?}], multiSelect?, intent?} ] }`
应答 value：`{"answers": [{"id", "selected": ["<label>", ...], "custom"?}]}`；
中止用 `outcome: {kind:'rejected', error:{name:'UserQuestionError', code:'ASK_ABORTED'}}`。

**waterfall 语义**：host 把请求投递给所有活跃 $events 客户端，每个都必须回一帧
result——`next` 让位，任一 `result`/`rejected` 定案；被投递过的客户端事后都会收到
`cancel` 帧（别处定案或撤销）。断线重连（新 clientId）后 pending 请求会**重新投递**。

## 4. session/follow 流（会话日志：历史 + 实时事件合体）

endpoint = `session/follow`，args：

```json
{ "address": { "kind": "session", "sessionId": "..." }
           | { "kind": "subagent", "parentSessionId": "...", "childSessionId": "...", "mode": "one-shot|continuable" },
  "maxMessages": 60 }
```

### 4.1 帧

```ts
// 第一帧必是 snapshot：会话头 + 最近一页历史 + 续传游标
{ type: 'snapshot', header: SessionHeader, cursor: number,
  records: SessionHistoryRecord[], hasMore: boolean,
  projections: SessionProjectionBaseline }
// 之后是无缝实时事件
{ type: 'event', event: SessionWireEvent }
```

- `SessionWireEvent = { type: string, seq: number, time: number, data: any, ignorable?: true, sourceEventSeqs?: number[], surfaceOp?: SurfaceOp }` —— 与旧版 SessionEvent **同构**。
- `SessionHistoryRecord = SessionEventEntry | SessionChunkRun`，
  `SessionChunkRun = { type:'chunks', event: ChunkRowEvent }`（压缩的 chunk 行，客户端可展开或跳过）。
- `hasMore: true` → 用 `session/page` unary 向更老的方向翻页。
- seq 连续无缺口（服务端保证 gap-free）；**没有 sinceSeq 参数**——断线续传 = 重开流，
  用新 snapshot 的 cursor 与本地已见 seq 对齐去重。
- 直播帧事件可带 `ignorable: true`（可安全丢弃）与 `surfaceOp: 'append' | {op:'replace',start,end}`
  （表面替换语义，取代旧版的 `view` 字段）。
- records 中 `{type:'chunks'}` 的 chunkrow 压缩行（≥3 个连续同块 delta）：
  text/reasoning → `data:{texts:[], turn, step, index, dt:[]}`；tool-call →
  `data:{id, name?, args:[], turn, step, index, dt:[]}`；第 i 个事件 seq=seq0+i、
  time=time0+前缀和(dt)。客户端可跳过（最终内容由 assistant/message 携带）或按规则展开。

### 4.2 事件词汇表（SessionEventMap，与旧版基本一致）

`turn/start`、`turn/end`、`step/start`、`step/end`、`user/message`、
`assistant/chunk`（data: `{turn, step, chunk: StreamChunk}`，StreamChunk =
`block-start|text-delta|reasoning-delta|tool-call-delta|block-end|usage|finish`，与旧版相同）、
`assistant/message`、`tool/call`、`tool/result`、`approval/asked`、`approval/decided`、
`approval/policy`、`session/title`、`command/run`、`command/done`、`compaction/summary`、
`goal/change`、`todo/write`、`model/selection`、`agent-preset/selected`、`subagent/descriptor` 等。

**tool/call 与 tool/result 的真实 data 形状（dsh ≥0.1.7 实测）**：
- `tool/call` data = `{turn, step, callId, name, arguments(JSON 字符串)}`。
- `tool/result` data = `{turn, step, message, sourceEventSeqs, surfaceOp}`，其中
  `message = {role:'tool', toolCallId, source:{kind:'tool', callId},
  content:[{type:'text', text}], isError, id}` —— 配对键在 `message.toolCallId`
  （或 `message.source.callId`），**不再**是 content 里的 `tool-result` 块
  （更旧的 host 用后者，客户端需两种都兼容）。

## 5. session/control 流（队列 + jobs + 投影）

endpoint = `session/control`，payload `{args:{}}`。

```ts
// 第一帧 baseline：全量快照
{ type: 'baseline', value: { queues: Record<sid, SessionQueuedItem[]>,
                             jobs: Record<sid, SessionJob[]>,
                             projections: Record<sid, SessionProjectionBaseline> } }
// 之后是替换帧（对应旧版 session/queue、session/jobs、session/projection）
{ type: 'queue', sessionId, items: SessionQueuedItem[] }
{ type: 'jobs', sessionId, jobs: SessionJob[] }
{ type: 'projection', ...SessionProjectionUpdate }
```

`SessionQueuedItem = { id, placement: 'queued'|'steering'|'context', rpcId?, message: {id, content} }`
`Job = { id, kind, label, status: 'running'|'stopping'|'completed'|'killed'|'failed', detail?, startedAt, finishedAt? }`

projection values 常见键：`title`、`todos`、`agentPreset`、`modelSelection{lastUsed,next}`、
`imageLimits`、`permissions`、`tokenUsage`、`contextPressure`、`contextBreakdown`、
`sessionStats`、`turnOutline`、`subagentTiming` 等（开放 record 允许扩展）。
**goal 投影**：`values.goal = {goal:{id,revision,objective,phase:'active'|'paused'|'blocked'|'complete',
blockedReason?:{code,message},maxGoalRounds}, roundsStarted, createdAt, updatedAt} | null`。
**permissions 投影**（dsh ≥0.1.7）：`values.permissions = {currentValue}` —— 只剩当前值；
可选项迁到进程级 unary `permissionPresets/catalog`（无参），返回
`{options: [{value,name,description?}], defaultOptions, defaultPreset}`。投影键缺失 =
host 未组合权限服务，客户端应隐藏切换入口。切换仍走 `/permission <preset>` 命令。

## 6. workspace/follow 流（工作区 roster）

endpoint = `workspace/follow`，payload `{args:{}}`。

```ts
// 第一帧 baseline
{ type: 'baseline', value: { items: WorkspaceView[], archivedSessionIds: SessionId[] } }
// 增量
{ type: 'upsert', workspace: WorkspaceView }
{ type: 'remove', workspaceId }
{ type: 'order', workspaceIds: WorkspaceId[] }
{ type: 'archived', archivedSessionIds: SessionId[] }
```

`WorkspaceView = { workspaceId, path, title, sessionIds[], createdAt, updatedAt }` —— 与旧版
`workspace.list` 行同构（多了 createdAt/updatedAt）。

## 7. 连接就绪握手（新版）

旧版：两条 WS open + `host.describe` 成功。
新版（与官方 Web 客户端同构）：
1. remote.mux socket open；
2. 开 `$events` 流，收到 ready 帧 → 记录 clientId / host.home → **就绪**；
3. 再开 `workspace/follow`、`session/control`（baseline 即全量，重连用新 baseline 整体替换）；
4. 每打开一个会话开一条 `session/follow`（snapshot 建窗，缺页用 session/page 补）。

## 8. session/page（历史翻页）

```ts
// args: {request: {address: SessionAddress, throughSeq: number, beforeSeq?: number, maxMessages?: number}}
// value: { records: SessionHistoryRecord[], hasMore: boolean }
```

配合 `session/follow` 的 snapshot：snapshot.hasMore 时用 snapshot 里最老 seq 作为
beforeSeq 向前翻页。records 中 `{type:'chunks'}` 的压缩 chunk 行可跳过
（最终内容由 assistant/message 携带，与旧版 slim history 丢 assistant/chunk 同理）。
