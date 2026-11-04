# Paseo Tray

Paseo Tray mirrors the running, finished, and needs-input agents in the macOS
menu bar. The menu bar app is a separate Swift application; this plugin adds the
same counts to Paseo's sidebar, a clickable agent list, and the settings that
the tray reads.

## Setup

Install the Paseo Tray macOS app from the project's
[GitHub Releases](https://github.com/romejiang/paseo-tray/releases/latest), then
install this plugin to get the sidebar entry and settings screen. The plugin
detects whether the tray app is installed and shows a download reminder when it
is missing. The plugin only controls a local daemon; it cannot install or start
a native app on another machine.

The tray connects directly to the local Paseo daemon over its WebSocket API. It
does not depend on this plugin to run. The plugin writes the shared settings
file to `~/Library/Application Support/PaseoTray/config.json` with an atomic
rename; the tray watches that directory.

## Settings

- Show running count and show finished count control the menu bar title.
- Include subagents reveals agents that carry the `paseo.parent-agent-id` label.
- Notification switches are off by default because Paseo already sends its own
  notifications. Turning one on makes the tray post a macOS notification for
  that reason. The tray stays silent while Paseo is frontmost.
- Play sound adds the default notification sound. If macOS notifications are
  unavailable, the tray falls back to a beep and a status item flash.

## Limits

The tray only understands a daemon advertised as `host:port` in `paseo.pid` or
`config.json`. Unix socket and pipe endpoints are reported as unsupported.
