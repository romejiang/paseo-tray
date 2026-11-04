import type { PluginClientContext, PluginSidebarItemProps } from "@getpaseo/plugin/client";
import { useSettings } from "@getpaseo/plugin/client";
import { SidebarRow } from "@getpaseo/plugin/client/ui";
import { Text } from "react-native";
import { AgentsScreen } from "./client/agents-screen";
import { TraySettingsScreen } from "./client/settings-screen";
import { useAgentCounts } from "./client/use-agent-directory";
import { traySettings } from "./shared/settings";

function TrayItem({ openScreen, theme }: PluginSidebarItemProps) {
  const settings = useSettings(traySettings);
  const includeSubagents = settings.status === "ready" ? settings.values.includeSubagents : false;
  const counts = useAgentCounts(includeSubagents);

  const label = counts.loading
    ? "…"
    : counts.error
      ? "!"
      : `▶${counts.running} ✓${counts.finished}${counts.actionable > 0 ? ` !${counts.actionable}` : ""}`;

  return (
    <SidebarRow
      icon="MonitorUp"
      label="Paseo Tray"
      onPress={() => openScreen({ screenId: "agents" })}
      trailing={
        <Text
          style={{
            color: counts.error ? theme.colors.statusDanger : theme.colors.foregroundMuted,
            fontSize: 12,
            fontVariant: ["tabular-nums"],
          }}
        >
          {label}
        </Text>
      }
    />
  );
}

export default function contribute(client: PluginClientContext) {
  client.addScreen({ id: "agents", title: "Paseo Tray", Component: AgentsScreen });
  client.addSidebarFooterItem({ id: "tray", title: "Paseo Tray", Component: TrayItem });
  client.addSettingsScreen({
    id: "tray-settings",
    title: "Tray",
    icon: "MonitorUp",
    Component: TraySettingsScreen,
  });
  client.addCommandCenterItem({
    id: "open-tray-agents",
    title: "Open Paseo Tray agents",
    icon: "MonitorUp",
    keywords: ["tray", "menu bar", "agents"],
    context: "global",
    onSelect({ openScreen }) {
      openScreen({ screenId: "agents" });
    },
  });
  client.addCommandCenterItem({
    id: "open-tray-settings",
    title: "Configure Paseo Tray",
    icon: "Settings",
    keywords: ["tray", "menu bar", "notifications"],
    context: "global",
    onSelect({ openSettings }) {
      openSettings("tray-settings");
    },
  });
  return () => {};
}
