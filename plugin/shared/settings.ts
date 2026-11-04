import { defineSettings } from "@getpaseo/plugin";
import { z } from "zod";

/**
 * The tray is silent by default because Paseo already posts its own system
 * notifications. Each reason is opt-in from this settings screen.
 */
export const traySettings = defineSettings({
  id: "tray",
  scope: "host",
  version: 1,
  schema: z.object({
    showRunningCount: z.boolean().default(true),
    showFinishedCount: z.boolean().default(true),
    notifyOnFinish: z.boolean().default(false),
    notifyOnError: z.boolean().default(false),
    notifyOnPermission: z.boolean().default(false),
    playSound: z.boolean().default(false),
    includeSubagents: z.boolean().default(false),
  }),
});

export type TraySettings = z.infer<typeof traySettings.schema>;
