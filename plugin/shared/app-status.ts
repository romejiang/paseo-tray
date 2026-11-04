import { defineRpc } from "@getpaseo/plugin";
import { z } from "zod";

export const TRAY_DOWNLOAD_URL = "https://github.com/romejiang/paseo-tray/releases/latest";

export const trayAppStatusRpc = defineRpc({
  name: "tray.app.status",
  input: z.object({}),
  output: z.object({
    platform: z.string(),
    installed: z.boolean(),
    path: z.string().nullable(),
    version: z.string().nullable(),
    downloadUrl: z.string().url(),
    minimumMacOS: z.string(),
  }),
});

export interface TrayAppStatus {
  platform: string;
  installed: boolean;
  path: string | null;
  version: string | null;
  downloadUrl: string;
  minimumMacOS: string;
}
