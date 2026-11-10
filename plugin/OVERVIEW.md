# Paseo Tray

Paseo Tray puts your Paseo agents in the macOS menu bar, so you can see what is
running, what finished, and what is waiting for you without switching windows.
It has two parts:

- **A native menu bar app** (separate Swift application, signed and notarized)
  that connects to your local Paseo daemon and shows live counts.
- **This plugin**, which mirrors the same information inside Paseo: a sidebar
  entry, a full agent screen, and the settings the tray app reads.

The tray app works without the plugin. The plugin adds the in-app view and a
place to configure the tray.

## What the menu bar shows

The menu bar title is the summary:

| Title | Meaning |
| --- | --- |
| `▶ n` | Agents currently running |
| `✓ n` | Finished agents you have not looked at yet |
| `! n` | Agents that need input or failed (shown in red) |
| `–` | Offline, password required, or unsupported connection (icon dimmed) |
| Icon only | Nothing running, finished, or waiting |

Click the icon to open a menu grouped into **需要你处理 (Needs you) → 失败
(Failed) → 运行中 (Running) → 已完成 (Finished)**. Every row is one agent with
its title and how long it has been in that state. Clicking a row opens that
exact agent in Paseo. The menu also has **打开 Paseo (Open Paseo)**, **登录时启动
(Launch at login)**, **托盘设置… (Tray settings…)**, and **退出 (Quit)**.

The menu bar app and the plugin screens currently use Simplified Chinese UI
labels; this page translates them in parentheses.

While Paseo is not frontmost, new finished, failed, and permission events flash
the menu bar icon even when macOS notifications are off, so you notice them
without allowing banners.

## What the plugin adds inside Paseo

- **Sidebar entry** — a `Paseo Tray  ▶2 ✓1 !1` row at the bottom of Paseo's
  sidebar. Click it to open the agent screen.
- **Agents screen** — the same grouping as the menu, with clickable rows that
  jump to each agent.
- **Settings screen** — every tray option in one place, with the shared config
  file path and the last write result.
- **Command Center actions** — `Open Paseo Tray agents` and
  `Configure Paseo Tray`.
- **Install detection** — if the menu bar app is not installed on this Mac, the
  agent screen and settings show a download link.

## Setup

Paseo Tray requires macOS 13 or later and Paseo 0.14.0 or later.

1. Install the **Paseo Tray** macOS app:
   - From [GitHub Releases](https://github.com/romejiang/paseo-tray/releases/latest):
     download `PaseoTray-<version>.dmg` and drag `PaseoTray.app` into
     `/Applications`.
   - Or with Homebrew:

     ```bash
     brew tap romejiang/tap
     brew trust romejiang/tap
     brew install --cask romejiang/tap/paseo-tray
     ```

     Upgrade with `brew upgrade --cask paseo-tray`; uninstall with
     `brew uninstall --cask paseo-tray`.
2. The menu bar icon appears as soon as the app launches. Allow notifications
   only if you want system banners; the flashing icon works without them.

**Launch at login** is optional and uses the macOS login item API. The app asks
for notification permission only when you enable a notification switch.

## Settings

The settings screen writes one shared file:
`~/Library/Application Support/PaseoTray/config.json`.

| Setting | Default | Effect |
| --- | --- | --- |
| 显示运行中数量 (Show running count) | on | Show `▶ n` in the menu bar title |
| 显示已完成数量 (Show finished count) | on | Show `✓ n` in the menu bar title |
| 包含子 agent (Include subagents) | off | Show agents labeled `paseo.parent-agent-id` |
| 完成时通知 (Notify on finish) | off | Post a macOS notification when an agent finishes |
| 出错时通知 (Notify on error) | off | Post a notification when an agent fails |
| 需要权限时通知 (Notify on permission) | off | Post a notification when an agent needs permission |
| 播放声音 (Play sound) | off | Add the default notification sound |

Notification switches are off by default because Paseo already sends its own
notifications. When one is on, the tray stays silent while Paseo is frontmost.

The plugin writes the file with a temporary file and an atomic rename; the tray
watches the folder and usually applies a change in under a second. If the
plugin is disabled, the tray keeps using the last saved settings.

## Data and privacy

- The tray connects **directly to the local Paseo daemon** over its WebSocket
  API. Nothing goes through a cloud service.
- It reads the existing `~/.paseo/local-credential` file for authentication and
  never writes it. The token stays in memory and is not logged.
- The plugin writes one non-sensitive JSON file (the settings above) and reads
  the local daemon. It does not send data anywhere.
- The tray and plugin never modify `/Applications/Paseo.app` or Paseo's own
  config.

## Limits

- Only a local daemon advertised as `host:port` in `paseo.pid` or `config.json`
  is supported. Unix socket and pipe endpoints are reported as unsupported.
- The tray only manages the Mac it runs on. It cannot install or start a native
  app on another machine.
- If the daemon requires a password and the stored credential is invalid, the
  tray shows “Password required” and offers to open Paseo.
- The menu bar item follows the active display. Multi-display setups and menu
  bar managers such as Hidden Bar may move it into a hidden section.

Paseo Tray is an unofficial companion project. The Paseo name and logo belong
to their owners.
