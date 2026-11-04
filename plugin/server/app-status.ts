import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { TRAY_DOWNLOAD_URL, type TrayAppStatus } from "../shared/app-status";

const CANDIDATES = [
  path.join(homedir(), "Applications", "PaseoTray.app"),
  "/Applications/PaseoTray.app",
];

function versionFromPlist(plist: string): string | null {
  const match = plist.match(
    /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/,
  );
  return match?.[1]?.trim() || null;
}

export async function getTrayAppStatus(): Promise<TrayAppStatus> {
  for (const candidate of CANDIDATES) {
    try {
      const plist = await readFile(
        path.join(candidate, "Contents", "Info.plist"),
        "utf8",
      );
      return {
        platform: process.platform,
        installed: true,
        path: candidate,
        version: versionFromPlist(plist),
        downloadUrl: TRAY_DOWNLOAD_URL,
        minimumMacOS: "13.0",
      };
    } catch {
      // Try the next standard location.
    }
  }
  return {
    platform: process.platform,
    installed: false,
    path: null,
    version: null,
    downloadUrl: TRAY_DOWNLOAD_URL,
    minimumMacOS: "13.0",
  };
}
