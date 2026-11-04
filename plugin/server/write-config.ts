import { randomUUID } from "node:crypto";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import type { TrayConfigStatus } from "../shared/config-status";
import type { TraySettings } from "../shared/settings";

export function trayConfigPath(): string {
  const override = process.env.PASEOTRAY_CONFIG_PATH?.trim();
  if (override) return override;
  return path.join(homedir(), "Library", "Application Support", "PaseoTray", "config.json");
}

let queue: Promise<void> = Promise.resolve();
let lastStatus: TrayConfigStatus = {
  ok: false,
  error: null,
  path: trayConfigPath(),
  syncedAt: null,
};

export async function getTrayConfigStatus(): Promise<TrayConfigStatus> {
  const pending = queue;
  await pending.catch(() => undefined);
  return { ...lastStatus, path: trayConfigPath() };
}

/**
 * Writes are serialized and atomic. The tray watches the directory, not the
 * file, because rename replaces the inode.
 */
export function writeTrayConfig(values: TraySettings): Promise<void> {
  const target = trayConfigPath();
  queue = queue.then(async () => {
    try {
      await writeNow(values, target);
      lastStatus = {
        ok: true,
        error: null,
        path: target,
        syncedAt: new Date().toISOString(),
      };
      console.error(`[paseo-tray] tray config synced to ${target}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      lastStatus = {
        ok: false,
        error: message,
        path: target,
        syncedAt: lastStatus.syncedAt,
      };
      console.error("[paseo-tray] failed to write tray config", message);
    }
  });
  return queue;
}

async function writeNow(values: TraySettings, target: string): Promise<void> {
  const directory = path.dirname(target);
  await mkdir(directory, { recursive: true, mode: 0o755 });

  const payload = {
    showRunningCount: values.showRunningCount,
    showFinishedCount: values.showFinishedCount,
    notifyOnFinish: values.notifyOnFinish,
    notifyOnError: values.notifyOnError,
    notifyOnPermission: values.notifyOnPermission,
    playSound: values.playSound,
    includeSubagents: values.includeSubagents,
  };
  const body = `${JSON.stringify(payload, null, 2)}\n`;
  const temporary = path.join(directory, `.config.json.${process.pid}.${randomUUID()}.tmp`);
  try {
    await writeFile(temporary, body, { mode: 0o644 });
    await rename(temporary, target);
  } finally {
    await rm(temporary, { force: true });
  }
}
