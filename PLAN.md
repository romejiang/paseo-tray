# Paseo Tray — 实施计划

## 目标

为 Paseo 提供一个真正的 macOS 菜单栏托盘，并配一个薄 Paseo 插件做应用内镜像与设置入口。

- 托盘是独立 Swift App，不依赖插件、不改 `/Applications/Paseo.app`。
- 插件只做三件事：侧边栏计数、agent 列表 screen、设置页。
- 设置通过 daemon 侧插件写入 `~/Library/Application Support/PaseoTray/config.json`，托盘监听目录变化。

## 架构

```
Paseo daemon (127.0.0.1:6767)
  │  ws://<listen>/ws
  │  hello → server_info
  │  fetch_agents_request (subscribe) → fetch_agents_response + agent_update
  │  session.events.set_subscription(agent_attention_required)
  │
  ├── PaseoTray.app (Swift / AppKit / URLSessionWebSocketTask)
  │     AgentStore ← 协议帧
  │     MenuController → NSStatusItem + NSMenu
  │     TrayConfigStore → 监听 config 目录
  │     Notifier → 可选系统通知 / beep 降级
  │
  └── paseo-tray plugin (TS)
        index.server.ts → registerSettings → 原子写 config.json
        index.client.tsx → footer 计数 / agents screen / settings screen
```

## 关键决策

1. **不做 Electron Tray**：不改 Paseo 主仓库和安装包。方案 A（独立托盘 + 薄插件）。
2. **状态桶严格按 `packages/protocol/src/agent-state-bucket.ts`**：
   `needs_input > failed > running > attention > done`。
   托盘只展示前四类，`done`（普通 idle）不进入菜单，也不计入计数。
3. **完成信号用 `agent_attention_required`**，不用 `status === "idle"`。
4. **`server_info` 兼容两种帧**：源码实际是 `{"type":"session","message":{"type":"status","payload":{...}}}`；同时兼容裸 `{"type":"status",...}`。
5. **通知默认关闭**：Paseo 自己已经发通知，避免双份。开启后 Paseo 在前台则静默。
6. **鉴权只读 `~/.paseo/local-credential`**，不写日志、不写配置、不拼 URL。
7. **不重启真实 daemon**：验收中的 daemon 重启用 `test/mock-daemon.mjs` 完成；真实 daemon 只做只读连接和插件安装/重载。

## 阶段

### Phase 1 — Swift 菜单栏 App

- 文件：`tray/Sources/{main,AppDelegate,PaseoClient,AgentStore,MenuController,TrayConfig,Notifier,LoginItem,Diagnostics,Log}.swift`
- 功能：
  - `paseo.pid` / `config.json` 发现 daemon，`PASEO_HOME` 覆盖。
  - hello + auth + 两个订阅 + 30s ping + 90s 看门狗 + 指数退避重连。
  - 状态桶、过滤 background/internal/subagent/archived、排序、计数。
  - 菜单栏标题 `▶ n ✓ n ! n`，离线灰色 `–`。
  - 原生 `NSMenu`，条目打开 `paseo://h/<serverId>/agent/<agentId>`。
  - 配置目录监听、登录自启、可选通知、`--demo`。
  - `--selftest` / `--watch-json` / `--self-check` 诊断模式。
- 构建：`tray/build.sh` 生成 `.app` 并 ad-hoc 签名；`tray/install.sh` 安装到 `~/Applications`。

### Phase 2 — Paseo 插件

- 文件：`plugin/{paseo-plugin.json,package.json,tsconfig.json,OVERVIEW.md,index.client.tsx,index.server.ts,client/*,server/*,shared/*}`
- 使用 0.14 运行时 API：`server.on`、`registerSettings`、`addSidebarFooterItem`、`addScreen`、`addSettingsScreen`、`useSettings`、`usePaseo`、`navigation.openAgent`。
- `requirements.paseo >= 0.14.0`；devDependency 用 0.14.0 做类型检查，避免误用 0.15 API。
- 安装到真实 daemon，验证 `plugin ls` / `logs` / disable / enable。

### Phase 3 — 联调、验收、文档

- `test/mock-daemon.mjs`：可控 WebSocket daemon，驱动空/运行/完成/待输入/清除/重连/多 agent。
- `test/plugin-settings-probe.mjs`：通过真实 daemon 调 `settings.tray.read/write`，验证插件写 config。
- `README.md`、`ARCHITECTURE.md`、`ACCEPTANCE.md`（命令与结果）。
- 截图：demo 菜单、真实 daemon 菜单、Paseo 内插件入口（尽可能）。

## 验收项映射

| # | 场景 | 验证方式 |
| --- | --- | --- |
| 1 | 全空 | mock daemon 空快照 → `--selftest` 计数全 0 |
| 2 | 运行中 | mock + 真实 daemon 快照 → `▶ n` |
| 3 | 完成 | mock attention event → `✓ n` + notify 决策 |
| 4 | 待输入 | mock permission event → `! n`，菜单置顶 |
| 5 | 清除 | mock upsert requiresAttention=false → `✓` 减少 |
| 6 | daemon 重启 | mock daemon kill/restart → 托盘自动重连 |
| 7 | 托盘重启 | killall + 重新 `--selftest` |
| 8 | 插件 disable/enable | 真实 CLI |
| 9 | 设置 | `settings.tray.write` → config 文件 → `--watch-json` 配置事件 |
| 10 | 登录自启 | `--login-item-*` 状态转换 |
| 11 | Demo | `--demo` + 截图 |
| 12 | 多 agent | mock 6 agents → 计数/排序/菜单 |

## 已知风险

- ad-hoc 签名的 `UNUserNotificationCenter` 可能受系统限制；失败时降级 beep + 图标闪烁，README 说明。
- `SMAppService.mainApp` 在 `~/Applications` + ad-hoc 签名下可能要求系统设置批准；菜单会显示状态并提供打开系统设置。
- 托盘只支持 `host:port` 的 daemon listen；socket 形式显示“不支持”。
- 插件设置是 host 级，只对同机 daemon 有意义。
