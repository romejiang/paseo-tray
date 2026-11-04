# 架构

## 1. 为什么托盘不能是 Paseo 插件

Paseo 插件只有两个运行时：

- `index.server.ts`：daemon 拉起的 Node 子进程，只有 Node 能力，没有 Electron、AppKit、`NSStatusItem`。
- `index.client.tsx`：跑在 Paseo 渲染进程里的 React Native 组件，只能往 Paseo 窗口里画 UI。

SDK 没有 Tray、系统通知、Electron 主进程 API。`window.paseoDesktop` 这类桥不是公开契约，不能用。

所以只有三条路：

| 方案 | 做法 | 结论 |
| --- | --- | --- |
| A | 独立 Swift 菜单栏 App + 薄插件 | 采用。不动 Paseo 安装包，升级 Paseo 不受影响 |
| B | 改 `packages/desktop`，Electron 主进程加 `Tray` | 需要自己构建并长期维护 Paseo 分支，不做 |
| C | 只写插件 | 不是真托盘，不满足需求，不做 |

## 2. 两条数据通道

```
                    Paseo daemon (127.0.0.1:6767)
                    │
        ┌───────────┴────────────┐
        │                        │
  WebSocket                  Paseo app
  ws://host:port/ws          (Electron renderer)
        │                        │
  PaseoTray.app            paseo-tray plugin
  (Swift/AppKit)           (index.client.tsx)
        │                        │
  NSStatusItem + NSMenu    SidebarRow / Screen / Settings
        │                        │
        └───────────┬────────────┘
                    │
        ~/Library/Application Support/PaseoTray/config.json
        (plugin 原子写，tray 监听目录)
```

托盘不经过 Paseo app，也不经过插件；它直接连 daemon。插件被禁用时托盘继续工作。

## 3. daemon 协议

### 3.1 发现 daemon

优先级：

1. `PASEO_HOME` 环境变量；默认 `~/.paseo`。
2. `$PASEO_HOME/paseo.pid` 的 `listen` 和 `serverId`。
3. 没有 `listen` 时回退 `$PASEO_HOME/config.json` 的 `daemon.listen`。

`paseo.pid` 示例：

```json
{
  "pid": 29261,
  "listen": "127.0.0.1:6767",
  "serverId": "srv_example",
  "desktopManaged": true,
  "heartbeat": true
}
```

v1 只接受 `host:port`（包括 `[::1]:6767`）。`unix://`、`pipe://`、`/path` 显示“不支持”。
daemon 不在时每 2 秒重读 `paseo.pid`；不要在代码里硬编码 6767。

### 3.2 鉴权

读 `$PASEO_HOME/local-credential`（单行 token），放在：

```json
{"kind":"localCredential","token":"..."}
```

token 只出现在 hello 帧里，不写日志、不写配置、不拼 URL。文件缺失时 hello 不带 auth；daemon 返回 `hello.rejected` 后显示“需要密码”，30 秒后重试。

### 3.3 帧格式

- hello 是裸帧：`{"type":"hello", ...}`
- 其他请求包一层：`{"type":"session","message":{...}}`
- 业务响应同样是 `{"type":"session","message":{...}}`
- `server_info` 实际是：

```json
{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"...","version":"0.14.0"}}}
```

托盘同时兼容裸 `{"type":"status","payload":{...}}`。
- 心跳：发 `{"type":"ping"}`，收 `{"type":"pong"}`，30 秒一次；90 秒无消息主动重连。

hello：

```json
{
  "type": "hello",
  "clientId": "paseo-tray-<stable-uuid>",
  "clientType": "cli",
  "protocolVersion": 1,
  "appVersion": "0.1.0",
  "auth": {"kind":"localCredential","token":"..."},
  "capabilities": {
    "owned_subscriptions": true,
    "explicit_event_subscriptions": true,
    "hello_rejection": true
  }
}
```

`clientId` 用 `UserDefaults` 持久化。`clientType` 是 `cli`，不伪装 browser/mobile。

### 3.4 agent 目录订阅

发送：

```json
{
  "type": "session",
  "message": {
    "type": "fetch_agents_request",
    "requestId": "agents-...",
    "scope": "active",
    "filter": {"includeArchived": false, "includeBackground": false},
    "page": {"limit": 200},
    "subscribe": {}
  }
}
```

收到一次全量 `fetch_agents_response`，随后是 `agent_update`：

```json
{"kind":"upsert","agent":{...}}
{"kind":"remove","agentId":"..."}
```

`pageInfo.hasMore` 为 true 时菜单显示“只显示前 200 个”。重连后重新发订阅，不复用旧 `subscriptionId`。

订阅有独立的 ack 和重试：

- agents 和 events 各有一个 8 秒超时。
- `fetch_agents_response` 算 agents ack；`session.events.set_subscription.response` 或首次 `agent_attention_required` 算 events ack。
- 首次超时或 `rpc_error`（`payload.requestId` 匹配当前请求）只重发一次，使用新 requestId，并把错误写进 `subscriptionError`。
- 第二次仍失败才 `handleDisconnect`，走完整重连。
- 快照/事件 ack 后分别重置自己的订阅重试计数。
- **指数退避只在 agents 和 events 都 ack 后重置**；`server_info` 本身不重置。这样 daemon 接受连接但持续拒绝订阅时，重连间隔会按 1s → 2s → 5s → 10s → 30s 增长，而不是每秒抖动。

### 3.5 完成/权限/错误事件

```json
{
  "type": "session",
  "message": {
    "type": "session.events.set_subscription.request",
    "requestId": "events-...",
    "events": ["agent_attention_required"],
    "notifications": true
  }
}
```

事件：

```json
{
  "type": "session",
  "message": {
    "type": "agent_attention_required",
    "payload": {
      "agentId": "...",
      "reason": "finished",
      "timestamp": "2026-11-05T...",
      "shouldNotify": false,
      "notification": {...}
    }
  }
}
```

`reason` 只有 `finished` / `error` / `permission`。
**不依赖 `shouldNotify`**：它是 daemon 按前台客户端定向投放的，托盘通常拿到 false。托盘用自己的判断：Paseo 在前台就静默。
事件不重放；启动时不补发历史通知。去重键 `agentId + reason + timestamp`。

### 3.6 状态归一化

与 `packages/protocol/src/agent-state-bucket.ts` 一致：

```ts
if (pendingPermissions?.length > 0 || attentionReason === "permission") return "needs_input";
if (status === "error" || attentionReason === "error") return "failed";
if (status === "running") return "running";
if (requiresAttention) return "attention";
return "done";
```

过滤：

- `background === true` 不计入。
- `internal === true` 不计入。
- `labels["paseo.parent-agent-id"]` 非空默认不计入，`includeSubagents` 打开后计入。
- `archivedAt` 非空不计入。
- `done` 桶不显示、不计数（普通 idle 不是“已完成”）。

`attention` 桶在本项目里等价于“finished，但用户还没看”。用户打开 agent 后 daemon 会清掉 `requiresAttention`，托盘计数随之减少。

事件和快照的顺序不保证。`agent_attention_required` 先到、对应 agent 还不在快照里时，`AgentStore` 会把 `(reason, timestamp, receivedAt)` 放进 `pendingAttention`；下一次 `agent_update` upsert 或全量快照合并后移除。pending 上限 100 条、5 分钟过期，避免无限增长。

## 4. 托盘状态机

```
offline ──发现 pid──> connecting ──server_info──> connected
   ↑                       │                         │
   └──── 1/2/5/10/30s ─────┘                         │
   ↑                                                 │
   └──────────── 断线 / 90s 无消息 / 发送失败 ────────┘
```

- 指数退避：1 → 2 → 5 → 10 → 30 秒。
- 鉴权失败/协议不兼容：30 秒固定重试，不无限快速重试。
- 连接成功但 8 秒内没有 `fetch_agents_response`：保留连接，标记“订阅失败/订阅超时”，菜单显示提示。
- 每次重连前重读 `paseo.pid`，所以 daemon 换端口也能恢复。
- 系统唤醒（`NSWorkspace.didWakeNotification`）立即重连。

## 5. 配置共享

插件 server 端：

1. `registerSettings(traySettings)`。
2. `settings.read()` + `settings.subscribe()`。
3. 只写 `status === "ready"` 的值。
4. 写临时文件 → `rename` 到 `~/Library/Application Support/PaseoTray/config.json`。
5. 写操作串行化，避免连续 toggle 竞态。

托盘：

1. `DispatchSource.makeFileSystemObjectSource` 监听**目录**，mask 含 `.write`、`.delete`、`.rename`、`.link`、`.attrib`、`.extend`。
2. 80ms debounce 后重读配置。
3. 目录被替换/删除时 250ms 后重建 source。
4. 配置缺失时使用默认值；字段类型错误时回退该字段默认值并记录警告。
5. 启动路径只读，不创建文件；`revealInFinder` 才按需创建。

为什么监听目录：原子 `rename` 会换 inode，监听文件本身会失效。

插件设置页通过 `tray.config.status` 读取最后一次写入结果（`ok` / `error` / `path` / `syncedAt`）。该 RPC 会 `await` 当前写入队列，保证保存后的状态不是旧的。

## 6. 通知与闪烁

- 默认全部关闭，避免和 Paseo 自带通知重复。
- **视觉提示不依赖通知开关**：新的 attention 事件在 Paseo 不在前台时闪烁菜单栏图标；`AttentionGate` 按 `agentId + reason + timestamp` 做 10 分钟去重，重复事件不闪、不通知。
- `notifyOnFinish` / `notifyOnError` / `notifyOnPermission` 分别控制 reason。
- `playSound` 控制 `UNNotificationContent.sound`。
- Paseo 前台（`sh.paseo.desktop`）跳过闪烁和通知。
- 通知去重同样使用 `AttentionGate`。
- 通知点击从 `userInfo.deepLink` 打开同一深链。
- `UNUserNotificationCenter` 不可用/发送失败：`NSSound.beep()` + 菜单栏图标闪烁。
- 授权状态先用 `getNotificationSettings` 读取：`.authorized` / `.provisional` 直接可用，`.denied` 置降级，只有 `.notDetermined` 才请求权限。
- 需要 app bundle 和 bundle identifier；裸二进制没有通知能力，所以构建脚本必须生成 `.app`。

## 7. 深链

```swift
paseo://h/<percent-encoded-serverId>/agent/<percent-encoded-agentId>
```

`serverId` 来自 `server_info`（优先）或 `paseo.pid`。**不要**用 `fetch_agents_response.payload.subscriptionId` 当 serverId。

## 8. 安全边界

- 托盘只读本地 credential 文件，token 只在内存和 hello 帧里。
- 不把 token 写进 `UserDefaults`、日志、配置文件或 URL。
- 插件 server 端无沙箱，只写一个非敏感 JSON；不读 credential。
- 不修改 Paseo 安装包、`pluginsEnabled`、已有插件。
- 不重启真实 daemon；联调中的 daemon 重启用 `test/mock-daemon.mjs` 模拟。

## 9. 版本兼容

运行中的 daemon 是 0.14.0，参考源码是 0.15.0。插件按 0.14 运行时实现：

- `server.on("agent.turn_ended", ...)` 在 0.14 存在，但本项目不需要。
- 不使用 0.15 的 `server.addHook("agent.turn.after", ...)`。
- `addSidebarFooterItem`、`addScreen`、`addSettingsScreen`、`useSettings`、`navigation.openAgent` 在 0.14 都有。
- devDependency 固定 `@getpaseo/plugin@0.14.0`，避免 typecheck 通过但运行时缺 API。
- `requirements.paseo` 写 `>=0.14.0`。

## 10. 失败模式

| 现象 | 行为 |
| --- | --- |
| `paseo.pid` 不存在 | 离线，2 秒重读 |
| `listen` 是 socket/pipe | 不支持，30 秒重试 |
| credential 缺失/失效 | 需要密码，30 秒重试，菜单提供“打开 Paseo” |
| daemon 重启 | 自动重连，重新订阅，计数恢复 |
| 订阅无响应 | 保留连接，菜单显示“订阅失败/订阅超时” |
| 配置写失败 | 插件日志记录，托盘继续用旧配置 |
| 通知不可用 | beep + 图标闪烁 |
| 登录项需批准 | 菜单显示状态，点击打开系统设置 |
