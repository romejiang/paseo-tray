# Paseo Tray

Paseo Tray 把 Paseo 的 agent 状态放进 macOS 菜单栏：不用切窗口，就能看到哪些
agent 正在运行、哪些已经完成、哪些在等你处理。它由两部分组成：

- **原生菜单栏 App**（独立的 Swift 应用，已签名并公证）：直连本机 Paseo
  daemon，在菜单栏显示实时计数。
- **这个插件**：在 Paseo 内部镜像同样的信息，提供侧边栏入口、完整的 agent
  列表页，以及托盘 App 读取的设置页。

托盘 App 不依赖插件也能工作；插件负责应用内视图和配置入口。

## 菜单栏显示什么

菜单栏标题就是摘要：

| 标题 | 含义 |
| --- | --- |
| `▶ n` | 正在运行的 agent 数量 |
| `✓ n` | 已完成、你还没看的 agent 数量 |
| `! n` | 需要你输入或已经失败的 agent 数量（红色显示） |
| `–` | 离线、需要密码或不支持的连接方式（图标变灰） |
| 只有图标 | 没有运行中、已完成或待处理的 agent |

点击图标会打开按 **需要你处理 → 失败 → 运行中 → 已完成** 分组的菜单。每一条
就是一个 agent，显示标题和它处于该状态多久；点击条目会在 Paseo 里直接打开对应
的 agent。菜单里还有 **打开 Paseo**、**登录时启动**、**托盘设置…** 和 **退出**。

Paseo 不在前台时，新的完成、失败、权限事件会让菜单栏图标闪烁——即使系统通知开关
是关的，也能注意到，不需要因此打开横幅通知。

## 插件在 Paseo 里增加什么

- **侧边栏入口**：Paseo 侧边栏底部出现 `Paseo Tray  ▶2 ✓1 !1`，点击打开 agent
  列表页。
- **Agent 列表页**：和菜单相同的分组，每一行都可以点击跳转到对应 agent。
- **设置页**：集中管理所有托盘选项，并显示共享配置文件的路径和最近一次写入结果。
- **Command Center 命令**：`Open Paseo Tray agents` 和 `Configure Paseo Tray`。
- **安装检测**：如果这台 Mac 还没安装菜单栏 App，agent 列表页和设置页会显示下载
  提醒。

## 安装

Paseo Tray 要求 macOS 13 或更高版本，以及 Paseo 0.14.0 或更高版本。

1. 从项目的 GitHub Releases 安装 **Paseo Tray** macOS App，放进
   `/Applications` 或 `~/Applications`。
2. App 启动后菜单栏就会出现图标。只有想要系统横幅通知时才需要允许通知；闪烁提醒
   不依赖通知权限。

**登录时启动** 是可选项，使用 macOS 的登录项 API。只有你打开某个通知开关时，App
才会申请通知权限。

## 设置

设置页写入一个共享文件：
`~/Library/Application Support/PaseoTray/config.json`。

| 设置 | 默认 | 作用 |
| --- | --- | --- |
| 显示运行中数量 | 开 | 菜单栏标题显示 `▶ n` |
| 显示已完成数量 | 开 | 菜单栏标题显示 `✓ n` |
| 包含子 agent | 关 | 显示带 `paseo.parent-agent-id` 标签的 agent |
| 完成时通知 | 关 | agent 完成时发 macOS 通知 |
| 出错时通知 | 关 | agent 失败时发通知 |
| 需要权限时通知 | 关 | agent 需要权限时发通知 |
| 播放声音 | 关 | 通知附带默认提示音 |

通知开关默认全关，因为 Paseo 自己已经会发通知。打开后，Paseo 在前台时托盘会自动
静默。

插件用临时文件加原子 `rename` 写入配置；托盘监听配置目录，保存后通常 1 秒内生效。
插件被禁用时，托盘继续使用最后一次保存的设置。

## 数据与隐私

- 托盘**直连本机 Paseo daemon** 的 WebSocket API，不经过任何云服务。
- 认证读取现有的 `~/.paseo/local-credential`，只读不写；token 只放在内存里，不写
  日志。
- 插件只写一个非敏感的 JSON 配置文件（上面的设置），并读取本机 daemon，不向任何
  地方发送数据。
- 托盘和插件都不会修改 `/Applications/Paseo.app` 或 Paseo 自己的配置。

## 限制

- 只支持在 `paseo.pid` 或 `config.json` 中以 `host:port` 形式公布的本地 daemon。
  Unix socket 和 pipe 端点会显示为不支持。
- 托盘只管理它运行所在的这台 Mac，不能在另一台机器上安装或启动原生 App。
- 如果 daemon 要求密码而保存的 credential 已失效，托盘会显示“需要密码”，并提供
  打开 Paseo 的入口。
- 菜单栏图标跟随当前活跃显示器。多显示器配置或 Hidden Bar 之类的菜单栏管理器可能
  把它放进隐藏区。

Paseo Tray 是非官方 companion 项目。Paseo 名称和 logo 归其所有者所有。
