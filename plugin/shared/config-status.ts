import { defineRpc } from "@getpaseo/plugin";
import { z } from "zod";

export const trayConfigStatusRpc = defineRpc({
  name: "tray.config.status",
  input: z.object({}),
  output: z.object({
    ok: z.boolean(),
    error: z.string().nullable(),
    path: z.string(),
    syncedAt: z.string().nullable(),
  }),
});

export interface TrayConfigStatus {
  ok: boolean;
  error: string | null;
  path: string;
  syncedAt: string | null;
}
