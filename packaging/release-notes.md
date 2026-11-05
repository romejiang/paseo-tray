# Paseo Tray 0.1.0

A macOS menu bar tray for [Paseo](https://paseo.sh), plus a thin Paseo plugin.

> This release is signed with a Developer ID Application certificate and
> notarized by Apple. The DMG has a stapled notarization ticket.

## Install

1. Download `PaseoTray-0.1.0.dmg`.
2. Open it and drag `PaseoTray.app` into `/Applications`.
3. Launch Paseo Tray. The Paseo logo appears in the menu bar.
4. Install the Paseo plugin:

   ```bash
   PASEO=/Applications/Paseo.app/Contents/Resources/bin/paseo
   $PASEO plugin install /path/to/paseo-tray/plugin --id paseo-tray
   ```

   Or install from the source repository; see the README.

## Requirements

- macOS 13 Ventura or newer.
- Paseo 0.14.0 or newer, running locally.
- The tray app and the daemon must be on the same machine.

## What it does

- Menu bar counts: running, finished, needs input/failed.
- Click an agent to open its Paseo deep link.
- New attention events flash the menu bar icon even when system notifications
  are off.
- Optional system notifications and launch at login.
- Paseo sidebar mirror, agent screen, and settings.
- The plugin detects a missing tray app and shows a download reminder.

## Checksum

See the `PaseoTray-0.1.0.dmg.sha256` asset next to the DMG.

## Known limitations

- Only `host:port` daemon endpoints are supported.
- Local daemon only; multi-host and relay are out of scope for 0.1.0.
- Menu bar items can be hidden by menu bar managers such as Hidden Bar.
