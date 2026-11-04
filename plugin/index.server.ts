import type { PluginServerContext, PluginSettingsState } from "@getpaseo/plugin/server";
import { getTrayAppStatus } from "./server/app-status";
import { getTrayConfigStatus, writeTrayConfig } from "./server/write-config";
import { trayAppStatusRpc } from "./shared/app-status";
import { trayConfigStatusRpc } from "./shared/config-status";
import { traySettings } from "./shared/settings";

type TraySettingsState = PluginSettingsState<typeof traySettings.schema>;

export default function contribute(server: PluginServerContext) {
  const settings = server.registerSettings(traySettings);
  server.handle(trayConfigStatusRpc, () => getTrayConfigStatus());
  server.handle(trayAppStatusRpc, () => getTrayAppStatus());

  const write = (state: TraySettingsState): void => {
    if (state.status === "ready") {
      void writeTrayConfig(state.values);
      return;
    }
    console.error(`[paseo-tray] settings invalid: ${state.error}`);
  };

  void settings
    .read()
    .then(write)
    .catch((error: unknown) => {
      console.error(
        "[paseo-tray] failed to read settings",
        error instanceof Error ? error.message : String(error),
      );
    });

  const unsubscribe = settings.subscribe(write);
  return () => {
    unsubscribe();
  };
}
